// OpenAIProvider — OpenAI direct API (api.openai.com)
// implementation of LLMProvider for users with a personal or
// org OpenAI key who don't want to set up Azure OpenAI Service.
//
// This is intentionally close to AzureOpenAIProvider in structure:
// both speak OpenAI Chat Completions JSON and parse the same SSE
// delta format. The concrete differences are:
//   - URL: api.openai.com/v1/chat/completions (single fixed endpoint;
//     no resource / deployment / api-version path components).
//   - Auth header: "Authorization: Bearer <key>" (Azure uses "api-key:").
//   - Request body: "model" field required (Azure routes by deployment
//     URL; OpenAI direct uses the body `model` field).
//
// Reasoning models (o1, o1-mini, o3, o3-mini, o4-mini) are handled
// via a conditional parameter shape: `max_completion_tokens` instead
// of `max_tokens`, and `temperature` omitted entirely. Detection
// delegates to `isOpenAIReasoningModel(_:)` in OpenAIReasoningModels.swift,
// shared with any future callers that need the same check.
//
// Compliance posture: audio is transcribed locally (FluidAudio) or
// on a user-configured ASR endpoint; cleaned text is sent only to the
// LLM provider whose Keychain credential the user has set. Parleq
// itself does not proxy or log the content. OpenAI direct is another
// first-party endpoint in this model alongside Gemini, Bedrock, and
// Azure. Orgs whose data-residency requirements mandate Azure can
// leave this credential unset — Parleq won't route through a provider
// whose Keychain item is absent.

import Foundation

public final class OpenAIProvider: LLMProvider, Sendable {
    public let model: String
    public let session: URLSession

    public var providerName: String { "openai" }

    /// Vision capability for OpenAI direct (api.openai.com).
    /// gpt-4o family and gpt-4.1/4.1-mini support vision.
    /// gpt-4.1-nano is text-only (smallest, cheapest — no multimodal path).
    /// Reasoning models: o1 and o3 support vision (added Dec 2024 / 2025);
    /// o4-mini supports vision; o1-mini and o3-mini are text-only.
    public var supportsVision: Bool {
        let m = model.lowercased()
        if m.contains("gpt-4o") { return true }
        if m == "gpt-4.1" || m == "gpt-4.1-mini" { return true }
        // o-series reasoning models (partial vision support)
        if m == "o1" || m == "o3" || m == "o4-mini" { return true }
        if m == "o1-mini" || m == "o3-mini" { return false }
        return false  // conservative; explicit allowlist only
        // gpt-4.1-nano falls through to false (text-only).
    }

    public init(model: String) {
        self.model = model
        self.session = URLSession.shared
    }

    public func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        let body = buildRequestBody(systemPrompt: systemPrompt, messages: messages)

        let urlString = "https://api.openai.com/v1/chat/completions"
        guard let url = URL(string: urlString) else {
            throw LLMError.requestFailed(
                NSError(
                    domain: "OpenAIProvider",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not build URL: \(urlString)"]
                )
            )
        }

        // Resolve fresh from Keychain on each call so a key set
        // in Settings takes effect on the next dictation without
        // requiring a restart.
        guard let apiKey = KeychainStore.readOpenAIAPIKey(), !apiKey.isEmpty else {
            throw LLMError.missingCredentials(
                "No OpenAI API key set. Open Settings → Cleanup → Set OpenAI API Key."
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // OpenAI direct uses Bearer auth, not the Azure-style api-key header.
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
            var buf = Data()
            for try await byte in bytes {
                buf.append(byte)
                if buf.count > 4096 { break }
            }
            let snippet = String(data: buf, encoding: .utf8) ?? "<\(buf.count) bytes>"
            throw LLMError.badStatus(http.statusCode, String(snippet.prefix(400)))
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let parsed = try? JSONDecoder().decode(OpenAIStreamPayload.self, from: data) else { continue }

            if let chunk = parsed.deltaText, !chunk.isEmpty {
                if ttft == 0 {
                    ttft = -started.timeIntervalSinceNow
                }
                onEvent(.chunk(chunk))
            }
            if let usage = parsed.usage {
                inputTokens = usage.prompt_tokens ?? inputTokens
                outputTokens = usage.completion_tokens ?? outputTokens
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

    private func buildRequestBody(systemPrompt: String, messages: [LLMMessage]) -> [String: Any] {
        // OpenAI Chat Completions wire format. Unlike Azure, the `model`
        // field in the body is the routing key — there is no deployment-
        // name indirection here. system message is role="system" as a
        // first-class conversation turn.
        var convo: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
        ]
        for msg in messages {
            convo.append(buildOpenAIMessage(msg))
        }
        var body: [String: Any] = [
            "model": model,
            "messages": convo,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        // Reasoning models (o1, o1-mini, o3, o3-mini, o4-mini) reject
        // `max_tokens` and require `max_completion_tokens` because they
        // distinguish a hidden reasoning token budget from the visible
        // output budget. They also reject any `temperature` value other
        // than the implicit default of 1.0 — omit the key entirely to
        // avoid a 400. Standard models continue to use `max_tokens` +
        // `temperature: 0`.
        if isOpenAIReasoningModel(model) {
            body["max_completion_tokens"] = 1024
            // Omit temperature — reasoning models only accept the default 1.0.
        } else {
            body["max_tokens"] = 1024
            body["temperature"] = 0
        }
        return body
    }

    /// Serialize a single LLMMessage to OpenAI's chat message object.
    /// When image parts are present, `content` is an array of typed
    /// content parts (text + image_url). For text-only messages, `content`
    /// stays a plain string to preserve wire-compatibility.
    private func buildOpenAIMessage(_ msg: LLMMessage) -> [String: Any] {
        let role = msg.role == "model" ? "assistant" : msg.role
        let hasImage = msg.parts.contains {
            if case .image = $0 { return true } else { return false }
        }
        if hasImage {
            let content: [[String: Any]] = msg.parts.map { part in
                switch part {
                case .text(let s):
                    return ["type": "text", "text": s]
                case .image(let data, let mime):
                    return [
                        "type": "image_url",
                        "image_url": [
                            "url": "data:\(mime);base64,\(data.base64EncodedString())",
                        ],
                    ]
                }
            }
            return ["role": role, "content": content]
        } else {
            let text = msg.parts.compactMap {
                if case .text(let s) = $0 { return s } else { return nil }
            }.joined()
            return ["role": role, "content": text]
        }
    }

    /// Provider-specific recovery hint for the cleanup-failure
    /// overlay. Points the user at Settings where they can set
    /// or replace their OpenAI API key.
    public func cleanupFailureHint(for error: LLMError) -> String? {
        switch error {
        case .missingAPIKey, .missingCredentials:
            return "OpenAI API key missing. Open Settings → Cleanup → Set OpenAI API Key…"
        case .badStatus(let code, _) where code == 401 || code == 403:
            return "OpenAI rejected the API key. Open Settings → Cleanup → Set OpenAI API Key… and verify the key is current."
        case .badStatus, .malformedResponse, .requestFailed:
            return nil
        }
    }
}

// MARK: - OpenAI SSE payload

/// OpenAI Chat Completions streaming chunks follow the same schema
/// whether hitting api.openai.com or Azure OpenAI Service. Each chunk
/// has `choices[0].delta.content` (a partial text string) and the
/// final chunk(s) include a `usage` block when
/// `stream_options.include_usage` is set in the request.
private struct OpenAIStreamPayload: Decodable {
    let choices: [Choice]?
    let usage: Usage?

    var deltaText: String? {
        choices?.first?.delta?.content
    }

    struct Choice: Decodable {
        let delta: Delta?
    }
    struct Delta: Decodable {
        let content: String?
    }
    struct Usage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }
}
