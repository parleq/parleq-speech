// BedrockProvider — AWS Bedrock implementation of LLMProvider for
// work machines that can't reach Google's API directly.
//
// Auth: delegates to the user's existing AWS CLI session. Today
// `BedrockProvider` calls Soto's `.sso()` credential provider
// specifically — that handles the OAuth refresh on the modern
// sso-session format, so once the user has logged in via
// `aws sso login --profile <name>` on their work machine, Parleq
// picks up the credentials automatically. When the SSO session
// expires, the surfaced error tells the user exactly which command
// to run. Multi-mode auth — Bedrock API keys, static IAM access
// keys, environment variables, instance profiles — is tracked in
// issue #21.
//
// API: ConverseStream (the Bedrock unified-message API). Events
// arrive as a Soto `AWSEventStream`; we filter to text-content
// deltas + metadata and map them onto our LLMStreamEvent shape.
//
// Models: two configurable defaults today —
//   - `openai.gpt-oss-120b-1:0` with `reasoning_effort: "low"` —
//     the fastest viable model on Bedrock for short cleanup
//     prompts. The reasoning_effort knob is required for gpt-oss
//     models to suppress the 200+-token hidden reasoning channel
//     that's otherwise emitted before the actual response.
//   - `us.anthropic.claude-haiku-4-5-20251001-v1:0` — balanced
//     accuracy / latency choice, no reasoning_effort field.
// The reasoning_effort knob is per-model; we dispatch on the model
// ID prefix rather than expose the toggle as a separate config
// knob.

import Foundation
import Logging
import SotoBedrockRuntime
import SotoCore

public final class BedrockProvider: LLMProvider, @unchecked Sendable {
    /// Bedrock credential resolution mode. Maps 1:1 to
    /// `Config.awsAuthMode`. Bedrock API keys (the newer scoped
    /// bearer tokens AWS shipped in 2024) need bearer auth rather
    /// than SigV4, which Soto doesn't model directly — adding them
    /// requires a custom HTTP path and is left for a follow-up
    /// (#21 step 3 follow-up).
    public enum AuthMode: Sendable {
        /// Resolve credentials from the user's AWS CLI session
        /// (Soto's `.sso()` provider against `~/.aws/config` plus
        /// `~/.aws/sso/cache/`). Existing default.
        case sso
        /// Use access keys + secret + optional session token stored
        /// in the macOS Keychain (`KeychainStore.AWSStaticCredentials`).
        case `static`
    }

    public let model: String
    public let region: String
    public let profileName: String?
    public let authMode: AuthMode

    public var providerName: String { "bedrock" }

    public var supportsVision: Bool {
        // All Claude models on Bedrock support vision.
        // Amazon Nova Pro + Nova Lite are multimodal; Nova Micro is
        // text-only on the Converse path Parleq uses.
        // Meta Llama and Mistral are text-only on Bedrock Converse.
        // GPT-OSS-120B (gpt-oss-120b-1:0) is text-only.
        if model.contains("claude") { return true }
        if model.contains("nova-pro") || model.contains("nova-lite") { return true }
        // Nova Micro, Llama, Mistral, GPT-OSS — text-only on our path.
        return false
    }

    /// Soto resolves credentials at AWSClient init time and caches
    /// them in-process. When the user's SSO session expires and they
    /// run `aws sso login` externally to refresh the on-disk cache at
    /// `~/.aws/sso/cache/`, our existing AWSClient keeps using the
    /// stale-in-memory triple and every call fails. The fix is to
    /// rebuild AWSClient + BedrockRuntime when an auth error
    /// surfaces — Soto re-reads the on-disk cache on a fresh client,
    /// picking up the post-`aws sso login` credentials. `clientLock`
    /// serializes concurrent rebuilds so two parallel cleanups that
    /// both hit auth errors don't race; `awsClient` is `@unchecked
    /// Sendable` because the lock provides the actual synchronization.
    /// See issue #26 for the original bug.
    private let clientLock = NSLock()
    private var awsClient: AWSClient
    private var bedrockRuntime: BedrockRuntime
    /// Resolved at init from the user's profile-name preference + the
    /// AWS_PROFILE env var. Stored so credential rebuilds (see
    /// `rebuildClient()`) can re-invoke the same chain logic without
    /// reparsing.
    private let effectiveProfile: String?
    private let sotoRegion: Region
    /// Logger passed into every Soto call. When PARLEQ_BEDROCK_TRACE
    /// is set, this is configured to write trace-level output to
    /// stderr so credential-resolution failures and the per-provider
    /// "Select credential provider failed" lines surface — useful
    /// when AWS CLI auth setup isn't being picked up. Defaults to
    /// disabled to keep production runs quiet.
    private let logger: Logger

    /// Construct a Bedrock provider.
    ///
    /// - Parameters:
    ///   - model: Bedrock model ID or inference-profile ID (e.g.
    ///     `openai.gpt-oss-120b-1:0` or
    ///     `us.anthropic.claude-haiku-4-5-20251001-v1:0`).
    ///   - region: AWS region (e.g. `us-east-2`).
    ///   - profileName: Named profile from `~/.aws/config`. Used in
    ///     `.sso` mode to find the SSO session; ignored in `.static`
    ///     mode (creds come from the Keychain instead).
    ///   - authMode: How Soto resolves AWS credentials.
    ///     - `.sso` (default): use the profile's `sso_session` entry,
    ///       relying on the user's `aws sso login` cache.
    ///     - `.static`: use access key + secret + optional session
    ///       token from the Keychain (#21 step 3 — AWS_PROFILE / env
    ///       vars not consulted in this mode).
    public init(
        model: String,
        region: String,
        profileName: String?,
        authMode: AuthMode = .sso
    ) throws {
        self.model = model
        self.region = region
        self.authMode = authMode

        // Resolve the effective profile. Settings field wins; if
        // empty, fall through to the AWS_PROFILE env var (matches
        // AWS CLI / boto behavior — `aws sso login --profile X` then
        // dictating Just Works without re-typing X in Settings); if
        // both empty, Soto's default chain reads the `[default]`
        // profile from `~/.aws/config`. Only relevant for SSO mode.
        let effectiveProfile: String? = {
            if let p = profileName?.trimmingCharacters(in: .whitespaces),
               !p.isEmpty {
                return p
            }
            let env = ProcessInfo.processInfo.environment["AWS_PROFILE"]?
                .trimmingCharacters(in: .whitespaces)
            return (env?.isEmpty ?? true) ? nil : env
        }()
        self.profileName = effectiveProfile
        self.effectiveProfile = effectiveProfile

        guard let sotoRegion = Region(awsRegionName: region) else {
            // Region(awsRegionName:) returns nil only for malformed
            // strings ("us east 2" with spaces, etc.). The user
            // typed this into Settings, so bubble back a clear
            // error instead of silently using us-east-1.
            throw LLMError.requestFailed(
                NSError(domain: "BedrockProvider", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "invalid AWS region '\(region)'",
                ])
            )
        }
        self.sotoRegion = sotoRegion

        let trace = ProcessInfo.processInfo.environment["PARLEQ_BEDROCK_TRACE"] == "1"
        var lg = Logger(label: "parleq.bedrock") { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = trace ? .trace : .warning
            return handler
        }
        lg.logLevel = trace ? .trace : .warning
        self.logger = lg

        let (client, runtime) = try Self.buildClient(
            authMode: authMode,
            effectiveProfile: effectiveProfile,
            sotoRegion: sotoRegion,
            logger: lg
        )
        self.awsClient = client
        self.bedrockRuntime = runtime
    }

    /// Construct a fresh AWSClient + BedrockRuntime from the same
    /// inputs the initializer uses. Pulled out so `rebuildClient()`
    /// can re-invoke it after an auth failure to pick up refreshed
    /// SSO credentials (or refreshed Keychain static credentials)
    /// without restarting the app. Heads-up on Soto's SSO support:
    /// soto-core's bundled INIParser treats `#` and `;` as inline-
    /// comment delimiters even when they appear inside a value. AWS
    /// Identity Center start URLs sometimes end in `#`
    /// (e.g. `https://d-XXXX.awsapps.com/start/#`); when present,
    /// Soto truncates the URL at the `#`, hashes the truncated
    /// string, looks for the wrong cache file, and throws
    /// `tokenCacheNotFound`. AWS CLI and boto don't have this bug.
    /// If you hit this: drop the trailing `#` from `sso_start_url`
    /// in `~/.aws/config` and re-run `aws sso login` — the cache
    /// file then lands at the SHA-1 Soto is looking for.
    private static func buildClient(
        authMode: AuthMode,
        effectiveProfile: String?,
        sotoRegion: Region,
        logger: Logger
    ) throws -> (AWSClient, BedrockRuntime) {
        let credentialProvider: CredentialProviderFactory
        switch authMode {
        case .static:
            // Pull the user's pasted access key id + secret + optional
            // session token from the Keychain. If the user picked
            // static-mode but never set credentials, fail init so the
            // launch path falls through to "no LLM cleanup" with a
            // clear error message rather than silently issuing
            // unauthenticated SigV4 requests.
            guard let creds = KeychainStore.readAWSStaticCredentials() else {
                throw LLMError.missingCredentials(
                    "AWS auth mode is 'static' but no access keys are stored in Keychain. Open Settings → LLM → Set AWS Credentials."
                )
            }
            credentialProvider = .static(
                accessKeyId: creds.accessKeyId,
                secretAccessKey: creds.secretAccessKey,
                sessionToken: creds.sessionToken
            )
        case .sso:
            if let p = effectiveProfile {
                credentialProvider = .selector(
                    .environment,
                    .configFile(profile: p),
                    .sso(profileName: p),
                )
            } else {
                credentialProvider = .default
            }
        }

        let client = AWSClient(credentialProvider: credentialProvider, logger: logger)
        let runtime = BedrockRuntime(client: client, region: sotoRegion)
        return (client, runtime)
    }

    /// Rebuild the Soto client so a subsequent request reads fresh
    /// credentials from disk / Keychain. The trigger is an auth
    /// failure on a real ConverseStream call — the most common
    /// path being "user launched Parleq before running
    /// `aws sso login`, then ran it externally; Soto's in-memory
    /// credential cache stayed stale until we tear the client down
    /// and rebuild."
    ///
    /// `failedClient` is the AWSClient reference whose request just
    /// threw the auth error. The rebuild is guarded by an identity
    /// check so coincident auth-failure storms (two parallel
    /// dictations hitting the same expired-SSO state at once)
    /// don't double-rebuild — the second rebuild would (a) be pure
    /// waste because the on-disk cache only changes when the user
    /// runs `aws sso login` and (b) introduce an in-flight-shutdown
    /// race where dictation B's rebuild's `syncShutdown()` kills
    /// the client dictation A is currently using.
    ///
    /// Old client is shut down asynchronously after the lock
    /// releases so the rebuild doesn't block on soto-core's
    /// shutdown handshake. Best-effort: if rebuild itself fails
    /// (e.g. .static auth mode and the Keychain entry got deleted
    /// between launch and now), we keep the prior client active so
    /// subsequent calls return a sensible error rather than
    /// crashing.
    private func rebuildClient(failedClient: AWSClient) {
        clientLock.lock()
        guard awsClient === failedClient else {
            // Another caller already rebuilt the client between
            // this caller's snapshot and now. Skip — the new client
            // is already in place; the retry path picks it up.
            clientLock.unlock()
            return
        }
        let oldClient = awsClient
        do {
            let (newClient, newRuntime) = try Self.buildClient(
                authMode: authMode,
                effectiveProfile: effectiveProfile,
                sotoRegion: sotoRegion,
                logger: logger
            )
            awsClient = newClient
            bedrockRuntime = newRuntime
            clientLock.unlock()
            // Shut down the old client outside the lock — syncShutdown
            // blocks for the soto-core teardown handshake (~50–200 ms
            // typical) and we don't want concurrent dictations
            // waiting on it.
            try? oldClient.syncShutdown()
        } catch {
            clientLock.unlock()
            FileHandle.standardError.write(
                "[parleq] bedrock: rebuild after auth failure itself failed: \(error). Keeping prior client.\n"
                    .data(using: .utf8) ?? Data()
            )
        }
    }

    /// Snapshot the current BedrockRuntime + the AWSClient backing it
    /// under the lock so a concurrent rebuild doesn't observe a
    /// half-mutated client. The AWSClient reference is returned
    /// alongside so the caller can later say "I'm asking you to
    /// rebuild THIS specific client" — see `rebuildClient(failedClient:)`
    /// for why the identity is load-bearing.
    private func currentRuntime() -> (BedrockRuntime, AWSClient) {
        clientLock.lock(); defer { clientLock.unlock() }
        return (bedrockRuntime, awsClient)
    }

    public func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        let started = Date()
        var ttft: TimeInterval = 0
        var inputTokens = 0
        var outputTokens = 0

        let bedrockMessages: [BedrockRuntime.Message] = messages.map { msg in
            let role: BedrockRuntime.ConversationRole =
                msg.role == "assistant" ? .assistant : .user
            let content: [BedrockRuntime.ContentBlock] = msg.parts.compactMap { part -> BedrockRuntime.ContentBlock? in
                switch part {
                case .text(let s):
                    return .text(s)
                case .image(let data, let mime):
                    // Map our MIME type string to Soto's ImageFormat enum.
                    // Unsupported types are dropped with a stderr log rather
                    // than crashing — Bedrock only supports jpeg/png/gif/webp.
                    guard let format = BedrockRuntime.ImageFormat(rawValue: mime.split(separator: "/").last.map(String.init) ?? "") else {
                        FileHandle.standardError.write(
                            "[parleq] bedrock: unsupported image MIME type '\(mime)' — dropping image part\n"
                                .data(using: .utf8) ?? Data()
                        )
                        return nil
                    }
                    return .image(BedrockRuntime.ImageBlock(
                        format: format,
                        source: .bytes(AWSBase64Data.data(data))
                    ))
                }
            }
            return BedrockRuntime.Message(content: content, role: role)
        }

        let inferenceConfig = BedrockRuntime.InferenceConfiguration(
            maxTokens: 1024,
            temperature: 0
        )

        // Try once; on an auth-shaped failure rebuild the Soto client
        // (which forces a fresh read of ~/.aws/sso/cache/ or the
        // Keychain entries) and try again. Common case: user launched
        // Parleq before `aws sso login`, ran the login externally,
        // then dictated — without the retry, Parleq pasted raw ASR
        // until the user manually quit and relaunched. The retry is
        // capped at one attempt per generateStreaming call: if both
        // attempts fail, the credentials are genuinely missing or
        // the user's session can't be refreshed, and we surface the
        // error to the caller's normal cleanup-failure UI (see #27).
        //
        // Snapshot the client up-front and use the same reference
        // for the failure-identity check. That's what makes
        // `rebuildClient(failedClient:)`'s identity check actually
        // discriminate: if a parallel dictation already rebuilt
        // between our snapshot and our failure, the live `awsClient`
        // is the post-rebuild one, our `clientForAttempt1` is the
        // pre-rebuild one, the references differ, and we skip the
        // redundant rebuild + dangerous shutdown of the client the
        // parallel dictation is now using.
        let (runtimeForAttempt1, clientForAttempt1) = currentRuntime()
        let response: BedrockRuntime.ConverseStreamResponse
        do {
            response = try await openStream(
                runtime: runtimeForAttempt1,
                inferenceConfig: inferenceConfig,
                bedrockMessages: bedrockMessages,
                systemPrompt: systemPrompt
            )
        } catch let firstError as LLMError where Self.isAuthFailure(firstError) {
            FileHandle.standardError.write(
                "[parleq] bedrock: auth failure on first attempt (\(firstError.description)); rebuilding Soto client to pick up refreshed credentials and retrying once.\n"
                    .data(using: .utf8) ?? Data()
            )
            rebuildClient(failedClient: clientForAttempt1)
            // Fresh snapshot for the retry — whether we did the
            // rebuild ourselves or a parallel caller had already
            // done it, this picks up the live post-rebuild client.
            let (runtimeForAttempt2, _) = currentRuntime()
            response = try await openStream(
                runtime: runtimeForAttempt2,
                inferenceConfig: inferenceConfig,
                bedrockMessages: bedrockMessages,
                systemPrompt: systemPrompt
            )
        }

        do {
            for try await event in response.stream {
                switch event {
                case .contentBlockDelta(let delta):
                    if case .text(let text) = delta.delta, !text.isEmpty {
                        if ttft == 0 { ttft = -started.timeIntervalSinceNow }
                        onEvent(.chunk(text))
                    }
                case .metadata(let meta):
                    inputTokens = meta.usage.inputTokens
                    outputTokens = meta.usage.outputTokens
                case .messageStop, .messageStart, .contentBlockStart, .contentBlockStop:
                    // Structural events — nothing user-visible to do.
                    continue
                case .modelStreamErrorException(let err):
                    throw LLMError.malformedResponse("model stream error: \(err.message ?? "unknown")")
                case .internalServerException(let err):
                    throw LLMError.malformedResponse("internal server error: \(err.message ?? "unknown")")
                case .serviceUnavailableException(let err):
                    throw LLMError.malformedResponse("service unavailable: \(err.message ?? "unknown")")
                case .throttlingException(let err):
                    throw LLMError.malformedResponse("throttled: \(err.message ?? "unknown")")
                case .validationException(let err):
                    throw LLMError.malformedResponse("validation error: \(err.message ?? "unknown")")
                }
            }
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.requestFailed(error)
        }

        let summary = LLMStreamSummary(
            totalLatency: -started.timeIntervalSinceNow,
            ttft: ttft,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
        onEvent(.done(summary))
    }

    /// Per-model additional request fields. In-house benchmarks
    /// found that `reasoning_effort: "low"` on Bedrock-hosted
    /// gpt-oss models drops their hidden-reasoning channel from
    /// ~220 tokens to ~30 and 2.5× speeds up TTFT, with no quality
    /// regression on cleanup tasks. Anthropic and other models on
    /// Bedrock don't accept this field, so we only inject it for
    /// the gpt-oss family.
    private static func additionalFields(forModel model: String) -> AWSDocument? {
        if model.hasPrefix("openai.gpt-oss") {
            return .map(["reasoning_effort": .string("low")])
        }
        return nil
    }

    /// Single attempt at opening a ConverseStream. Maps Soto's
    /// auth-shaped errors onto `LLMError.missingCredentials` so the
    /// retry path above can detect them. The previous shape lived
    /// inline in `generateStreaming`; factored out so the auth-retry
    /// can re-issue the same logic without code duplication.
    private func openStream(
        runtime: BedrockRuntime,
        inferenceConfig: BedrockRuntime.InferenceConfiguration,
        bedrockMessages: [BedrockRuntime.Message],
        systemPrompt: String
    ) async throws -> BedrockRuntime.ConverseStreamResponse {
        do {
            return try await runtime.converseStream(
                additionalModelRequestFields: Self.additionalFields(forModel: model),
                inferenceConfig: inferenceConfig,
                messages: bedrockMessages,
                modelId: model,
                system: [.text(systemPrompt)],
                logger: logger
            )
        } catch let error as AWSClientError where error == .invalidSignature
            || error == .accessDenied
            || error == .missingAuthenticationToken {
            throw LLMError.missingCredentials(
                "AWS credentials rejected (\(error)). Run `aws sso login\(profileName.map { " --profile \($0)" } ?? "")` and retry."
            )
        } catch {
            // Common shape for an expired SSO session is the SDK
            // returning a credential-resolution error before any HTTP
            // call goes out. Surface a useful command in the error so
            // the user can recover without digging through logs.
            let detail = "\(error)"
            if detail.localizedCaseInsensitiveContains("sso")
                || detail.localizedCaseInsensitiveContains("expired")
                || detail.localizedCaseInsensitiveContains("credential") {
                throw LLMError.missingCredentials(
                    "AWS credentials unavailable (\(detail)). Try `aws sso login\(profileName.map { " --profile \($0)" } ?? "")`."
                )
            }
            throw LLMError.requestFailed(error)
        }
    }

    /// True when an LLMError indicates an auth failure that may be
    /// recoverable by rebuilding the Soto client. Currently any
    /// `.missingCredentials(_)` qualifies — both the AWSClientError
    /// cases mapped above (invalidSignature / accessDenied /
    /// missingAuthenticationToken) and the substring-matched SSO /
    /// expired / credential errors. `.missingAPIKey` doesn't apply
    /// to Bedrock; `.requestFailed` and `.badStatus` cover non-auth
    /// failures (network, throttling, model errors) that a rebuild
    /// wouldn't help with.
    private static func isAuthFailure(_ error: LLMError) -> Bool {
        switch error {
        case .missingCredentials: return true
        case .missingAPIKey, .badStatus, .malformedResponse, .requestFailed, .authPathBlocked:
            return false
        }
    }

    /// Provider-specific recovery hint for a cleanup failure (#27).
    /// Auth-mode-aware: SSO points the user at `aws sso login`;
    /// .static mode points at Settings → LLM → Set AWS Credentials.
    /// The error's own `description` carries the AWS-side detail
    /// already (e.g. "AccessDenied"); we prepend the actionable
    /// next step so the overlay's hint reads like a recovery
    /// instruction, not a stack trace.
    public func cleanupFailureHint(for error: LLMError) -> String? {
        switch error {
        case .missingCredentials:
            switch authMode {
            case .sso:
                let profileFragment = profileName.map { " --profile \($0)" } ?? ""
                return "AWS session expired or unavailable. Run `aws sso login\(profileFragment)` and try again."
            case .static:
                return "AWS credentials rejected. Open Settings → LLM → Set AWS Credentials."
            }
        case .badStatus(let code, _):
            // Most auth-shaped 403s from Bedrock get caught by the
            // upstream `.invalidSignature / .accessDenied /
            // .missingAuthenticationToken` mapping into
            // `.missingCredentials`. A raw 403 reaching this branch
            // typically means: model isn't enabled for the account
            // in this region, an IAM policy denies the action, or
            // the region itself isn't opted in. We point the user
            // at the most common cause (model access) without
            // claiming it's the only one — the Bedrock console
            // shows all three so the user can diagnose from there.
            if code == 403 {
                return "Bedrock returned 403. Common causes: model `\(model)` isn't enabled for this account in `\(region)`, the IAM policy attached to your credentials denies bedrock:InvokeModel, or the region isn't opted in. Check the Bedrock console or pick a different model in Settings → LLM."
            }
            return nil
        case .missingAPIKey, .malformedResponse, .requestFailed:
            // Gemini-shaped (.missingAPIKey doesn't apply to Bedrock)
            // or generic — fall through to AppState's generic hint.
            return nil
        case .authPathBlocked(let msg):
            return msg
        }
    }
}
