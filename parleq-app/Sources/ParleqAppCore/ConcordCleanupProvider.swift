// ConcordCleanupProvider — the "Lightweight (on-device)" 2nd-pass
// cleanup tier, backed by the private Concord correction engine.
//
// Concord is a *deterministic + confidence-gated* corrector (spoken
// numbers → digits, compound de-spacing, and Double-Metaphone dictionary
// jargon correction with a per-word confidence veto). It is NOT a
// generative LLM: it runs in-process, synchronously, in ~0 ms, crosses
// no network boundary, and needs no auth. It implements `LLMProvider`
// purely so it can slot into the existing cleanup pipeline alongside the
// real LLM providers — the streaming contract is honored by emitting the
// whole cleaned transcript as a single `.chunk` followed by `.done`.
//
// Per-word confidence plumbing (the load-bearing input). Concord's
// dictionary stage gates every substitution on the ASR's own per-token
// confidence: only low-confidence words are eligible to be replaced by a
// dictionary term, which is what keeps it zero-harm on already-correct
// words. That confidence lives in `ASRDiagnostics.tokenTimings`, which the
// rest of the pipeline drops before cleanup. We can't widen the
// `LLMProvider.generateStreaming` signature (every provider shares it), so
// the diagnostics arrive via a per-utterance SIDE-CHANNEL: AppState calls
// `setUtteranceContext(diagnostics:)` immediately before invoking cleanup,
// the provider reads + CLEARS it inside generateStreaming, and a fresh
// utterance with no diagnostics (e.g. the HTTP ASR path, which returns
// nil) falls back to all-1.0 confidence (Concord treats that as "no
// dictionary eligibility" — safe). Clearing each utterance preserves the
// fresh-stateless-per-utterance invariant.
//
// Compliance: transcript/edit CONTENT never reaches stderr or disk. The
// `.done` summary line logs counts only (chars/words, like the ASR
// length-only log). Per-stage provenance with the actual edited words is
// retained IN-MEMORY ONLY via `ConcordProvenanceStore` (process memory,
// wiped on quit) — mirroring CorrectionJournal's never-to-disk discipline.

#if Concord
import Concord
import Foundation

/// The cleanup provider that drives Concord. Reference type (final class)
/// so AppState can stash per-utterance diagnostics on the SAME instance it
/// hands to `streamCleanupOrRefine`; `@unchecked Sendable` because the
/// single mutable slot is lock-guarded and access is provably serial
/// (set-then-read within one utterance on the MainActor).
public final class ConcordCleanupProvider: LLMProvider, @unchecked Sendable {

    public var model: String { "concord-phase1" }
    public var providerName: String { "concord" }
    public var supportsVision: Bool { false }

    private let engine: ConcordEngine

    // Per-utterance side-channel for ASR diagnostics (per-word confidence
    // + token timings). Lock-guarded; set by AppState just before cleanup,
    // consumed + cleared inside generateStreaming. nil → no confidence
    // available (HTTP ASR path) → Concord uses safe all-1.0 fallback.
    private let lock = NSLock()
    private var pendingDiagnostics: ASRDiagnostics?

    // The APPLIED edits from the most recent cleanup call. Read by AppState
    // right after `streamCleanupOrRefine` returns to drive the overlay's
    // "highlight what the corrector changed" + per-correction-undo feature.
    // Lock-guarded; set inside generateStreaming. In-memory only (the same
    // content already lives in ConcordProvenanceStore) — never logged/persisted.
    private var lastEdits: [EditRecord] = []

    public init(engine: ConcordEngine = ConcordEngine()) {
        self.engine = engine
    }

    /// Stash the ASR diagnostics for the NEXT cleanup call. Called by
    /// AppState immediately before `streamCleanupOrRefine`. Passing nil
    /// (HTTP ASR path) is fine — Concord falls back to all-1.0 confidence,
    /// which makes its dictionary stage a no-op (zero harm).
    public func setUtteranceContext(diagnostics: ASRDiagnostics?) {
        lock.lock(); defer { lock.unlock() }
        pendingDiagnostics = diagnostics
    }

    /// Consume + clear the side-channel (fresh-stateless-per-utterance).
    private func takeDiagnostics() -> ASRDiagnostics? {
        lock.lock(); defer { lock.unlock() }
        let d = pendingDiagnostics
        pendingDiagnostics = nil
        return d
    }

    // Acoustic-gate factory (voice-enrollment disambiguation). Set ONCE when the enrollment demo is
    // armed; given an utterance's diagnostics it returns the gate the engine consults to VETO an
    // over-firing dictionary substitution. nil (the default) → no enforcement, byte-identical
    // baseline. The factory captures only Sendable value types (the enrolled voiceprint snapshot),
    // so it runs safely here off the MainActor. Set-once (not per-utterance) so there is nothing to
    // drain on a skipped turn.
    private var _gateFactory: (@Sendable (ASRDiagnostics?) -> AcousticGate?)?

    /// Install (or clear) the acoustic-gate factory. Called by AppState once the voiceprint demo is
    /// armed; nil disables enforcement.
    public func setEnrollmentGateFactory(_ factory: (@Sendable (ASRDiagnostics?) -> AcousticGate?)?) {
        lock.lock(); defer { lock.unlock() }
        _gateFactory = factory
    }

    private func gateFactory() -> (@Sendable (ASRDiagnostics?) -> AcousticGate?)? {
        lock.lock(); defer { lock.unlock() }
        return _gateFactory
    }

    private func setLastEdits(_ edits: [EditRecord]) {
        lock.lock(); defer { lock.unlock() }
        lastEdits = edits
    }

    /// The APPLIED edits from the most recent cleanup call, for the overlay
    /// highlight + per-correction-undo feature. Read by AppState after a
    /// cleanup completes; empty after a refine (or before any cleanup).
    /// Returns a copy under the lock — does NOT clear, so a re-read (e.g. a
    /// second consumer) is safe; the next cleanup overwrites it.
    public func appliedEditsForOverlay() -> [EditRecord] {
        lock.lock(); defer { lock.unlock() }
        return lastEdits.filter { $0.applied }
    }

    // Per-utterance call context: the BARE ASR transcript (framing-independent)
    // and whether this is a REFINE turn. Concord is cleanup-only — it can't
    // follow refine instructions — so refine turns return the prior text
    // unchanged. (Preset turns are still plain cleanups here: isRefine is false
    // and Concord cleans the bare transcript, simply ignoring the preset style.)
    private var pendingTranscript: String?
    private var pendingIsRefine = false
    private var pendingPriorText: String?

    /// Stash the call context for the NEXT cleanup call (set by AppState just
    /// before cleanup). `transcript` is the bare ASR text; `isRefine` true only
    /// for refine turns, which return `priorText` unchanged.
    public func setUtteranceCall(transcript: String, isRefine: Bool, priorText: String?) {
        lock.lock(); defer { lock.unlock() }
        pendingTranscript = transcript
        pendingIsRefine = isRefine
        pendingPriorText = priorText
    }
    private func takeCall() -> (transcript: String?, isRefine: Bool, priorText: String?) {
        lock.lock(); defer { lock.unlock() }
        let t = pendingTranscript, r = pendingIsRefine, p = pendingPriorText
        pendingTranscript = nil; pendingIsRefine = false; pendingPriorText = nil
        return (t, r, p)
    }

    public func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        let start = Date()
        let call = takeCall()

        // CLEANUP-ONLY tier. Refine turns carry instruction scaffolding
        // ("Current text:" / "Edit instruction:") Concord can't follow, so it
        // never runs cleanup on them — a refine turn returns the prior text
        // UNCHANGED (a safe no-op). Refinement requires a cloud/LLM provider.
        if call.isRefine {
            // Drain the OTHER side-channels too (they were set for this utterance),
            // so a skipped refine never leaks stale diagnostics/dictionary/policies into a
            // later cleanup — preserving the fresh-stateless-per-utterance invariant.
            _ = takeDiagnostics()
            _ = pendingDictionaryTerms()
            _ = takePolicies()
            // A refine produces no edits — clear any prior cleanup's edits so the
            // overlay highlight from an earlier turn can't leak onto this one.
            setLastEdits([])
            let passthrough = call.priorText
                ?? Self.unwrapTranscript(messages.last?.legacyContentString ?? "")
            FileHandle.standardError.write(
                "[concord] refine skipped — on-device tier is cleanup-only (text unchanged)\n"
                    .data(using: .utf8) ?? Data())
            onEvent(.chunk(passthrough))
            let e = Date().timeIntervalSince(start)
            onEvent(.done(LLMStreamSummary(totalLatency: e, ttft: e, inputTokens: 0, outputTokens: 0)))
            return
        }

        // Cleanup: use the BARE transcript handed via the side-channel
        // (framing-independent, so a preset turn's scaffolding can't leak in),
        // falling back to unwrapping the message only if the context is absent.
        let transcript = call.transcript
            ?? Self.unwrapTranscript(messages.last?.legacyContentString ?? "")

        let diagnostics = takeDiagnostics()
        let tokens = Self.buildTokens(from: diagnostics)
        // Dictionary terms ride the per-utterance side-channel (they can't
        // ride the shared LLMProvider signature, and the system prompt only
        // carries a free-text hint, not structured terms).
        let dict = pendingDictionaryTerms()
        // Per-term correction policies (consumed here; the engine ignores them
        // until a future release wires up the matching path that acts on them).
        let policies = takePolicies()
        // Build this utterance's acoustic gate from its diagnostics (enrollment enforce mode). nil
        // → byte-identical baseline behavior.
        let acousticGate = gateFactory().flatMap { $0(diagnostics) }

        let result = acousticGate.map {
            engine.clean(transcript: transcript, tokens: tokens, dictionary: dict, acousticGate: $0,
                         policies: policies)
        } ?? engine.clean(transcript: transcript, tokens: tokens, dictionary: dict,
                          acousticGate: nil, policies: policies)

        // Provenance: retain the full per-stage edit records IN MEMORY for
        // the maintainer's A/B analysis. Counts-only to stderr below.
        ConcordProvenanceStore.record(result.edits)

        // Stash this utterance's edits for the overlay highlight + undo feature
        // (AppState reads them right after this call returns). In-memory only.
        setLastEdits(result.edits)

        // Count-only stderr log (compliance: no transcript/edit content).
        let byStage = result.appliedByStage
        let parts = byStage
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: " ")
        let appliedTotal = byStage.values.reduce(0, +)
        let consideredTotal = result.edits.count
        let chars = result.text.count
        let words = result.text.split(whereSeparator: { $0.isWhitespace }).count
        let summaryParts = appliedTotal == 0 ? "(none)" : parts
        FileHandle.standardError.write(
            "[concord] applied: \(summaryParts) (\(appliedTotal)/\(consideredTotal) considered, \(chars) chars / \(words) words)\n"
                .data(using: .utf8) ?? Data())

        // Honor the streaming contract: one chunk with the full result,
        // then done. Concord is ~instant, so ttft == total.
        onEvent(.chunk(result.text))
        let elapsed = Date().timeIntervalSince(start)
        onEvent(.done(LLMStreamSummary(
            totalLatency: elapsed,
            ttft: elapsed,
            inputTokens: 0,   // not a token-billed provider
            outputTokens: 0
        )))
    }

    // MARK: - Per-utterance dictionary side-channel

    // The dictionary terms also can't ride the shared LLMProvider
    // signature, so AppState sets them alongside the diagnostics. Stored
    // separately so each is set/cleared independently.
    private var pendingDictionary: [DictionaryTerm] = []

    /// Stash the user dictionary (mapped to Concord terms) for the NEXT
    /// cleanup call. Called by AppState immediately before cleanup.
    public func setUtteranceDictionary(_ entries: [DictionaryEntry]) {
        let mapped = entries.map {
            DictionaryTerm(term: $0.term, aliases: $0.aliases, spokenForms: $0.spokenForms)
        }
        lock.lock(); defer { lock.unlock() }
        pendingDictionary = mapped
    }

    private func pendingDictionaryTerms() -> [DictionaryTerm] {
        lock.lock(); defer { lock.unlock() }
        let d = pendingDictionary
        pendingDictionary = []
        return d
    }

    // MARK: - Per-utterance policy side-channel

    // Per-term correction policies (keyed by canonical term, original case).
    // Mirrors the pendingDictionary lifecycle: set by AppState before cleanup,
    // consumed + cleared inside generateStreaming, drained on refine turns.
    // The engine currently ignores the map; a future release wires the matching paths.
    private var pendingPolicies: [String: CorrectionPolicy] = [:]

    /// Stash the per-term correction policies for the NEXT cleanup call.
    /// Called by AppState immediately before cleanup (alongside setUtteranceDictionary).
    public func setUtterancePolicies(_ p: [String: CorrectionPolicy]) {
        lock.lock(); defer { lock.unlock() }
        pendingPolicies = p
    }

    private func takePolicies() -> [String: CorrectionPolicy] {
        lock.lock(); defer { lock.unlock() }
        let p = pendingPolicies
        pendingPolicies = [:]
        return p
    }

    // MARK: - Input construction

    /// Build Concord tokens (text + confidence + audio span) from the ASR
    /// diagnostics. Concord aligns confidence to transcript words
    /// positionally, so we pass the FluidAudio sub-word token stream
    /// straight through (text isn't used by the Phase-1 dictionary stage —
    /// only the per-token confidence and, for Phase 2, the timings).
    static func buildTokens(from diagnostics: ASRDiagnostics?) -> [ConcordToken] {
        guard let diagnostics else { return [] }
        return diagnostics.tokenTimings.map {
            ConcordToken(
                text: $0.token,
                confidence: $0.confidence,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        }
    }

    /// Strip the cleanup framing AppState wraps around the raw transcript
    /// ("Transcript to clean up:\n\n<text>"). If the prefix isn't present
    /// (any other framing), return the content unchanged.
    static func unwrapTranscript(_ wrapped: String) -> String {
        let prefix = "Transcript to clean up:\n\n"
        if wrapped.hasPrefix(prefix) {
            return String(wrapped.dropFirst(prefix.count))
        }
        return wrapped
    }

    // Concord is local-only and never fails in a way a user can act on;
    // no recovery hint, never reauthable (protocol defaults cover the rest).
    public func cleanupFailureHint(for error: LLMError) -> String? { nil }
}
#endif
