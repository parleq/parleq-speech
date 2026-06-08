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
        // gpt-4o family (gpt-4o, gpt-4o-mini, and dated snapshots like
        // gpt-4o-2024-11-20) supports vision. Audio-preview and
        // realtime-preview variants share the gpt-4o prefix but do NOT
        // accept image inputs through Chat Completions — exclude by
        // substring on the variant suffix.
        let isGPT4o = (m == "gpt-4o" || m.hasPrefix("gpt-4o-"))
        let isNonVisionPreview = m.contains("audio-preview") || m.contains("realtime-preview")
        if isGPT4o && !isNonVisionPreview { return true }
        // gpt-4.1 family supports vision (gpt-4.1, gpt-4.1-mini, and
        // their dated snapshots) EXCEPT gpt-4.1-nano which is text-only.
        let isGPT41 = (m == "gpt-4.1" || m.hasPrefix("gpt-4.1-"))
        let isGPT41Nano = (m == "gpt-4.1-nano" || m.hasPrefix("gpt-4.1-nano-"))
        if isGPT41 && !isGPT41Nano { return true }
        // o-series reasoning models (partial vision support).
        // Use the shared prefix-aware helper so dated snapshots (e.g.
        // "o1-2024-12-17") also report the correct capability.
        if isOpenAIReasoningModel(m) {
            // o1, o3, o4-mini (and their dated snapshots) support vision;
            // o1-mini and o3-mini (and their dated snapshots) are text-only.
            if m == "o1-mini" || m.hasPrefix("o1-mini-") { return false }
            if m == "o3-mini" || m.hasPrefix("o3-mini-") { return false }
            return true
        }
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

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse("response is not HTTP")
        }
        if !(200..<300).contains(http.statusCode) {
            // Drain up to 4KB of error body. Per-line iteration is far
            // faster than per-byte: a 400-char body via per-byte costs
            // thousands of awaits, while per-line costs one or two.
            // Matches the pattern used by other providers in this codebase.
            // Cap is enforced BEFORE appending to guarantee a hard 4096-byte
            // ceiling even when a single very long line (e.g. a minified
            // single-line JSON error envelope) would overshoot on append.
            let cap = 4096
            var buf = Data()
            for try await line in bytes.lines {
                guard buf.count < cap else { break }
                if let lineData = (line + "\n").data(using: .utf8) {
                    let remaining = cap - buf.count
                    buf.append(lineData.prefix(remaining))
                }
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
            // o-series models spend 1000-5000+ tokens internally on reasoning
            // before emitting any visible output. A 1024-token cap causes the
            // visible response to be truncated — often to empty — when the
            // model's reasoning budget alone consumes the ceiling. 4096 gives
            // ~2000-3000 tokens of headroom for reasoning plus ~1000-2000 for
            // the visible cleanup output, which is well above any real cleanup
            // response. Mirrors the existing Bedrock GPT-OSS treatment where
            // reasoning_effort:"low" is already set (CLAUDE.md hard invariant #4).
            //
            // #55: the maxOutputTokens knob can RAISE this for users who
            // need more visible output, but never below the 4096 reasoning
            // floor (a smaller cap would starve reasoning and truncate to
            // empty). Default 2048 < 4096 → floor wins, prior behavior kept.
            body["max_completion_tokens"] = max(4096, LLMTuning.current.maxOutputTokens)
            // low effort is appropriate for cleanup-style tasks (short
            // utterances); users who want medium/high can pick a non-reasoning
            // model. Omit temperature — reasoning models only accept 1.0.
            body["reasoning_effort"] = "low"
        } else {
            // #55: configurable max-tokens + temperature for the standard
            // family (reasoning models above reject non-1.0 temperature).
            body["max_tokens"] = LLMTuning.current.maxOutputTokens
            body["temperature"] = LLMTuning.current.temperature
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
        case .badStatus(429, _):
            return "OpenAI rate-limited or quota exceeded. Check usage at https://platform.openai.com/usage and add billing if you haven't yet."
        case .badStatus(404, _):
            return "OpenAI returned 404 — the configured model isn't available on this API key. Free-tier and trial keys typically can't access gpt-4o or o-series; verify access at https://platform.openai.com/account/limits."
        case .badStatus(let code, _) where code == 401 || code == 403:
            return "OpenAI rejected the API key. Open Settings → Cleanup → Set OpenAI API Key… and verify the key is current."
        case .badStatus, .malformedResponse, .requestFailed:
            return nil
        case .authPathBlocked(let msg):
            return msg
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
