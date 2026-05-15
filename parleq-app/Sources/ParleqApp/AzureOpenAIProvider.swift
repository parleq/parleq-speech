// AzureOpenAIProvider — Microsoft Azure OpenAI Service
// implementation of LLMProvider for users on Microsoft-locked
// enterprises (or anyone who already has an Azure subscription
// with OpenAI deployments). Hits OpenAI's GPT-4o family models
// hosted in Azure with Azure-side data handling, BAA agreements,
// EU residency, and the Microsoft enterprise contract.
//
// Auth path for v1: API key only. The user creates an OpenAI
// resource in Azure, deploys a model under it (e.g. "gpt-4o-mini"),
// copies the resource API key from the portal, and pastes it into
// Settings. The key lives in the macOS Keychain. Microsoft Entra
// ID (formerly Azure AD) auth via `az login` is a #21 step 5
// follow-up — same mechanism as VertexProvider's gcloud shell-out
// but with `az account get-access-token` instead.
//
// API: OpenAI Chat Completions schema, NOT Gemini's. SSE response
// chunks follow OpenAI's `choices[].delta.content` shape with a
// final `usage` block (or `data: [DONE]`).
//
// URL format:
//   https://{resource}.openai.azure.com/openai/deployments/
//     {deployment}/chat/completions?api-version={api-version}

import Foundation

final class AzureOpenAIProvider: LLMProvider, Sendable {
    /// Azure OpenAI auth mode. Maps 1:1 to `Config.azureAuthMode`.
    enum AuthMode: Sendable {
        /// Resource API key from the Azure portal, stored in the
        /// macOS Keychain. Sent as the `api-key` HTTP header.
        case apiKey
        /// Microsoft Entra ID OAuth bearer token, minted by shelling
        /// out to `az account get-access-token --resource
        /// https://cognitiveservices.azure.com/`. The `az` CLI must
        /// be on PATH and the user must have run `az login`.
        case azureAd
    }

    /// Underlying model family that a deployment serves. Drives the
    /// request-shape branching in `buildRequestBody` — reasoning
    /// models reject `max_tokens` and any non-default temperature,
    /// standard models expect both. Azure's API routes by deployment
    /// *name*, not model, so Parleq can't infer the family from what
    /// it sends — the user has to declare it. Maps 1:1 to
    /// `Config.azureFamily`.
    enum Family: Sendable {
        /// gpt-4o, gpt-4, gpt-3.5-turbo, etc. Use `max_tokens` +
        /// arbitrary `temperature`.
        case standard
        /// gpt-5*, o1*, o3*, o4*, o5*. Use `max_completion_tokens`,
        /// no `temperature` knob (only the default 1.0 is accepted).
        case reasoning
    }

    let model: String
    let family: Family
    let resource: String
    let deployment: String
    let apiVersion: String
    let authMode: AuthMode
    let session: URLSession
    private let tokenCache: AzureTokenCache?

    var providerName: String { "azure" }

    /// `model` is logged on each call (and stored on each ledger
    /// entry) but not actually sent over the wire — Azure routes by
    /// deployment name, not model name. We surface the configured
    /// model label to the rest of the codebase so usage breakdowns
    /// stay readable, but the deployment is what the API actually
    /// dispatches against. The `family` parameter is what governs
    /// request-shape: reasoning vs standard.
    init(
        model: String,
        family: Family,
        resource: String,
        deployment: String,
        apiVersion: String,
        authMode: AuthMode = .apiKey
    ) {
        self.model = model
        self.family = family
        self.resource = resource
        self.deployment = deployment
        self.apiVersion = apiVersion
        self.authMode = authMode
        self.session = URLSession.shared
        // Token cache is created up-front for azureAd mode and left
        // nil for apiKey mode so we don't carry an unused actor.
        self.tokenCache = (authMode == .azureAd) ? AzureTokenCache() : nil
    }

    func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        // Try once; on an auth-shaped failure in .azureAd mode,
        // invalidate the token cache and retry once. Matches the
        // Bedrock (#26) and Vertex (#30) patterns. Common case:
        // user launched Parleq with an expired/missing `az login`
        // session, ran `az login` externally, then dictated —
        // without the retry, Parleq pasted raw ASR until the user
        // manually quit and relaunched.
        //
        // The retry only fires when .azureAd is the active auth
        // mode AND we have a token cache to invalidate. In .apiKey
        // mode, an auth failure means the user's stored key is
        // wrong; re-issuing the same request won't fix that, and
        // the per-call .apiKey re-read from Keychain already picks
        // up post-Settings-edit updates. So .apiKey skips the
        // retry path entirely.
        do {
            try await attemptStreaming(
                systemPrompt: systemPrompt,
                messages: messages,
                onEvent: onEvent
            )
        } catch let firstError as LLMError
            where authMode == .azureAd
                && tokenCache != nil
                && Self.isAuthFailure(firstError) {
            FileHandle.standardError.write(
                "[parleq] azure: auth failure on first attempt (\(firstError.description)); invalidating Azure token cache and retrying once.\n"
                    .data(using: .utf8) ?? Data()
            )
            await tokenCache?.invalidate()
            try await attemptStreaming(
                systemPrompt: systemPrompt,
                messages: messages,
                onEvent: onEvent
            )
        }
    }

    /// Single attempt at the Azure streaming call. Extracted so the
    /// retry-once path above can replay it after invalidating the
    /// AD token cache. Same auth-mode branching as before.
    private func attemptStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        let body = buildRequestBody(systemPrompt: systemPrompt, messages: messages)
        let urlString = "https://\(Self.endpointHost(forResource: resource))/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)"
        guard let url = URL(string: urlString) else {
            throw LLMError.requestFailed(
                NSError(domain: "AzureOpenAIProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not build URL: \(urlString)"])
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Auth header depends on mode — apiKey uses Azure's
        // documented `api-key` header, azureAd uses the standard
        // `Authorization: Bearer <token>` with a token minted from
        // the user's `az login` session.
        switch authMode {
        case .apiKey:
            guard let apiKey = KeychainStore.readAzureAPIKey(), !apiKey.isEmpty else {
                throw LLMError.missingCredentials(
                    "No Azure OpenAI API key set. Open Settings → LLM → Set Azure API Key."
                )
            }
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        case .azureAd:
            guard let cache = tokenCache else {
                // Should be impossible — init() pairs cache presence
                // with authMode. Belt-and-suspenders error so a
                // future refactor that breaks the invariant fails
                // loudly rather than producing unauthenticated
                // requests.
                throw LLMError.missingCredentials(
                    "Internal error: Azure auth mode is azureAd but no token cache is configured."
                )
            }
            let token: String
            do {
                token = try await cache.getToken()
            } catch {
                throw LLMError.missingCredentials(
                    "Could not obtain an Azure access token: \(error). Run `az login` and retry."
                )
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
            // 401 in azureAd mode usually means the cached token
            // expired between cache check and request; invalidate
            // so the next dictation refreshes. The original error
            // bubbles up either way.
            if http.statusCode == 401, authMode == .azureAd, let cache = tokenCache {
                await cache.invalidate()
            }
            throw LLMError.badStatus(http.statusCode, String(snippet.prefix(400)))
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let parsed = try? JSONDecoder().decode(AzureStreamPayload.self, from: data) else { continue }

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

    /// Resolve the Settings "Resource" field to a fully-qualified
    /// hostname for URL construction. Three input shapes are
    /// supported so the user can paste whatever Azure shows them:
    ///
    /// 1. Bare resource name — `my-openai`. Builds to
    ///    `my-openai.openai.azure.com` (the classic Azure OpenAI
    ///    endpoint pattern, what users see when they create an
    ///    "Azure OpenAI Service" resource specifically).
    /// 2. Full hostname — `my-openai.cognitiveservices.azure.com` /
    ///    `my-openai.services.ai.azure.com` / `…openai.azure.com`.
    ///    Used as-is. This is what newer AI Foundry / multi-service
    ///    resources expose since the 2024 unification.
    /// 3. Full URL — `https://my-openai.cognitiveservices.azure.com/
    ///    openai/responses?api-version=…`. Scheme and path are
    ///    stripped; just the hostname is used. The path Microsoft
    ///    shows in the portal often points at the new Responses API,
    ///    which we deliberately don't use here — Parleq still does
    ///    Chat Completions, which is served at the same hostname.
    ///
    /// Detection rule: if the trimmed value contains a dot, treat
    /// as hostname; else treat as bare resource name. Azure resource
    /// names are alphanumeric + hyphens (no dots), so this is
    /// unambiguous.
    static func endpointHost(forResource raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutScheme = trimmed
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let hostOnly = withoutScheme.split(separator: "/", maxSplits: 1).first.map(String.init)
            ?? withoutScheme
        if hostOnly.contains(".") {
            return hostOnly
        }
        return "\(hostOnly).openai.azure.com"
    }

    private func buildRequestBody(systemPrompt: String, messages: [LLMMessage]) -> [String: Any] {
        // OpenAI Chat Completions wire format — system message is a
        // first-class message with role="system", not a separate
        // top-level field like Gemini's `systemInstruction`.
        var convo: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
        ]
        for msg in messages {
            convo.append([
                "role": msg.role == "model" ? "assistant" : msg.role,
                "content": msg.content,
            ])
        }
        var body: [String: Any] = [
            "messages": convo,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        // OpenAI's reasoning-model families (o-series, gpt-5) reject
        // `max_tokens` and require `max_completion_tokens` because
        // they distinguish the hidden reasoning channel from the
        // user-visible output budget. They also reject non-default
        // `temperature` (only 1.0 is allowed). Older families
        // (gpt-4o, gpt-4, gpt-3.5-turbo) still expect `max_tokens` +
        // arbitrary temperature.
        //
        // The family is declared explicitly in Settings (Standard or
        // Reasoning) rather than inferred from a model label —
        // Azure's API routes by deployment name, not model name, and
        // deployment names are user-chosen and arbitrary, so we
        // can't reliably parse the family from any string Parleq
        // sees on the wire.
        switch family {
        case .reasoning:
            body["max_completion_tokens"] = 1024
            // Don't set temperature — the API rejects anything other
            // than the default 1.0 for reasoning models.
        case .standard:
            body["max_tokens"] = 1024
            body["temperature"] = 0
        }
        return body
    }

    /// Provider-specific recovery hint for the cleanup-failure
    /// overlay (#27). Branches on auth mode: the API-key path
    /// points the user at Settings; the Entra ID path points at
    /// `az login`. The hint mentions the deployment + resource so
    /// the user knows which Azure resource the failure was
    /// against (helpful when Settings might list more than one).
    func cleanupFailureHint(for error: LLMError) -> String? {
        switch error {
        case .missingAPIKey:
            return "Azure API key missing. Open Settings → LLM → Set Azure API Key…"
        case .missingCredentials:
            switch authMode {
            case .apiKey:
                return "Azure API key rejected. Open Settings → LLM → Set Azure API Key…"
            case .azureAd:
                return "Azure CLI session expired or unavailable. Run `az login` and try again."
            }
        case .badStatus(let code, _) where code == 401 || code == 403:
            switch authMode {
            case .apiKey:
                return "Azure rejected the API key for resource `\(resource)`. Open Settings → LLM → Set Azure API Key… (or confirm the resource name)."
            case .azureAd:
                return "Azure rejected the AD token for resource `\(resource)` deployment `\(deployment)`. Re-run `az login` and confirm your tenant has access."
            }
        case .badStatus, .malformedResponse, .requestFailed:
            return nil
        }
    }

    /// True when an LLMError indicates an auth failure that may be
    /// recoverable by invalidating the AD token cache and re-minting.
    /// Used only on the .azureAd path; the caller in
    /// `generateStreaming` already gates on `authMode == .azureAd`
    /// because retry doesn't help on .apiKey (the per-call Keychain
    /// re-read already picks up Settings updates). 403 is not
    /// considered an auth-retry candidate — same reasoning as
    /// Vertex: an IAM-level denial can't be fixed by a fresh token
    /// for the same principal.
    private static func isAuthFailure(_ error: LLMError) -> Bool {
        switch error {
        case .missingCredentials:
            return true
        case .badStatus(let code, _):
            return code == 401
        case .missingAPIKey, .malformedResponse, .requestFailed:
            return false
        }
    }
}

// MARK: - Azure SSE payload

/// Azure OpenAI's streaming chunks follow OpenAI's chat-completions
/// schema. Each chunk has `choices[0].delta.content` (a partial
/// text string) and the final chunk(s) include a `usage` block when
/// `stream_options.include_usage` is set in the request.
private struct AzureStreamPayload: Decodable {
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

// MARK: - Azure AD token cache

/// Caches the Azure CLI-issued access token across requests so we
/// don't fork-exec on every dictation. Azure-issued tokens are
/// typically valid for 60–90 minutes; we expire ours conservatively
/// at 50 minutes to stay well clear of the boundary. Token storage
/// is process-memory only — the `az` CLI's own token cache lives
/// at `~/.azure/` and rotates per Microsoft's normal flow.
private actor AzureTokenCache {
    private var cached: (token: String, expires: Date)?
    private static let refreshAfter: TimeInterval = 50 * 60  // 50 min

    func getToken() async throws -> String {
        if let cached, cached.expires > Date() {
            return cached.token
        }
        let fresh = try await fetchFromAz()
        cached = (token: fresh, expires: Date().addingTimeInterval(Self.refreshAfter))
        return fresh
    }

    func invalidate() {
        cached = nil
    }

    private func fetchFromAz() async throws -> String {
        // `az account get-access-token` mints a token scoped to the
        // requested resource. For Azure OpenAI Service, the
        // resource is `https://cognitiveservices.azure.com/`. We
        // ask for `--query accessToken -o tsv` so stdout is just
        // the token string with a trailing newline — no JSON
        // parsing required.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "az", "account", "get-access-token",
                "--resource", "https://cognitiveservices.azure.com/",
                "--query", "accessToken",
                "-o", "tsv",
            ]
            // launchd-spawned apps inherit a sparse PATH that
            // doesn't include /opt/homebrew/bin (Apple Silicon
            // Homebrew) or /usr/local/bin (Intel Homebrew + most
            // official .pkg installers). Without augmentation,
            // exec("az") returns 127 even when `az --version`
            // works in the user's shell. Prepend the common
            // install dirs to PATH so the lookup succeeds
            // regardless of how Parleq was launched.
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
                            domain: "AzureOpenAIProvider.AzureTokenCache",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "az CLI returned empty output"]
                        ))
                    } else {
                        cont.resume(returning: trimmed)
                    }
                } else {
                    let stderr = String(data: stderrData ?? Data(), encoding: .utf8) ?? "<no stderr>"
                    cont.resume(throwing: NSError(
                        domain: "AzureOpenAIProvider.AzureTokenCache",
                        code: Int(proc.terminationStatus),
                        userInfo: [
                            NSLocalizedDescriptionKey: "az account get-access-token failed (exit \(proc.terminationStatus)): \(stderr)",
                        ]
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: NSError(
                    domain: "AzureOpenAIProvider.AzureTokenCache",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not exec az: \(error). Is the Azure CLI installed and on PATH?"]
                ))
            }
        }
    }
}
