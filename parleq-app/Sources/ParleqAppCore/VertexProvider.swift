// VertexProvider — Google Cloud Vertex AI implementation of
// LLMProvider for users on GCP-locked enterprises (or anyone with
// gcloud auth already set up). Hits the same Gemini models as the
// direct LLMClient path, but on the Vertex AI control plane —
// gives you GCP-side data residency, audit logs, IAM, and quota
// management instead of a standalone Google AI Studio API key.
//
// Auth: today, gcloud Application Default Credentials only —
// shells out to `gcloud auth application-default print-access-token`
// to obtain an OAuth bearer, with a 50-minute TTL cache so we
// don't fork-exec on every dictation. Service-account JSON paste
// (#21 step 4 follow-up) and Vertex API keys are also possible
// but require either JWT signing in Swift or an alternate auth
// header path; deferred until the gcloud path is in user hands.
//
// API: streamGenerateContent on the Vertex Gemini publisher
// endpoint, SSE response identical in shape to the direct API
// (same StreamPayload fits, hence we reuse LLMStreaming's parser
// indirectly through this file's local copy).
//
// URL format:
//   https://{region}-aiplatform.googleapis.com/v1/projects/{project}/
//          locations/{region}/publishers/google/models/{model}:streamGenerateContent

import Foundation

public final class VertexProvider: LLMProvider, Sendable {
    /// Vertex AI auth mode. Maps 1:1 to `Config.vertexAuthMode`.
    public enum AuthMode: Sendable {
        /// gcloud Application Default Credentials. Shells out to
        /// `gcloud auth application-default print-access-token`
        /// per session. Requires the `gcloud` CLI on PATH and the
        /// user to have run `gcloud auth application-default login`.
        case adc
        /// Pasted service-account JSON key. Mints OAuth tokens
        /// directly via JWT-bearer flow against Google's token
        /// endpoint — no `gcloud` required, no interactive login.
        /// JSON is stored in the macOS Keychain (see
        /// `KeychainStore.readVertexServiceAccountJSON`).
        case serviceAccount
        /// Enterprise OIDC federation (Workforce Identity Federation).
        /// The OAuth bearer is a federated access token minted from the
        /// corporate OIDC ID token via `CachedExchange`. Every request
        /// in this mode also carries `x-goog-user-project` so GCP bills
        /// / quotas the federated call against the configured project
        /// (workforce principals have no implicit project).
        case oidcFederation
        /// Native Google sign-in via the OIDC engine ("Sign in with
        /// Google, dictate with Gemini" — no broker). The OAuth ACCESS
        /// token from the OIDC sign-in (granted the
        /// `https://www.googleapis.com/auth/cloud-platform` scope) is a
        /// valid Vertex bearer DIRECTLY — exactly what gcloud ADC produces,
        /// done in-app. No exchanger, no STS/workforce hop: the bearer is
        /// `session.accessToken()`. GCP federation can't use Google as a
        /// workforce IdP, so this sidesteps federation entirely. Like
        /// `.oidcFederation`, every request carries `x-goog-user-project`
        /// (user-credential quota attribution against the configured
        /// project).
        case googleOAuth
    }

    public let model: String
    public let project: String
    public let region: String
    /// Region used specifically for Anthropic publisher calls (Claude
    /// models). Kept separate from `region` (Gemini calls) so users
    /// can route Gemini through us-central1 and Claude through us-east5
    /// without a wholesale region switch that would affect cost, latency,
    /// and data-residency for non-Claude calls. Defaults to "us-east5".
    public let anthropicRegion: String
    public let authMode: AuthMode
    public let session: URLSession
    /// gcloud-ADC / service-account token cache. nil in `.oidcFederation`
    /// mode: there the `CachedExchange` IS the cache (it owns the federated
    /// token's TTL, refresh-ahead, and single-flight), so layering a second
    /// TokenCache on top would be a redundant cache that sign-out's
    /// `CachedExchange.invalidate()` couldn't reach — letting a signed-out
    /// federated token keep serving. We read through `oidcExchange` directly
    /// every call instead (see `getAccessToken`).
    private let tokenCache: TokenCache?
    /// Enterprise OIDC federation: the per-request source of a
    /// Workforce Identity Federation access token. Non-nil only in
    /// `.oidcFederation` mode. When set, every Vertex REST call also
    /// emits `x-goog-user-project`.
    private let oidcExchange: CachedExchange<GCPWorkforceExchanger>?
    /// Native Google sign-in session for `.googleOAuth` mode. Non-nil only
    /// in that mode. The bearer is `session.accessToken()` — no exchanger,
    /// no STS hop. The session owns the token cache (TTL + refresh-ahead +
    /// single-flight), so sign-out's clear of the session is the single
    /// source of truth for "this access is gone"; there's no second layer.
    private let oidcSession: OIDCSession?

    /// True when this provider must add `x-goog-user-project` to every
    /// request. Federated workforce principals (`.oidcFederation`) carry no
    /// implicit quota/billing project; native Google user credentials
    /// (`.googleOAuth`) attribute quota/billing to the configured project
    /// rather than the token's home project — both want the explicit header.
    private var usesUserProjectHeader: Bool {
        authMode == .oidcFederation || authMode == .googleOAuth
    }

    public var providerName: String { "vertex" }

    public var supportsVision: Bool {
        // Vertex hosts both Gemini and Anthropic Claude models.
        // Claude models (any ID containing "claude") are all vision-
        // capable on Vertex — same capability as on Bedrock. The
        // Anthropic publisher is only available in specific Vertex
        // regions (us-east5, europe-west1). With the separate
        // `anthropicRegion` config field (issue #34), Claude is now
        // in the curated Vertex dropdown; the URL is built using
        // `anthropicRegion` instead of `region` so Gemini region
        // settings are unaffected.
        // Gemini: 2.5 Flash + Pro are multimodal; Flash-Lite is
        // text-only. Gemini 1.5 family was retired from Vertex in
        // 2025 and is no longer recognized here.
        if model.lowercased().contains("claude") { return true }
        let m = model.lowercased()
        switch m {
        case "gemini-2.5-flash", "gemini-2.5-pro":
            return true
        case "gemini-2.5-flash-lite":
            return false
        default:
            return false   // conservative; explicit allowlist
        }
    }

    public init(
        model: String,
        project: String,
        region: String,
        anthropicRegion: String = "us-east5",
        authMode: AuthMode = .adc,
        oidcExchange: CachedExchange<GCPWorkforceExchanger>? = nil,
        oidcSession: OIDCSession? = nil
    ) {
        self.model = model
        self.project = project
        self.region = region
        self.anthropicRegion = anthropicRegion
        self.authMode = authMode
        self.oidcExchange = oidcExchange
        self.oidcSession = oidcSession
        self.session = URLSession.shared
        // Build the per-mode token-mint closure once and hand it to
        // the cache. The cache itself is mode-agnostic — it just
        // calls the closure when fresh credentials are needed.
        switch authMode {
        case .adc:
            self.tokenCache = TokenCache(fetch: {
                let token = try await fetchAccessTokenViaGcloud()
                // gcloud-issued tokens are typically valid for 60 min;
                // 3600 s is the safe assumption when stdout doesn't
                // give us the actual expiry.
                return (token: token, expiresIn: 3600)
            })
        case .serviceAccount:
            self.tokenCache = TokenCache(fetch: {
                guard let json = KeychainStore.readVertexServiceAccountJSON(),
                      !json.isEmpty else {
                    throw NSError(
                        domain: "VertexProvider",
                        code: 100,
                        userInfo: [NSLocalizedDescriptionKey: "No service-account JSON in Keychain. Open Settings → LLM → Set Service Account JSON."]
                    )
                }
                let key = try ServiceAccountKey.parse(json)
                let result = try await mintAccessTokenFromServiceAccount(key)
                return (token: result.token, expiresIn: result.expiresIn)
            })
        case .oidcFederation:
            // No TokenCache: the CachedExchange IS the cache (TTL +
            // refresh-ahead + single-flight all live there). `getAccessToken`
            // reads through `oidcExchange.credentials()` every call so
            // sign-out's `CachedExchange.invalidate()` is the single source of
            // truth for "this federated access is gone" — no redundant layer
            // to clear.
            self.tokenCache = nil
        case .googleOAuth:
            // No TokenCache: the OIDCSession owns the access-token cache
            // (TTL + refresh-ahead + single-flight all live in the session).
            // `getAccessToken` reads through `session.accessToken()` every
            // call, so a sign-out that clears the session's cached tokens is
            // the single source of truth — no redundant layer to clear.
            self.tokenCache = nil
        }
    }

    /// Resolve the OAuth bearer for the current auth mode. ADC and
    /// service-account read through the per-mode `TokenCache`; oidcFederation
    /// reads through the `CachedExchange` directly (it owns the cache), so a
    /// sign-out that invalidates the exchange takes effect on the next call.
    private func getAccessToken() async throws -> String {
        if authMode == .oidcFederation {
            guard let exchange = oidcExchange else {
                throw LLMError.missingCredentials(
                    "Sign in to your organization in Settings \u{2192} Company Account."
                )
            }
            return try await exchange.credentials().token
        }
        if authMode == .googleOAuth {
            // The OAuth access token from the Google sign-in IS the Vertex
            // bearer (cloud-platform scope) — no exchange. The session's
            // accessToken() owns freshness + single-flight refresh and
            // throws the OIDC taxonomy, which the catch in attemptStreaming
            // maps to fail-closed missingCredentials with the Company
            // Account copy.
            guard let session = oidcSession else {
                throw LLMError.missingCredentials(
                    "Sign in to your organization in Settings \u{2192} Company Account."
                )
            }
            return try await session.accessToken()
        }
        guard let tokenCache else {
            throw LLMError.missingCredentials("No token cache for auth mode \(authMode).")
        }
        return try await tokenCache.getToken()
    }

    /// Invalidate the active token cache for the current auth mode. ADC /
    /// service-account clear the `TokenCache`; oidcFederation invalidates the
    /// `CachedExchange` (its only cache) so the next call re-exchanges.
    private func invalidateToken() async {
        if authMode == .oidcFederation {
            await oidcExchange?.invalidate()
        } else if authMode == .googleOAuth {
            // The OIDCSession owns the access-token cache. Drop ONLY the cached
            // access token so the retry's getAccessToken() forces a silent
            // refresh that mints a fresh token — covering the rare case where a
            // still-fresh-by-TTL token was revoked server-side and Vertex 401s
            // it. This is a pure cache-drop: id_token / refresh token / epoch
            // are untouched, so the session stays validly signed in.
            await oidcSession?.invalidateAccessToken()
        } else {
            await tokenCache?.invalidate()
        }
    }

    public func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        // Try once; on an auth-shaped failure (token mint failed or
        // server returned 401), invalidate the token cache and retry
        // once. Common case for ADC mode: user launched Parleq, then
        // their gcloud session expired or got refreshed externally
        // via `gcloud auth application-default login`. The first
        // attempt sees the stale token, fails 401 (server rejected),
        // we invalidate, the retry's getToken() re-shells out to
        // gcloud which now reads the refreshed
        // application_default_credentials.json — and the retry
        // succeeds. Matches the Bedrock pattern from #26 / #30.
        //
        // Auth failures happen before any chunk is emitted (the HTTP
        // status check fires first), so the onEvent callback hasn't
        // run yet on the failed attempt — safe to replay the whole
        // call without sending duplicate chunks to the overlay.
        do {
            try await attemptStreaming(
                systemPrompt: systemPrompt,
                messages: messages,
                onEvent: onEvent
            )
        } catch let firstError as LLMError where Self.isAuthFailure(firstError) {
            FileHandle.standardError.write(
                "[parleq] vertex: auth failure on first attempt (\(firstError.logSafeDescription)); invalidating token cache and retrying once.\n"
                    .data(using: .utf8) ?? Data()
            )
            await invalidateToken()
            try await attemptStreaming(
                systemPrompt: systemPrompt,
                messages: messages,
                onEvent: onEvent
            )
        }
    }

    /// Single attempt at the Vertex streaming call. Extracted so the
    /// retry-once path above can replay it after invalidating the
    /// token cache. Dispatches to the Claude or Gemini path based on
    /// the model ID; no auth retry happens at this layer.
    private func attemptStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        let token: String
        do {
            token = try await getAccessToken()
        } catch {
            // Enterprise OIDC federation fails closed with the Company
            // Account pointer (and the taxonomy copy when the cache
            // surfaced an OIDCAuthFailure), not a gcloud/SA hint.
            // Differentiated copy surfaces via the Company Account doctor
            // (hopStatus); the overlay banner shows the generic
            // cleanupFailureHint pointer.
            if authMode == .oidcFederation || authMode == .googleOAuth {
                if let f = error as? OIDCAuthFailure {
                    throw LLMError.missingCredentials(
                        f.userCopy + " (Settings \u{2192} Company Account)"
                    )
                }
                throw LLMError.missingCredentials(
                    "Sign in to your organization in Settings \u{2192} Company Account."
                )
            }
            let hint: String
            switch authMode {
            case .adc:
                hint = "Run `gcloud auth application-default login` and retry."
            case .serviceAccount:
                hint = "Verify the service-account JSON in Settings → LLM is valid and the SA has Vertex AI User role on the configured project."
            case .oidcFederation, .googleOAuth:
                hint = ""   // handled above
            }
            throw LLMError.missingCredentials(
                "Could not obtain a Vertex AI access token: \(error). \(hint)"
            )
        }

        if isClaudeModel(model) {
            try await attemptClaudeStreaming(
                token: token,
                systemPrompt: systemPrompt,
                messages: messages,
                onEvent: onEvent
            )
        } else {
            try await attemptGeminiStreaming(
                token: token,
                systemPrompt: systemPrompt,
                messages: messages,
                onEvent: onEvent
            )
        }
    }

    /// True when the model ID belongs to the Anthropic Claude family.
    /// Claude IDs on Vertex use the `<base>@<version>` format, e.g.
    /// `claude-sonnet-4-5@20250929`. Checking for "claude" substring
    /// is sufficient and forward-compatible with future model names.
    private func isClaudeModel(_ id: String) -> Bool {
        id.lowercased().contains("claude")
    }

    // MARK: - Gemini path (publishers/google)

    /// Stream via Vertex's Gemini publisher endpoint
    /// (publishers/google/models/<model>:streamGenerateContent).
    /// Request/response shape is identical to the direct Gemini API.
    private func attemptGeminiStreaming(
        token: String,
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        let body = buildGeminiRequestBody(systemPrompt: systemPrompt, messages: messages)
        let urlString = "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/google/models/\(model):streamGenerateContent?alt=sse"
        guard let url = URL(string: urlString) else {
            throw LLMError.requestFailed(
                NSError(domain: "VertexProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not build URL: \(urlString)"])
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Workforce Identity Federation principals carry no implicit
        // quota/billing project, and native Google user credentials must
        // attribute quota/billing to the configured project — so both the
        // .oidcFederation and .googleOAuth modes name it explicitly. ADC and
        // service-account principals already resolve a project.
        if usesUserProjectHeader {
            request.setValue(project, forHTTPHeaderField: "x-goog-user-project")
        }
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
            var buf = Data()
            for try await byte in bytes {
                buf.append(byte)
                if buf.count > 4096 { break }
            }
            let snippet = String(data: buf, encoding: .utf8) ?? "<\(buf.count) bytes>"
            // Token might be expired between cache check and request
            // — invalidate and let the next dictation refresh. We
            // still bubble up the original error so the user sees
            // the actual API response.
            if http.statusCode == 401 {
                await invalidateToken()
            }
            throw LLMError.badStatus(http.statusCode, String(snippet.prefix(400)))
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let parsed = try? JSONDecoder().decode(VertexStreamPayload.self, from: data) else { continue }

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

    // MARK: - Anthropic Claude path (publishers/anthropic)

    /// Stream via Vertex's Anthropic publisher endpoint
    /// (publishers/anthropic/models/<model>:streamRawPredict).
    ///
    /// Vertex's Anthropic endpoint accepts the Anthropic Messages API
    /// body shape (anthropic-native, not Bedrock Converse) with one
    /// Vertex-specific wrapper field: `"anthropic_version":
    /// "vertex-2023-10-16"`. The streaming response is raw SSE with
    /// Anthropic-native event types (message_start, content_block_delta,
    /// etc.) — no Bedrock binary event-stream envelope.
    ///
    /// OAuth bearer token is the same as for the Gemini path — the
    /// Vertex SA or ADC principal must have the `aiplatform.user` role.
    /// No additional IAM role is needed specifically for the Anthropic
    /// publisher endpoint.
    private func attemptClaudeStreaming(
        token: String,
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        let body = buildClaudeRequestBody(systemPrompt: systemPrompt, messages: messages)
        // percent-encode the model ID; Vertex Claude IDs contain `@`
        // (e.g. `claude-sonnet-4-5@20250929`) which must be encoded in
        // URL path segments.
        let encodedModel = model.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? model
        let urlString = "https://\(anthropicRegion)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(anthropicRegion)/publishers/anthropic/models/\(encodedModel):streamRawPredict"
        guard let url = URL(string: urlString) else {
            throw LLMError.requestFailed(
                NSError(domain: "VertexProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not build Claude URL: \(urlString)"])
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // See attemptGeminiStreaming: federated workforce principals and
        // native Google user credentials both need the explicit
        // quota/billing project header.
        if usesUserProjectHeader {
            request.setValue(project, forHTTPHeaderField: "x-goog-user-project")
        }
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
            var buf = Data()
            for try await byte in bytes {
                buf.append(byte)
                if buf.count > 4096 { break }
            }
            let snippet = String(data: buf, encoding: .utf8) ?? "<\(buf.count) bytes>"
            if http.statusCode == 401 {
                await invalidateToken()
            }
            throw LLMError.badStatus(http.statusCode, String(snippet.prefix(400)))
        }

        // Parse Anthropic-native SSE stream. Vertex's streamRawPredict
        // emits raw SSE lines without any binary framing (unlike
        // Bedrock's vended-event-stream envelope), so we parse directly
        // from the text lines:
        //
        //   event: message_start         → carries input token count
        //   event: content_block_delta   → carries text delta chunks
        //   event: message_delta         → carries output token count
        //   event: message_stop          → stream end marker (no data)
        //
        // We track the previous event type to interpret the following
        // `data:` line correctly, then extract the relevant fields.
        var currentEvent = ""
        for try await line in bytes.lines {
            if line.hasPrefix("event: ") {
                currentEvent = String(line.dropFirst("event: ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            switch currentEvent {
            case "content_block_delta":
                // delta.type == "text_delta" carries the text chunk.
                if let delta = json["delta"] as? [String: Any],
                   (delta["type"] as? String) == "text_delta",
                   let text = delta["text"] as? String,
                   !text.isEmpty {
                    if ttft == 0 { ttft = -started.timeIntervalSinceNow }
                    onEvent(.chunk(text))
                }
            case "message_start":
                // message.usage.input_tokens carries the prompt token count.
                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any],
                   let input = usage["input_tokens"] as? Int {
                    inputTokens = input
                }
            case "message_delta":
                // usage.output_tokens carries the completion token count.
                if let usage = json["usage"] as? [String: Any],
                   let output = usage["output_tokens"] as? Int {
                    outputTokens = output
                }
            default:
                break
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

    /// Build the Anthropic Messages API request body for Vertex's
    /// Anthropic publisher endpoint. Uses the anthropic-native content-
    /// block schema (NOT Bedrock Converse):
    ///   text   → {"type": "text", "text": s}
    ///   image  → {"type": "image", "source": {"type": "base64", …}}
    ///
    /// The `"anthropic_version": "vertex-2023-10-16"` field is
    /// required by Vertex; without it the endpoint returns 400.
    private func buildClaudeRequestBody(systemPrompt: String, messages: [LLMMessage]) -> [String: Any] {
        return [
            "anthropic_version": "vertex-2023-10-16",
            "system": systemPrompt,
            "messages": buildAnthropicNativeMessages(messages),
            // #55: max output tokens (temperature deliberately NOT sent
            // on the Anthropic native path — preserving prior behavior).
            "max_tokens": LLMTuning.current.maxOutputTokens,
            "stream": true,
        ]
    }

    /// Serialize [LLMMessage] to the Anthropic-native Messages API
    /// `messages` array. This is the schema Anthropic's own API and
    /// Vertex's Anthropic publisher endpoint both accept — distinct
    /// from Bedrock's Converse schema (which uses `{"text": s}` and
    /// `{"image": {"format": ..., "source": {"bytes": ...}}}`).
    private func buildAnthropicNativeMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        return messages.map { msg in
            let content: [[String: Any]] = msg.parts.compactMap { part in
                switch part {
                case .text(let s):
                    return ["type": "text", "text": s]
                case .image(let data, let mime):
                    return [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": mime,
                            "data": data.base64EncodedString(),
                        ],
                    ]
                }
            }
            return ["role": msg.role, "content": content]
        }
    }

    /// Build the Gemini request body for Vertex's Google publisher
    /// endpoint (publishers/google/models/<model>:streamGenerateContent).
    private func buildGeminiRequestBody(systemPrompt: String, messages: [LLMMessage]) -> [String: Any] {
        let contents: [[String: Any]] = buildVertexContents(messages: messages)
        let tuning = LLMTuning.current
        var generationConfig: [String: Any] = [
            "temperature": tuning.temperature,
            "maxOutputTokens": tuning.maxOutputTokens,
        ]
        // Gemini 2.5 Flash and Flash-Lite accept thinkingBudget=0 to
        // disable chain-of-thought tokens — cheaper and faster for the
        // short-output cleanup task Parleq runs (invariant #3). Gemini
        // 2.5 Pro requires thinking (rejects 0 with a 400) but accepts
        // its 128-token FLOOR — without an explicit budget Pro uses the
        // dynamic default and routinely burns thousands of thinking
        // tokens (10-20s TTFT) deliberating over a punctuation task.
        // The floor keeps Pro legal while cutting deliberation to the
        // minimum the model allows.
        // #55: thinkingBudget override sent verbatim when set; otherwise
        // the built-in Flash(0)/Pro(128) split.
        generationConfig["thinkingConfig"] = [
            "thinkingBudget": tuning.resolvedThinkingBudget(forModel: model)
        ]
        return [
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": generationConfig,
        ]
    }

    /// Serialize [LLMMessage] to Vertex Gemini's `contents` array. The
    /// request body shape is wire-compatible with the direct Gemini API:
    /// text → `{"text": s}`, image → `{"inlineData": {"mimeType": …,
    /// "data": base64}}`.
    private func buildVertexContents(messages: [LLMMessage]) -> [[String: Any]] {
        return messages.map { msg in
            let parts: [[String: Any]] = msg.parts.map { part in
                switch part {
                case .text(let s):
                    return ["text": s]
                case .image(let data, let mime):
                    return ["inlineData": [
                        "mimeType": mime,
                        "data": data.base64EncodedString(),
                    ]]
                }
            }
            return [
                "role": msg.role == "assistant" ? "model" : "user",
                "parts": parts,
            ]
        }
    }

    /// Provider-specific recovery hint for the cleanup-failure
    /// overlay (#27). Branches on auth mode so the user sees the
    /// command that matches their setup. The gcloud ADC path is
    /// the common case for personal use; the service-account path
    /// is the no-CLI corporate path.
    ///
    /// Both .missingCredentials (token mint failed) and
    /// .badStatus(401|403) (token minted fine but Vertex rejected
    /// the principal — service account lacks `aiplatform.user`,
    /// ADC token issued for the wrong project, IAM policy denial)
    /// map onto the same recovery path per auth mode, so we don't
    /// branch the copy further. Mentioning the project in the hint
    /// helps users with multiple gcloud configurations spot the
    /// "wrong project" case.
    public func cleanupFailureHint(for error: LLMError) -> String? {
        switch error {
        case .missingCredentials:
            return authRecoveryHint
        case .badStatus(let code, _) where code == 401 || code == 403:
            return authRecoveryHint
        case .missingAPIKey, .badStatus, .malformedResponse, .requestFailed:
            return nil
        case .authPathBlocked(let msg):
            return msg
        }
    }

    public func cleanupFailureIsReauthable(for error: LLMError) -> Bool {
        // Mirror the exact error shapes authRecoveryHint surfaces the
        // "Sign in to your organization" copy for, but only in the OIDC
        // modes (oidcFederation / googleOAuth). ADC + service-account
        // failures are not recoverable by an org sign-in.
        guard authMode == .oidcFederation || authMode == .googleOAuth else { return false }
        switch error {
        case .missingCredentials:
            return true
        case .badStatus(let code, _):
            // 401 = the IdP token was rejected → a fresh sign-in can
            // plausibly fix it. 403 is NOT re-authable: a Vertex 403
            // usually means the federated principal lacks the
            // `aiplatform.user` role (see isAuthFailure's comment), which
            // re-minting a token does not change — surfacing a clickable
            // sign-in there would loop with no progress. The static hint
            // still points at Company Account; only the tappable
            // affordance is withheld.
            return code == 401
        case .missingAPIKey, .malformedResponse, .requestFailed, .authPathBlocked:
            return false
        }
    }

    /// Shared auth-mode-aware copy for the two auth-failure shapes
    /// `cleanupFailureHint` recognizes. Hoisted so the
    /// .missingCredentials and .badStatus(401|403) branches stay in
    /// lockstep without duplicating the strings.
    private var authRecoveryHint: String {
        switch authMode {
        case .adc:
            return "Vertex rejected gcloud credentials for project `\(project)`. Re-run `gcloud auth application-default login`, confirm the principal has the `aiplatform.user` role, and check that `gcloud config get-value project` matches."
        case .serviceAccount:
            return "Vertex rejected the service-account credentials for project `\(project)`. Open Settings → LLM → Set Service Account JSON… (and confirm the service account has the `aiplatform.user` role in this project)."
        case .oidcFederation, .googleOAuth:
            return "Sign in to your organization in Settings → Company Account."
        }
    }

    /// True when an LLMError indicates an auth failure that may be
    /// recoverable by invalidating the token cache and re-minting.
    /// `.missingCredentials` covers the "gcloud print-access-token
    /// itself failed" case (rare but possible if the user fixed
    /// something between attempts) and the malformed-creds case.
    /// 401 = server rejected our token; re-mint may pick up
    /// post-`gcloud auth application-default login` credentials.
    /// 403 deliberately NOT retried: it usually means the IAM
    /// principal lacks the role, which re-minting won't fix — the
    /// user needs to grant the role on the GCP console. We don't
    /// want to waste a second gcloud shell-out on a known-doomed
    /// retry. Non-auth errors (network, malformed JSON, etc.)
    /// don't benefit from token invalidation either.
    private static func isAuthFailure(_ error: LLMError) -> Bool {
        switch error {
        case .missingCredentials:
            return true
        case .badStatus(let code, _):
            return code == 401
        case .missingAPIKey, .malformedResponse, .requestFailed, .authPathBlocked:
            return false
        }
    }
}

// MARK: - Token cache

/// Caches an OAuth access token across requests so we don't redo
/// the mint flow on every dictation. The cache is mode-agnostic —
/// the per-mode "how do I mint a fresh token" logic lives in the
/// closure passed to init. Both gcloud and service-account paths
/// produce a token + expires-in pair; the cache subtracts a 10-min
/// safety margin from the reported expiry so we don't hand out
/// tokens that are about to die.
private actor TokenCache {
    private var cached: (token: String, expires: Date)?
    private let fetch: @Sendable () async throws -> (token: String, expiresIn: TimeInterval)

    init(fetch: @Sendable @escaping () async throws -> (token: String, expiresIn: TimeInterval)) {
        self.fetch = fetch
    }

    func getToken() async throws -> String {
        if let cached, cached.expires > Date() {
            return cached.token
        }
        let result = try await fetch()
        // 10-min headroom under the reported expiry. Floor at 60 s
        // so a misbehaving server that reports a tiny expires_in
        // doesn't crash to negative TTL.
        let safeTTL = max(60, result.expiresIn - 600)
        cached = (token: result.token, expires: Date().addingTimeInterval(safeTTL))
        return result.token
    }

    func invalidate() {
        cached = nil
    }
}

/// Shell out to `gcloud auth application-default print-access-token`.
/// File-private so VertexProvider's TokenCache closure can call it
/// without the cache itself being gcloud-specific. The command
/// writes a single newline-terminated token to stdout. If gcloud
/// isn't installed or the user isn't authenticated, exit code is
/// non-zero and stderr explains why; we surface stderr in the
/// thrown error so the user gets actionable info.
private func fetchAccessTokenViaGcloud() async throws -> String {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "gcloud", "auth", "application-default", "print-access-token",
        ]
        // See augmentedShellEnvironment for why — launchd-spawned
        // apps need PATH augmentation to find `gcloud` installed
        // via Homebrew.
        process.environment = augmentedShellEnvironment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { proc in
            let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            if proc.terminationStatus == 0 {
                let trimmed = String(data: stdoutData ?? Data(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.isEmpty {
                    cont.resume(throwing: NSError(
                        domain: "VertexProvider.gcloud",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "gcloud returned empty output"]
                    ))
                } else {
                    cont.resume(returning: trimmed)
                }
            } else {
                let stderr = String(data: stderrData ?? Data(), encoding: .utf8) ?? "<no stderr>"
                cont.resume(throwing: NSError(
                    domain: "VertexProvider.gcloud",
                    code: Int(proc.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: "gcloud auth print-access-token failed (exit \(proc.terminationStatus)): \(stderr)",
                    ]
                ))
            }
        }
        do {
            try process.run()
        } catch {
            cont.resume(throwing: NSError(
                domain: "VertexProvider.gcloud",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not exec gcloud: \(error). Is the Google Cloud SDK installed and on PATH?"]
            ))
        }
    }
}

// MARK: - Vertex SSE payload

/// Vertex's streamGenerateContent payload is wire-compatible with
/// the direct Gemini API's payload at the response-shape level —
/// same candidates / content / parts / text / usageMetadata
/// hierarchy. Decoded as its own type rather than reusing
/// LLMStreaming's private StreamPayload because Swift can't
/// reach into another file's private types.
private struct VertexStreamPayload: Decodable {
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
