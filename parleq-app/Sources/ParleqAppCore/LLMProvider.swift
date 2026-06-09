// LLMProvider — provider-agnostic interface for the cleanup / refine
// LLM call.
//
// Parleq's runtime path streams the cleanup/refine response into the
// overlay character-by-character. Different providers (Google AI
// direct, AWS Bedrock, etc.) speak different wire protocols, but the
// runtime contract is the same: feed system prompt + messages, get a
// stream of text chunks plus a final summary with token counts.
//
// AppState holds an `any LLMProvider` rather than a concrete type so
// the actual implementation is swappable via Config without any
// changes to the dictation pipeline. Adding a new provider means
// implementing `LLMProvider` and wiring it up in ParleqApp's
// startup factory — nothing else changes.

import Foundation

/// A single content part in an LLM message. Text-only messages use
/// `.text`; vision-mode references add `.image` parts alongside the
/// text instruction so the LLM sees both in one turn.
public enum Part: Equatable, Sendable {
    case text(String)
    case image(data: Data, mimeType: String)
}

/// One conversation turn passed to the LLM. Role is "user" or
/// "assistant"; the provider implementation is responsible for any
/// vendor-specific role mapping (e.g. Gemini uses "model" for
/// assistant turns, Bedrock uses "assistant").
public struct LLMMessage: Equatable, Sendable {
    public let role: String
    public let parts: [Part]

    public init(role: String, parts: [Part]) {
        self.role = role
        self.parts = parts
    }

    /// Convenience for text-only messages — preserves the pre-Phase-2
    /// ergonomics where call sites pass a plain string.
    public init(role: String, content: String) {
        self.role = role
        self.parts = [.text(content)]
    }

    /// Pre-Phase-2 ergonomics — concatenates text parts, ignoring
    /// image parts. Use this only for legacy call sites that haven't
    /// migrated to part-aware reading yet.
    public var legacyContentString: String {
        parts.compactMap {
            if case .text(let s) = $0 { return s } else { return nil }
        }.joined()
    }
}

/// One observation in a streaming generation. The provider delivers
/// a series of `.chunk(text)` events as the model produces output,
/// then exactly one `.done(summary)` at the end with the aggregate
/// metadata.
public enum LLMStreamEvent: Sendable {
    case chunk(String)
    case done(LLMStreamSummary)
}

/// Final summary of a streaming generation — used by the runtime to
/// log latency and bill the UsageLedger.
public struct LLMStreamSummary: Sendable {
    public let totalLatency: TimeInterval
    /// Time-to-first-text. Zero if the stream completed without
    /// emitting any visible text.
    public let ttft: TimeInterval
    public let inputTokens: Int
    public let outputTokens: Int
}

/// Errors any LLM provider can raise. Provider-specific failure
/// modes (missing API key, expired AWS CLI session, missing
/// service-account JSON, etc.) get mapped to these cases at the
/// provider boundary so the runtime path doesn't have to know
/// about each provider's error shape.
public enum LLMError: Error, CustomStringConvertible {
    case missingAPIKey
    case missingCredentials(String)
    case badStatus(Int, String)
    case malformedResponse(String)
    case requestFailed(Error)
    /// Phase 5 — thrown by BlockedProvider when staticApiKeysAllowed=false
    /// prevents using the provider's static-key auth path at runtime.
    case authPathBlocked(String)

    public var description: String {
        switch self {
        case .missingAPIKey:
            return "GEMINI_API_KEY not set — set it in Settings → LLM (stored in macOS Keychain) or via the GEMINI_API_KEY environment variable"
        case .missingCredentials(let detail):
            // Cloud-neutral: this case is thrown by both Bedrock (AWS) and the
            // Vertex googleOAuth/oidcFederation paths (GCP), so the shared enum
            // description must not say "AWS". Provider-specific recovery hints
            // (e.g. Bedrock's `aws sso login`) live in the `detail` string each
            // provider passes in, and stay cloud-specific there. NOTE: keep the
            // word "credential" in here — BedrockProvider's catch matches the
            // "credential" substring of this rendering to avoid double-wrapping.
            return "credentials unavailable: \(detail)"
        case .badStatus(let code, let body):
            return "LLM HTTP \(code): \(body)"
        case .malformedResponse(let detail):
            return "LLM response malformed: \(detail)"
        case .requestFailed(let underlying):
            return "LLM request failed: \(underlying)"
        case .authPathBlocked(let detail):
            return "Auth path blocked by organization policy: \(detail)"
        }
    }
}

/// A streaming LLM client. Implementations: `GeminiProvider`
/// (Google AI direct API), `BedrockProvider` (AWS Bedrock).
public protocol LLMProvider: Sendable {
    /// Provider-specific model identifier. Logged with each call and
    /// stored on each UsageLedger entry.
    var model: String { get }

    /// Short tag for the UsageLedger's provider column ("gemini",
    /// "bedrock"). Stable across model swaps within the same
    /// provider.
    var providerName: String { get }

    /// True when this provider's model can accept image inputs as
    /// part of the messages payload. Read by ModelConflict + the
    /// in-overlay ModelPicker (👁 marker).
    ///
    /// Set per concrete model, not per provider — Gemini 2.5 Flash
    /// supports vision, Gemini 2.5 Flash-Lite generally does NOT for
    /// production tier. Conform-er documents the per-model decision
    /// inline.
    var supportsVision: Bool { get }

    /// Run a streaming generation. The closure is called once per
    /// chunk and once with `.done` at the end. The closure runs on
    /// whatever queue the underlying transport processes events on,
    /// so callers that update UI must hop to MainActor inside.
    func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws

    /// One-line, user-facing recovery hint for a cleanup failure.
    /// Returned to AppState so the overlay's "Cleanup failed —
    /// pasting raw transcript" decoration can include
    /// provider-specific guidance ("Run `aws sso login`", "Open
    /// Settings → LLM → Set Gemini API Key…", etc.) rather than the
    /// raw error string.
    ///
    /// Implementations should be aware of their own auth mode so the
    /// hint matches what the user can actually do — e.g. a Bedrock
    /// SSO failure should suggest `aws sso login`, while a Bedrock
    /// static-keys failure should point at Settings. Return nil for
    /// errors the provider doesn't have a specific hint for; the
    /// classifier will fall back to a generic message.
    func cleanupFailureHint(for error: LLMError) -> String?

    /// True when `error` represents a fail-closed condition that an
    /// interactive *organization sign-in* can recover — i.e. the
    /// enterprise OIDC federation session expired or the user signed
    /// out. The overlay uses this (NOT the hint copy) to decide whether
    /// to render its signed-out notice as a tappable sign-in control.
    ///
    /// Only the OIDC auth paths return true; static-credential, API-key,
    /// 403 model-access, and network errors return false because a
    /// sign-in does not fix them. Default is false.
    func cleanupFailureIsReauthable(for error: LLMError) -> Bool
}

/// Default implementation so providers that don't have any
/// provider-specific guidance (or haven't yet wired the protocol
/// method) can opt out without a separate empty method definition.
extension LLMProvider {
    func cleanupFailureHint(for error: LLMError) -> String? { nil }
    public func cleanupFailureIsReauthable(for error: LLMError) -> Bool { false }
}

extension LLMError {
    /// Description suitable for ~/.parleq/app.log — strips API
    /// response bodies that could contain account metadata, request
    /// IDs, or other context that shouldn't persist on disk.
    ///
    /// Use this from any code path that writes errors to the disk
    /// log. User-facing surfaces (overlays, notifications) can still
    /// show the full `description` since they are memory-only.
    ///
    /// BedrockBearerProvider embeds up to 400 chars of response body
    /// in `.malformedResponse` detail strings (e.g. "Body preview:
    /// …"). The aggressive truncation here (100 chars) strips that.
    public var logSafeDescription: String {
        switch self {
        case .missingAPIKey:
            return "LLMError.missingAPIKey"
        case .missingCredentials(let detail):
            // Credential detail strings are user-authored (key names,
            // command hints) — safe to log in full.
            return "LLMError.missingCredentials(\(detail))"
        case .badStatus(let code, _):
            // Strip the body — it can contain request IDs, account
            // metadata, and provider-specific context strings.
            return "LLMError.badStatus(\(code), <body redacted>)"
        case .malformedResponse(let detail):
            // Some providers embed response-body previews in this
            // detail (BedrockBearerProvider does via "Body preview: …").
            // Truncate aggressively to prevent body content from reaching
            // the disk log even through this indirect path.
            let truncated = String(detail.prefix(100))
            return "LLMError.malformedResponse(\(truncated))"
        case .requestFailed(let underlying):
            // The underlying error is a URLSession/network error —
            // safe to log (no response body embedded here).
            return "LLMError.requestFailed(\(String(describing: underlying)))"
        case .authPathBlocked(let detail):
            // Policy-enforcement error — detail string is IT-authored
            // policy language, safe to log in full.
            return "LLMError.authPathBlocked(\(detail))"
        }
    }
}

// MARK: - BlockedProvider (Phase 5)

/// A sentinel `LLMProvider` returned by `makeProvider` when
/// `staticApiKeysAllowed=false` blocks the provider's auth path.
///
/// Unlike returning `nil` (which AppState interprets as "no LLM
/// configured — skip cleanup silently"), `BlockedProvider` is non-nil
/// so `streamCleanupOrRefine` attempts a cleanup call, immediately
/// receives `.authPathBlocked`, and routes the error through the
/// standard `cleanupFailureHint` path to surface a clear,
/// actionable message in the overlay.
///
/// The message stored at init time is the same one that was logged
/// by `makeProvider` at launch. Both callers (cleanup and context tier)
/// receive the same provider and the same message.
public struct BlockedProvider: LLMProvider, Sendable {
    public let model: String
    public let providerName: String
    private let blockedMessage: String

    public init(providerID: String, model: String, message: String) {
        self.model = model
        self.providerName = providerID
        self.blockedMessage = message
    }

    public var supportsVision: Bool { false }

    /// Immediately throws `.authPathBlocked` — no network call is made.
    public func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        throw LLMError.authPathBlocked(blockedMessage)
    }

    /// Returns the stored message as the user-facing recovery hint so
    /// the overlay shows actionable guidance (not a raw error string).
    public func cleanupFailureHint(for error: LLMError) -> String? {
        if case .authPathBlocked(let msg) = error {
            return msg
        }
        return nil
    }
}
