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

final class VertexProvider: LLMProvider, Sendable {
    /// Vertex AI auth mode. Maps 1:1 to `Config.vertexAuthMode`.
    enum AuthMode: Sendable {
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
    }

    let model: String
    let project: String
    let region: String
    let authMode: AuthMode
    let session: URLSession
    private let tokenCache: TokenCache

    var providerName: String { "vertex" }

    init(model: String, project: String, region: String, authMode: AuthMode = .adc) {
        self.model = model
        self.project = project
        self.region = region
        self.authMode = authMode
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
        }
    }

    func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        let token: String
        do {
            token = try await tokenCache.getToken()
        } catch {
            let hint: String
            switch authMode {
            case .adc:
                hint = "Run `gcloud auth application-default login` and retry."
            case .serviceAccount:
                hint = "Verify the service-account JSON in Settings → LLM is valid and the SA has Vertex AI User role on the configured project."
            }
            throw LLMError.missingCredentials(
                "Could not obtain a Vertex AI access token: \(error). \(hint)"
            )
        }
        let body = buildStreamingRequestBody(systemPrompt: systemPrompt, messages: messages)
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
            // Token might be expired between cache check and request
            // — invalidate and let the next dictation refresh. We
            // still bubble up the original error so the user sees
            // the actual API response.
            if http.statusCode == 401 {
                await tokenCache.invalidate()
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

    private func buildStreamingRequestBody(systemPrompt: String, messages: [LLMMessage]) -> [String: Any] {
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
                "thinkingConfig": ["thinkingBudget": 0],
            ],
        ]
    }

    /// Provider-specific recovery hint for the cleanup-failure
    /// overlay (#27). Branches on auth mode so the user sees the
    /// command that matches their setup. The gcloud ADC path is
    /// the common case for personal use; the service-account path
    /// is the no-CLI corporate path.
    func cleanupFailureHint(for error: LLMError) -> String? {
        switch error {
        case .missingCredentials:
            switch authMode {
            case .adc:
                return "gcloud session unavailable or expired. Run `gcloud auth application-default login` and try again."
            case .serviceAccount:
                return "Service-account JSON rejected. Open Settings → LLM → Set Service Account JSON…"
            }
        case .missingAPIKey, .badStatus, .malformedResponse, .requestFailed:
            return nil
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
