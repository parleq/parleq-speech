// LLMStreaming — Server-Sent Events streaming for the Google AI
// :streamGenerateContent endpoint. Reads `data:` lines, decodes
// each as a partial GenerateContentResponse, and yields visible-text
// chunks via a callback.
//
// The non-streaming :generateContent path in LLMClient.swift is kept
// for one-shot batch use (e.g. tests, headless scripts). The
// runtime path for the overlay UX uses this streaming variant
// because the design requires "always stream the LLM step": on
// short outputs the win is small, but on long refinement outputs
// it's 200-600 ms.
//
// TTFT (time-to-first-token) is measured as the wall clock from
// request send to the first non-empty text chunk arriving — exactly
// the "user sees text appearing" moment in the overlay.

import Foundation

extension LLMClient {
    /// Run a streaming generation. The closure is called once per
    /// chunk and once with `.done` at the end. The closure runs on
    /// whatever queue URLSession's byte stream is processed on, so
    /// callers that need to update UI must hop to MainActor inside.
    public func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        let apiKey = try currentAPIKey()
        let body = buildStreamingRequestBody(systemPrompt: systemPrompt, messages: messages)
        // Auth via header (see `generate()` above for rationale).
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = LLMTuning.current.requestTimeoutSeconds  // #55
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw LLMError.requestFailed(error)
        }

        let started = Date()
        var ttft: TimeInterval = 0
        var inputTokens = 0
        var outputTokens = 0

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse("response is not HTTP")
        }
        if !(200..<300).contains(http.statusCode) {
            // Drain the body for a meaningful error message; SSE
            // failures sometimes ship a JSON error in the response.
            var buf = Data()
            for try await byte in bytes {
                buf.append(byte)
                if buf.count > 4096 { break }
            }
            let snippet = String(data: buf, encoding: .utf8) ?? "<\(buf.count) bytes>"
            throw LLMError.badStatus(http.statusCode, String(snippet.prefix(400)))
        }

        for try await line in bytes.lines {
            // SSE event lines: `data: <payload>` (or empty / comment lines).
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let parsed = try? JSONDecoder().decode(StreamPayload.self, from: data) else { continue }

            if let chunk = parsed.text, !chunk.isEmpty {
                if ttft == 0 {
                    ttft = -started.timeIntervalSinceNow
                }
                onEvent(.chunk(chunk))
            }
            if let usage = parsed.usageMetadata {
                inputTokens = usage.promptTokenCount ?? inputTokens
                outputTokens = usage.candidatesTokenCount ?? outputTokens
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

    // MARK: - Wire format

    private func buildStreamingRequestBody(systemPrompt: String, messages: [LLMMessage]) -> [String: Any] {
        let contents: [[String: Any]] = buildGeminiContents(messages: messages)
        return [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": geminiGenerationConfig(),
        ]
    }
}

// MARK: - SSE payload

private struct StreamPayload: Decodable {
    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?

    var text: String? {
        candidates?.first?.content?.parts?
            .compactMap(\.text)
            .joined()
    }

    struct Candidate: Decodable {
        let content: Content?
    }
    struct Content: Decodable {
        let parts: [Part]?
    }
    struct Part: Decodable {
        let text: String?
    }
    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
    }
}
