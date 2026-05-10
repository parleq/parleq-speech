// BedrockBearerProvider — Bedrock LLMProvider for the new
// scoped Bedrock API key auth path (#22).
//
// AWS shipped Bedrock-specific bearer tokens in 2024 as a simpler
// alternative to IAM access keys for Bedrock-only access. They're
// scoped to a single AWS account, can be rotated independently,
// and don't require the user to understand IAM policies. The wire
// format is plain HTTP with `Authorization: Bearer <key>` instead
// of SigV4 — which means Soto can't do it directly (Soto's
// request flow inherently signs every request with SigV4 from a
// CredentialProvider). This file is the entire Soto-bypass path.
//
// What's in here:
//   1. URLSession-based HTTP request to
//      bedrock-runtime.<region>.amazonaws.com/model/<id>/converse-stream
//      with Bearer auth + Accept: application/vnd.amazon.eventstream.
//   2. Hand-built ConverseStream JSON request body matching the
//      shape Soto produces in BedrockProvider.swift.
//   3. AWS event-stream parsing via BedrockEventStream.swift.
//   4. Mapping to LLMStreamEvent for the runtime path.
//
// SSO and static-credential modes still go through the original
// BedrockProvider; the factory in ParleqApp.swift picks whichever
// concrete provider matches Config.awsAuthMode.

import Foundation

final class BedrockBearerProvider: LLMProvider, Sendable {
    let model: String
    let region: String
    let session: URLSession

    var providerName: String { "bedrock" }

    init(model: String, region: String) {
        self.model = model
        self.region = region
        self.session = URLSession.shared
    }

    func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        guard let key = KeychainStore.readBedrockAPIKey(), !key.isEmpty else {
            throw LLMError.missingCredentials(
                "No Bedrock API key set. Open Settings → LLM → Set Bedrock API Key."
            )
        }

        let body = buildRequestBody(systemPrompt: systemPrompt, messages: messages)
        // Model IDs can contain `:` (inference-profile IDs like
        // `us.anthropic.claude-haiku-4-5-20251001-v1:0`) and `.` —
        // both legal in path segments, but percent-encode anyway
        // since some intermediaries drop unencoded `:` into URL
        // queries unexpectedly.
        let encodedModel = model.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? model
        let urlString = "https://bedrock-runtime.\(region).amazonaws.com/model/\(encodedModel)/converse-stream"
        guard let url = URL(string: urlString) else {
            throw LLMError.requestFailed(
                NSError(domain: "BedrockBearerProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not build URL: \(urlString)"])
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The accept header is what triggers the binary event-stream
        // response on this endpoint. Without it the server returns
        // a JSON one-shot.
        request.setValue("application/vnd.amazon.eventstream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw LLMError.requestFailed(error)
        }

        let started = Date()
        var ttft: TimeInterval = 0
        var inputTokens = 0
        var outputTokens = 0

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse("response is not HTTP")
        }
        if !(200..<300).contains(http.statusCode) {
            // Errors here are plain JSON, not event-stream — drain
            // and surface the body as the error detail. Common
            // causes per status:
            //   401: invalid Bedrock API key, or key from a different
            //        AWS account / region than the request.
            //   403: key valid but doesn't have permission for the
            //        configured model — Bedrock API keys can be
            //        scoped to a subset of models in the AWS console.
            //   400: model id wrong, or region doesn't have model
            //        access enabled.
            var buf = Data()
            for try await byte in bytes {
                buf.append(byte)
                if buf.count > 4096 { break }
            }
            let snippet = String(data: buf, encoding: .utf8) ?? "<\(buf.count) bytes>"
            throw LLMError.badStatus(http.statusCode, String(snippet.prefix(400)))
        }
        // Successful response: confirm the body is event-stream
        // binary before feeding the parser. AWS occasionally
        // returns a 200 with a JSON body when something goes
        // sideways (model not enabled for streaming, API key
        // scoped only to the non-streaming Converse endpoint, etc.)
        // — feeding that into the binary parser would either crash
        // on the first prelude or produce garbage events.
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.contains("application/vnd.amazon.eventstream") else {
            var buf = Data()
            for try await byte in bytes {
                buf.append(byte)
                if buf.count > 4096 { break }
            }
            let snippet = String(data: buf, encoding: .utf8) ?? "<\(buf.count) bytes>"
            throw LLMError.malformedResponse(
                "Bedrock returned 200 OK but Content-Type='\(contentType)' (expected application/vnd.amazon.eventstream). Body preview: \(String(snippet.prefix(400)))"
            )
        }

        // Successful response: parse the event-stream binary frames.
        let parser = BedrockEventStreamParser(bytes: bytes)
        while let event = try await parser.nextEvent() {
            switch event {
            case .textDelta(let text):
                if !text.isEmpty {
                    if ttft == 0 { ttft = -started.timeIntervalSinceNow }
                    onEvent(.chunk(text))
                }
            case .metadata(let input, let output):
                inputTokens = input
                outputTokens = output
            case .other:
                continue
            case .error(let name, let message):
                throw LLMError.malformedResponse("\(name): \(message)")
            }
        }

        let summary = LLMStreamSummary(
            totalLatency: -started.timeIntervalSinceNow,
            ttft: ttft,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
        onEvent(.done(summary))
    }

    /// Build the ConverseStream JSON body. Shape matches what Soto
    /// produces in BedrockProvider.swift — same inferenceConfig,
    /// same per-model additionalModelRequestFields ("reasoning_effort":
    /// "low" for gpt-oss). We hand-build it here because Soto only
    /// emits it via SigV4-signed calls.
    private func buildRequestBody(systemPrompt: String, messages: [LLMMessage]) -> [String: Any] {
        let convo: [[String: Any]] = messages.map { msg in
            let role: String = (msg.role == "assistant") ? "assistant" : "user"
            return [
                "role": role,
                "content": [["text": msg.content]],
            ]
        }
        var body: [String: Any] = [
            "messages": convo,
            "system": [["text": systemPrompt]],
            "inferenceConfig": [
                "maxTokens": 1024,
                "temperature": 0,
            ],
        ]
        // Per-model tweaks — match BedrockProvider.additionalFields.
        // Today only gpt-oss has one (reasoning_effort=low; in-house
        // benchmarks found it drops the hidden reasoning channel
        // from 220 tokens to ~30 with no quality loss).
        if model.contains("gpt-oss") {
            body["additionalModelRequestFields"] = [
                "reasoning_effort": "low",
            ]
        }
        return body
    }
}
