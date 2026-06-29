// VoiceprintServices — the dependency bundle the voice-enrollment wizard needs,
// injected from main.swift (which alone has the live coordinator, ASR, and LLM)
// down into the Settings layer (which otherwise can't reach AppState).
//
// Holds: the always-on VoiceprintCoordinator; a carrier-sentence generator
// (LLM-backed with built-in template fallback); a recorder factory configured
// from the user's current audio settings; and the encoder-feature-capturing
// transcribe path used to pool enrollment embeddings.

#if Concord
import Foundation
import FluidAudio

@MainActor
public final class VoiceprintServices {
    public let coordinator: VoiceprintCoordinator
    /// Build a fresh recorder configured for the current mic/route settings.
    public let makeRecorder: () -> AudioRecorder
    /// Transcribe a 16 kHz mono WAV with encoder features (the enrollment path).
    public let transcribe: (Data) async throws -> ASRResult?
    /// One-shot LLM text generation for carrier sentences; nil when no
    /// generative provider is configured (→ templates).
    private let llmText: (@Sendable (String) async -> String?)?

    /// Read at the write site (save time) to decide whether to persist enrollment
    /// audio. The closure is called fresh on each save so it sees MDM-overlaid
    /// values, not a cached UI value. Returns (enabled, consented); if either is
    /// false, NO audio is stored (SI-3). Default: never store.
    public let clipStoragePolicy: () -> (enabled: Bool, consented: Bool)

    public init(coordinator: VoiceprintCoordinator,
                makeRecorder: @escaping () -> AudioRecorder,
                transcribe: @escaping (Data) async throws -> ASRResult?,
                llmText: (@Sendable (String) async -> String?)?,
                clipStoragePolicy: @escaping () -> (enabled: Bool, consented: Bool) = { (false, false) }) {
        self.coordinator = coordinator
        self.makeRecorder = makeRecorder
        self.transcribe = transcribe
        self.llmText = llmText
        self.clipStoragePolicy = clipStoragePolicy
    }

    /// Carrier sentences for `term`: LLM-generated when available, otherwise the
    /// built-in templates (and templates on any LLM failure). Always returns
    /// `count` sentences.
    /// `varied: true` (used by the wizard's "Regenerate sentences") shuffles the
    /// template fallback so successive calls differ even with no generative
    /// provider; the default keeps the initial set stable.
    public func carrierSentences(term: String, count: Int, varied: Bool = false) async -> [String] {
        await CarrierSentences.generate(term: term, count: count, llm: llmText, varied: varied)
    }

    /// 7033 gate: voice enrollment is OFFERED (enrollment UI shown + new
    /// enrollments accepted) only when the master switch is on (user or MDM).
    /// Existing voiceprints still LOAD and MATCH regardless — this gates only
    /// the enrollment surface, not playback/matching. Pure + config-driven so
    /// the gate is unit-testable; both the app-shell wiring (main.swift) and the
    /// Settings enroll entry point consult it.
    public nonisolated static func enrollmentOffered(_ config: Config) -> Bool {
        config.voiceEnrollmentEnabled
    }
}
#endif
