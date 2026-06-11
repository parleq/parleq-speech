// LocalLLMProvider — on-device LLM cleanup provider.
//
// Runs the dictation cleanup / refine LLM call entirely on-device via
// MLX (Apple Silicon). Unlike every other LLMProvider in this codebase
// there is:
//
//   • NO credential        — no API key, SSO session, or service account.
//   • NO cost               — no per-token billing; the UsageLedger records
//                             token counts at zero price.
//   • NO network boundary   — the transcript text never leaves the process.
//                             There is no HTTP request and nothing crosses a
//                             socket. This is the load-bearing privacy
//                             property of the on-device tier.
//
// Requirements: the model weights must already be downloaded into the
// Parleq-owned model directory (LocalModelStore.state == .ready), and the
// app bundle must ship the matching mlx.metallib (the Metal shader library
// MLX dlopens at runtime). Without either, generation cannot run.
//
// enable_thinking rationale: Gemma 4's chat template gates an optional
// hidden chain-of-thought "thinking" channel on the Jinja expression
// `enable_thinking is defined and enable_thinking`. If we leave that
// variable undefined we are relying on the template's current default — a
// future template revision could flip it on and silently burn the entire
// token budget on hidden reasoning, blowing latency and producing empty
// visible output. We therefore set `enable_thinking: false` EXPLICITLY in
// additionalContext on every call, matching the rest of the codebase's
// thinking-budget-low invariant (cleanup gains nothing from reasoning
// tokens).
//
// Determinism: temperature 0 (greedy) — validated on Gemma 4 to produce no
// degeneracy on cleanup-shaped prompts.

import Foundation
import MLXLMCommon

/// On-device MLX cleanup/refine provider. Conforms to `LLMProvider` so
/// the dictation pipeline can drive it identically to the cloud providers.
///
/// Sendable: every stored property is itself Sendable — an immutable
/// `model` string, a `@MainActor`-isolated `LocalModelStore` (MainActor
/// classes are implicitly Sendable; its `state` is read via a MainActor
/// hop), and a `ResidencyManager` actor. No mutable non-isolated state, so
/// this is a checked (`Sendable`, not `@unchecked`) conformance.
public final class LocalLLMProvider: LLMProvider, Sendable {

    /// The checkpoint id (e.g. "mlx-community/gemma-4-E4B-it-qat-4bit").
    public let model: String

    /// UsageLedger provider column tag.
    public let providerName = "local"

    /// v1 is text-only: the on-device tier handles plain cleanup/refine
    /// jobs. Anything carrying image parts routes to a vision-capable
    /// provider elsewhere, so the runtime never sends `.image` parts here.
    public let supportsVision = false

    /// `@MainActor`-isolated download/custody store. We never mutate it;
    /// we read `state` via a MainActor hop in `generateStreaming`.
    private let store: LocalModelStore

    /// RAM-aware load / idle-unload policy. Generation runs inside its
    /// `withModel` so the model can't be unloaded mid-call.
    private let residency: ResidencyManager

    /// - Parameters:
    ///   - model: the checkpoint id, also surfaced as `LLMProvider.model`.
    ///   - store: download/custody store; `.ready` gates generation.
    ///   - residency: load/idle-unload manager that vends the ModelContainer.
    public init(model: String, store: LocalModelStore, residency: ResidencyManager) {
        self.model = model
        self.store = store
        self.residency = residency
    }

    public func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        // Gate on the model being downloaded + ready. `store.state` is
        // MainActor-isolated, so hop to read it.
        let ready = await MainActor.run { store.state == .ready }
        guard ready else {
            throw LLMError.missingCredentials("on-device model not downloaded")
        }

        // Reduce the turns to plain (role, text) String pairs — both
        // Sendable, so they can cross into the `@Sendable` withModel body
        // where the non-Sendable `Chat.Message` values get built. Text parts
        // only; `.image` parts are dropped by legacyContentString (see
        // LLMProvider.swift for its definition — it returns only the
        // text-content string and silently discards any image parts).
        // supportsVision is false so the runtime won't send image parts
        // here anyway; a future vision path would need a parts-aware loop
        // instead of the single legacyContentString call.
        // Role mapping happens at the build site below.
        let turns: [(role: String, text: String)] = messages.map {
            ($0.role, $0.legacyContentString)
        }

        // Deterministic generation, bounded output. GenerateParameters is
        // Sendable; bind to a `let` so it can be captured by the body.
        let params: GenerateParameters = {
            var p = GenerateParameters()
            p.temperature = 0
            p.maxTokens = LocalModelDefaults.maxTokens
            return p
        }()

        // enable_thinking: false set EXPLICITLY — see file header. Do NOT
        // rely on the template's undefined default.
        let additionalContext: [String: any Sendable] = ["enable_thinking": false]

        let started = Date()

        // Streaming results are accumulated through a reference-typed box so the
        // @Sendable callbacks passed into the actor can write them. The actor
        // invokes these callbacks serially from inside the model isolation, so
        // no concurrent mutation occurs; @unchecked is the standard pattern for
        // this (mirrors the eval hook's EvalAccumulator).
        final class StreamResult: @unchecked Sendable {
            var firstChunkAt: TimeInterval?
            var promptTokens = 0
            var genTokens = 0
        }
        let result = StreamResult()

        do {
            // Check for cancellation before acquiring the model; once we're
            // inside the residency guard the container is held for the full
            // generation.
            try Task.checkCancellation()

            // Stream inside the residency guard so the container stays loaded
            // for the whole generation. The system prompt is prefilled once into
            // a KV prefix cache (keyed by checkpoint + prefix hash); each call
            // clones that cache and prefills only the per-utterance user suffix,
            // cutting time-to-first-token. Cache miss / non-prefix render falls
            // back transparently to a plain full-prompt prefill (today's
            // behavior) — see ResidencyManager.streamCleanup.
            try await residency.streamCleanup(
                checkpoint: model,
                systemPrompt: systemPrompt,
                turns: turns,
                params: params,
                additionalContext: additionalContext,
                started: started,
                onChunk: { text in onEvent(.chunk(text)) },
                onSummary: { first, input, output in
                    result.firstChunkAt = first
                    result.promptTokens = input
                    result.genTokens = output
                }
            )
        } catch is CancellationError {
            // Re-throw cancellation before the catch-all so it isn't wrapped
            // as a model-runtime failure and shown with the wrong recovery hint.
            throw CancellationError()
        } catch {
            // Model-load / Metal / MLX runtime errors all surface here.
            // Wrap as requestFailed; never embed transcript content. The
            // underlying error is library/Metal state, not input data.
            throw LLMError.requestFailed(error)
        }

        // Final summary. ttft is 0 if the stream emitted no visible text
        // (matches the LLMStreamSummary contract).
        onEvent(.done(LLMStreamSummary(
            totalLatency: Date().timeIntervalSince(started),
            ttft: result.firstChunkAt ?? 0,
            inputTokens: result.promptTokens,
            outputTokens: result.genTokens
        )))
    }

    public func cleanupFailureHint(for error: LLMError) -> String? {
        switch error {
        case .missingCredentials:
            return "The on-device model isn't downloaded yet. Open Settings → Cleanup to download it."
        case .requestFailed:
            return "On-device cleanup failed to run. If this Mac is low on memory, close memory-heavy apps or set Settings → Cleanup → Keep model loaded to \"Unload when idle\"."
        default:
            return nil
        }
    }
}
