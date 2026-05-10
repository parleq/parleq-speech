// LLMClient — Swift client for the Google AI direct API
// (generativelanguage.googleapis.com). Uses the streaming
// :streamGenerateContent SSE endpoint so the overlay can render
// text incrementally; a non-streaming :generateContent variant is
// kept for tests and headless callers.
//
// Operational invariant: `thinkingConfig.thinkingBudget` is ALWAYS
// set to 0 on every Gemini call. Default-on thinking on Gemini 2.5
// Flash costs 2-3x latency and 5-8x output tokens with no quality
// gain on the short-output cleanup task Parleq runs. The runtime
// API will not let the caller leave it unset.
//
// Auth is a single GEMINI_API_KEY. Loaded from the process
// environment, falling back to the macOS Keychain (set via the
// Settings UI's "Set Gemini API Key" sheet). There is no
// plaintext-on-disk fallback — see docs/SECURITY_REVIEW.md.

import Foundation

struct LLMResult {
    let text: String
    let latency: TimeInterval
    let inputTokens: Int
    let outputTokens: Int
}

/// Google AI direct API provider (generativelanguage.googleapis.com).
/// Auth is a single GEMINI_API_KEY resolved from the environment,
/// then the macOS Keychain. No plaintext-on-disk fallback.
final class LLMClient: LLMProvider, Sendable {
    static let defaultModel = "gemini-2.5-flash"
    private static let endpointBase = "https://generativelanguage.googleapis.com/v1beta"

    // Internal so the LLMStreaming extension (in a sibling file
    // within the same module) can read these without round-tripping
    // through Swift's stricter privacy model. They remain private
    // outside the module since the type is final.
    //
    // Note: there is intentionally NO `apiKey` field. The key is
    // resolved fresh on every request via `Self.resolveAPIKey()`
    // so that updates made through the Settings UI take effect on
    // the next dictation without requiring an app restart. Same
    // pattern we use for the custom dictionary (re-read per
    // utterance from `~/.parleq/config.json`).
    let model: String
    let session: URLSession

    var providerName: String { "gemini" }

    /// Construct a client. The Gemini API key is **not** captured
    /// at init — it's resolved per-request from env → Keychain so
    /// users can paste a key into Settings and have it work
    /// immediately. The init is therefore infallible; if no key is
    /// ever set, the per-request resolution throws
    /// `LLMError.missingAPIKey` and AppState's existing best-effort
    /// fallback pastes the raw ASR transcript.
    init(model: String = LLMClient.defaultModel) {
        self.model = model
        self.session = URLSession.shared
    }

    /// Resolve the API key for a single request. Throws when no
    /// key is configured anywhere — caller's catch path is
    /// expected to fall through to the raw-ASR fallback.
    func currentAPIKey() throws -> String {
        guard let key = Self.resolveAPIKey() else {
            throw LLMError.missingAPIKey
        }
        return key
    }

    /// Run a one-shot cleanup or refine call. `messages` is the
    /// conversation history; `systemPrompt` is the instruction
    /// preamble (cleanup vs refine).
    func generate(
        systemPrompt: String,
        messages: [LLMMessage]
    ) async throws -> LLMResult {
        let apiKey = try currentAPIKey()
        let body = buildRequestBody(systemPrompt: systemPrompt, messages: messages)
        // Auth via header rather than URL query parameter so the
        // key never lives in a URL string that any framework
        // logging path could capture. Google's API accepts both
        // `?key=...` and `x-goog-api-key:` — header is the safer
        // shape.
        let url = URL(string: "\(LLMClient.endpointBase)/models/\(model):generateContent")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw LLMError.requestFailed(error)
        }

        let started = Date()
        let respData: Data
        let response: URLResponse
        do {
            (respData, response) = try await session.data(for: request)
        } catch {
            throw LLMError.requestFailed(error)
        }
        let elapsed = -started.timeIntervalSinceNow

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse("response is not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: respData, encoding: .utf8) ?? "<\(respData.count) bytes>"
            throw LLMError.badStatus(http.statusCode, String(snippet.prefix(400)))
        }

        return try parseResponse(data: respData, latency: elapsed)
    }

    // MARK: - Request shape

    private func buildRequestBody(systemPrompt: String, messages: [LLMMessage]) -> [String: Any] {
        let contents: [[String: Any]] = messages.map { msg in
            [
                "role": msg.role == "assistant" ? "model" : "user",
                "parts": [["text": msg.content]],
            ]
        }
        return [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": [
                "temperature": 0,
                "maxOutputTokens": 1024,
                // INVARIANT: thinkingBudget=0 on every call.
                // Defaults-on thinking on Gemini 2.5 Flash costs
                // ~2.8x latency for no quality gain on this task.
                "thinkingConfig": ["thinkingBudget": 0],
            ],
        ]
    }

    // MARK: - Response parsing

    private func parseResponse(data: Data, latency: TimeInterval) throws -> LLMResult {
        struct Payload: Decodable {
            let candidates: [Candidate]?
            let usageMetadata: UsageMetadata?
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

        let parsed: Payload
        do {
            parsed = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw LLMError.malformedResponse("JSON decode: \(error)")
        }
        guard let cand = parsed.candidates?.first else {
            throw LLMError.malformedResponse("no candidates returned")
        }
        let text = (cand.content?.parts ?? []).compactMap(\.text).joined()
        if text.isEmpty {
            throw LLMError.malformedResponse("candidate has no text")
        }
        return LLMResult(
            text: text,
            latency: latency,
            inputTokens: parsed.usageMetadata?.promptTokenCount ?? 0,
            outputTokens: parsed.usageMetadata?.candidatesTokenCount ?? 0
        )
    }

    // MARK: - API key resolution

    /// Resolve the Gemini API key. Resolution order:
    ///   1. `GEMINI_API_KEY` environment variable — useful for CI,
    ///      `swift run` development, and dotfile-driven setups.
    ///   2. macOS Keychain (account "gemini-api-key" under service
    ///      "com.parleq.app"). The Settings UI is the canonical
    ///      writer; `KeychainStore.setGeminiAPIKey` puts the value
    ///      here.
    /// Returns nil when neither source has a key — the caller
    /// (`ParleqApp.main`) logs that LLM cleanup is disabled and the
    /// runtime falls through to pasting raw ASR.
    static func resolveAPIKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty {
            return key
        }
        if let key = KeychainStore.readGeminiAPIKey(), !key.isEmpty {
            return key
        }
        return nil
    }
}
