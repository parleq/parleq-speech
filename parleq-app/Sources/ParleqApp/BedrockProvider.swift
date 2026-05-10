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

final class BedrockProvider: LLMProvider, Sendable {
    /// Bedrock credential resolution mode. Maps 1:1 to
    /// `Config.awsAuthMode`. Bedrock API keys (the newer scoped
    /// bearer tokens AWS shipped in 2024) need bearer auth rather
    /// than SigV4, which Soto doesn't model directly — adding them
    /// requires a custom HTTP path and is left for a follow-up
    /// (#21 step 3 follow-up).
    enum AuthMode: Sendable {
        /// Resolve credentials from the user's AWS CLI session
        /// (Soto's `.sso()` provider against `~/.aws/config` plus
        /// `~/.aws/sso/cache/`). Existing default.
        case sso
        /// Use access keys + secret + optional session token stored
        /// in the macOS Keychain (`KeychainStore.AWSStaticCredentials`).
        case `static`
    }

    let model: String
    let region: String
    let profileName: String?

    var providerName: String { "bedrock" }

    /// Owned by this provider for its lifetime. Soto's recommendation
    /// is to keep the AWSClient as a singleton for the process — it
    /// holds the shared HTTP client and credential rotation state.
    /// Parleq has exactly one BedrockProvider instance from
    /// app-launch to quit, so we never call shutdown().
    private let awsClient: AWSClient
    private let bedrockRuntime: BedrockRuntime
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
    init(
        model: String,
        region: String,
        profileName: String?,
        authMode: AuthMode = .sso
    ) throws {
        self.model = model
        self.region = region

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

        // Build the credential provider chain based on the chosen
        // auth mode. Heads-up on Soto's SSO support: soto-core's
        // bundled INIParser treats `#` and `;` as inline-comment
        // delimiters even when they appear inside a value. AWS
        // Identity Center start URLs sometimes end in `#`
        // (e.g. `https://d-XXXX.awsapps.com/start/#`); when present,
        // Soto truncates the URL at the `#`, hashes the truncated
        // string, looks for the wrong cache file, and throws
        // `tokenCacheNotFound`. AWS CLI and boto don't have this bug.
        // If you hit this: drop the trailing `#` from `sso_start_url`
        // in `~/.aws/config` and re-run `aws sso login` — the cache
        // file then lands at the SHA-1 Soto is looking for.
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

        let trace = ProcessInfo.processInfo.environment["PARLEQ_BEDROCK_TRACE"] == "1"
        var lg = Logger(label: "parleq.bedrock") { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = trace ? .trace : .warning
            return handler
        }
        lg.logLevel = trace ? .trace : .warning
        self.logger = lg
        self.awsClient = AWSClient(credentialProvider: credentialProvider, logger: lg)
        guard let sotoRegion = Region(awsRegionName: region) else {
            // Region(awsRegionName:) returns nil only for malformed
            // strings ("us east 2" with spaces, etc.). The user
            // typed this into Settings, so bubble back a clear
            // error instead of silently using us-east-1.
            try? awsClient.syncShutdown()
            throw LLMError.requestFailed(
                NSError(domain: "BedrockProvider", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "invalid AWS region '\(region)'",
                ])
            )
        }
        self.bedrockRuntime = BedrockRuntime(client: awsClient, region: sotoRegion)
    }

    func generateStreaming(
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
            return BedrockRuntime.Message(
                content: [.text(msg.content)],
                role: role
            )
        }

        let inferenceConfig = BedrockRuntime.InferenceConfiguration(
            maxTokens: 1024,
            temperature: 0
        )

        let response: BedrockRuntime.ConverseStreamResponse
        do {
            response = try await bedrockRuntime.converseStream(
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
}
