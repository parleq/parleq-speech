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

/// One conversation turn passed to the LLM. Role is "user" or
/// "assistant"; the provider implementation is responsible for any
/// vendor-specific role mapping (e.g. Gemini uses "model" for
/// assistant turns, Bedrock uses "assistant").
struct LLMMessage: Sendable {
    let role: String
    let content: String
}

/// One observation in a streaming generation. The provider delivers
/// a series of `.chunk(text)` events as the model produces output,
/// then exactly one `.done(summary)` at the end with the aggregate
/// metadata.
enum LLMStreamEvent: Sendable {
    case chunk(String)
    case done(LLMStreamSummary)
}

/// Final summary of a streaming generation — used by the runtime to
/// log latency and bill the UsageLedger.
struct LLMStreamSummary: Sendable {
    let totalLatency: TimeInterval
    /// Time-to-first-text. Zero if the stream completed without
    /// emitting any visible text.
    let ttft: TimeInterval
    let inputTokens: Int
    let outputTokens: Int
}

/// Errors any LLM provider can raise. Provider-specific failure
/// modes (missing API key, expired AWS CLI session, missing
/// service-account JSON, etc.) get mapped to these cases at the
/// provider boundary so the runtime path doesn't have to know
/// about each provider's error shape.
enum LLMError: Error, CustomStringConvertible {
    case missingAPIKey
    case missingCredentials(String)
    case badStatus(Int, String)
    case malformedResponse(String)
    case requestFailed(Error)

    var description: String {
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
protocol LLMProvider: Sendable {
    /// Provider-specific model identifier. Logged with each call and
    /// stored on each UsageLedger entry.
    var model: String { get }

    /// Short tag for the UsageLedger's provider column ("gemini",
    /// "bedrock"). Stable across model swaps within the same
    /// provider.
    var providerName: String { get }

    /// Run a streaming generation. The closure is called once per
    /// chunk and once with `.done` at the end. The closure runs on
    /// whatever queue the underlying transport processes events on,
    /// so callers that update UI must hop to MainActor inside.
    func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws
}
