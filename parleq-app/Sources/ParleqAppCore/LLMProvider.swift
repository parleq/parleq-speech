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

    public var description: String {
        switch self {
        case .missingAPIKey:
            return "GEMINI_API_KEY not set — set it in Settings → LLM (stored in macOS Keychain) or via the GEMINI_API_KEY environment variable"
        case .missingCredentials(let detail):
            return "AWS credentials unavailable: \(detail)"
        case .badStatus(let code, let body):
            return "LLM HTTP \(code): \(body)"
        case .malformedResponse(let detail):
            return "LLM response malformed: \(detail)"
        case .requestFailed(let underlying):
            return "LLM request failed: \(underlying)"
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
}

/// Default implementation so providers that don't have any
/// provider-specific guidance (or haven't yet wired the protocol
/// method) can opt out without a separate empty method definition.
extension LLMProvider {
    func cleanupFailureHint(for error: LLMError) -> String? { nil }
}
