// VoiceprintEnrollmentModel — the state machine behind the voice-enrollment
// wizard sheet. Holds all the logic (carrier loading, recording bookkeeping,
// analysis/confusable branching, save) so the SwiftUI view stays thin and this
// stays unit-testable.
//
// Flow: intro(consent) → carriers(record each) → analyzing(enroll positive +
// harvest aliases) → confusable(optional: record the real-word confusable for a
// contrastive negative) → review(quality) → done.
//
// Safe-failure: a poor or abandoned enrollment leaves the gate quiet (no veto) —
// never a corruption. Cancelling after analysis removes the just-stored
// voiceprint so nothing lingers.

#if Concord
import Foundation
import Concord

public enum EnrollmentPhase: Equatable {
    case intro       // one-time biometric consent
    case carriers    // read + record the term carriers
    case analyzing   // transcribe, enroll positive, harvest aliases
    case confusable  // optional: record the real-word confusable
    case review      // quality verdict + Save
    case done
}

@MainActor
public final class VoiceprintEnrollmentModel: ObservableObject, Identifiable {
    public nonisolated var id: String { term }
    /// How many carriers to read for the term and for a confusable.
    public static let carrierCount = 6
    public static let negativeCarrierCount = 4

    public let term: String
    public var termID: String { term }
    private let services: VoiceprintServices
    private let initiallyConsented: Bool
    private let onConsentGranted: () -> Void
    /// Called on Save with (term, harvestedAliases) so Settings writes/updates the
    /// dictionary entry.
    private let onEnrolled: (String, [String]) -> Void

    @Published public private(set) var phase: EnrollmentPhase = .intro
    @Published public private(set) var carriers: [String] = []
    @Published public var recordings: [Data?] = []
    @Published public private(set) var harvestedConfusables: [String] = []
    @Published public private(set) var negativeLabel: String?
    @Published public private(set) var negativeCarriers: [String] = []
    @Published public var negativeRecordings: [Data?] = []
    @Published public private(set) var outcome: VoiceprintCoordinator.EnrollmentOutcome?
    @Published public private(set) var isWorking = false
    /// Set when analysis produced no usable spans (re-record nudge).
    @Published public private(set) var analysisFailed = false
    /// The term's template BEFORE this wizard run (a re-enroll overwrites it).
    /// Captured at `analyze()` so `cancel()` can restore it instead of deleting.
    private var priorTemplate: VoiceprintTemplate?

    public init(term: String,
                services: VoiceprintServices,
                consented: Bool,
                onConsentGranted: @escaping () -> Void,
                onEnrolled: @escaping (String, [String]) -> Void) {
        self.term = term
        self.services = services
        self.initiallyConsented = consented
        self.onConsentGranted = onConsentGranted
        self.onEnrolled = onEnrolled
    }

    /// True once every term carrier has a recording (enables Analyze).
    public var carriersReady: Bool { !recordings.isEmpty && recordings.allSatisfy { $0 != nil } }
    /// True once every confusable carrier has a recording (enables the negative).
    public var negativesReady: Bool { !negativeRecordings.isEmpty && negativeRecordings.allSatisfy { $0 != nil } }

    // MARK: lifecycle

    /// Load carriers and route to consent or straight to recording.
    public func start() async {
        carriers = await services.carrierSentences(term: term, count: Self.carrierCount)
        recordings = Array(repeating: nil, count: carriers.count)
        phase = initiallyConsented ? .carriers : .intro
    }

    /// Grant biometric consent (first enrollment only) → proceed to recording.
    public func consent() {
        onConsentGranted()
        phase = .carriers
    }

    public func setRecording(_ data: Data, at index: Int) {
        guard recordings.indices.contains(index) else { return }
        recordings[index] = data
    }

    public func setNegativeRecording(_ data: Data, at index: Int) {
        guard negativeRecordings.indices.contains(index) else { return }
        negativeRecordings[index] = data
    }

    /// Regenerate the carrier sentences (keeps any existing recordings cleared).
    public func regenerateCarriers() async {
        isWorking = true
        carriers = await services.carrierSentences(term: term, count: Self.carrierCount, varied: true)
        recordings = Array(repeating: nil, count: carriers.count)
        isWorking = false
    }

    // MARK: analysis

    /// Enroll the positive voiceprint from the recorded carriers, harvest the
    /// aliases, and branch to the confusable step (when a real-word confusable
    /// was heard) or straight to review.
    public func analyze() async {
        phase = .analyzing
        isWorking = true
        analysisFailed = false
        // Snapshot any existing enrollment so a cancel can restore it (enrollPositive
        // overwrites the term's template).
        priorTemplate = services.coordinator.template(for: termID)
        let clips: [VoiceprintCoordinator.EnrollmentClip] = zip(carriers, recordings).compactMap { text, data in
            data.map { VoiceprintCoordinator.EnrollmentClip(wav: $0, carrierText: text) }
        }
        let result = await services.coordinator.enrollPositive(
            termID: termID, term: term, carriers: clips, transcribe: services.transcribe)
        isWorking = false
        guard let result else {
            analysisFailed = true
            phase = .carriers   // back to recording with a nudge
            return
        }
        outcome = result
        await decidePhaseAfterHarvest(aliases: result.harvestedAliases)
    }

    /// Pure branching on harvested aliases — testable without audio. Computes the
    /// real-word confusables; if any, loads negative carriers for the first and
    /// moves to `.confusable`, else to `.review`.
    func decidePhaseAfterHarvest(aliases: [String]) async {
        let confusables = ConfusableDetector.confusables(mishears: aliases, term: term)
        harvestedConfusables = confusables
        if let label = confusables.first {
            negativeLabel = label
            negativeCarriers = await services.carrierSentences(term: label, count: Self.negativeCarrierCount)
            negativeRecordings = Array(repeating: nil, count: negativeCarriers.count)
            phase = .confusable
        } else {
            phase = .review
        }
    }

    // MARK: confusable + finish

    /// Attach the contrastive negative from the recorded confusable carriers.
    public func proceedWithNegative() async {
        guard let label = negativeLabel else { phase = .review; return }
        isWorking = true
        let clips: [VoiceprintCoordinator.EnrollmentClip] = zip(negativeCarriers, negativeRecordings).compactMap { text, data in
            data.map { VoiceprintCoordinator.EnrollmentClip(wav: $0, carrierText: text) }
        }
        _ = await services.coordinator.addNegative(
            termID: termID, label: label, carriers: clips, transcribe: services.transcribe)
        isWorking = false
        phase = .review
    }

    /// Skip the confusable step (the user says they're not confusable).
    public func skipConfusable() { phase = .review }

    /// Commit: write the dictionary entry (term + aliases) and finish.
    public func save() {
        onEnrolled(term, outcome?.harvestedAliases ?? [])
        phase = .done
    }

    /// Abandon after analysis. A re-enroll overwrote the term's template, so restore
    /// the prior one if there was one; otherwise remove the just-stored voiceprint so
    /// nothing lingers. (No-op if analysis never ran.)
    public func cancel() {
        guard outcome != nil else { return }
        if let prior = priorTemplate {
            services.coordinator.restoreTemplate(prior)
        } else {
            services.coordinator.removeVoiceprint(termID: termID)
        }
    }

    /// A fresh recorder configured for the current mic settings (for the view).
    public func makeRecorder() -> AudioRecorder { services.makeRecorder() }
}
#endif
