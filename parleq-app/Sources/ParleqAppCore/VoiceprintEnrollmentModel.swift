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
// never a corruption. NOTHING is stored or persisted until Save: analysis BUILDS
// a draft template held only in this model; `save()` is the single point that
// commits it to the coordinator's store (and disk). So dismiss/cancel/quit/crash
// before Save leaves no voiceprint at all, and cancel is a pure in-memory discard.

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
    /// The DRAFT voiceprint built at `analyze()` (and augmented at
    /// `proceedWithNegative()`). Held only here — NOT in the coordinator store —
    /// until `save()` commits it. nil before analysis succeeds.
    private var draftTemplate: VoiceprintTemplate?

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
        // Set the initial phase up front so the consent (`.intro`) screen never
        // flashes during the async carrier-load: a consented (skip) user lands
        // straight on `.carriers` (a brief load while sentences arrive); an
        // unconsented user lands on `.intro` and STAYS until they accept.
        self.phase = consented ? .carriers : .intro
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
        // 7050: the initial phase is already set in init. If the user tapped
        // consent during the await above, consent() advanced phase → .carriers;
        // re-asserting `initiallyConsented ? … : .intro` here would clobber that
        // back to .intro for an unconsented user. Only (re)assert the routing if
        // we're STILL on the pre-consent screen (no advance happened).
        if phase == .intro {
            phase = initiallyConsented ? .carriers : .intro
        }
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

    /// BUILD the positive voiceprint (a draft, not yet stored) from the recorded
    /// carriers, harvest the aliases, and branch to the confusable step (when a
    /// real-word confusable was heard) or straight to review. The draft is
    /// committed only at `save()` — analysis touches nothing on disk.
    public func analyze() async {
        phase = .analyzing
        isWorking = true
        analysisFailed = false
        let clips: [VoiceprintCoordinator.EnrollmentClip] = zip(carriers, recordings).compactMap { text, data in
            data.map { VoiceprintCoordinator.EnrollmentClip(wav: $0, carrierText: text) }
        }
        let built = await services.coordinator.buildPositive(
            termID: termID, term: term, carriers: clips, transcribe: services.transcribe)
        // Cancelled mid-analysis (the wizard was dismissed): abandon without writing
        // draft/outcome/phase. Nothing was persisted (build never stores), so this is
        // a clean bail — no stale state to leave behind.
        guard !Task.isCancelled else { isWorking = false; return }
        isWorking = false
        guard let built else {
            analysisFailed = true
            phase = .carriers   // back to recording with a nudge
            return
        }
        draftTemplate = built.template
        outcome = built.outcome
        await decidePhaseAfterHarvest(aliases: built.outcome.harvestedAliases)
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
            guard !Task.isCancelled else { return }
            negativeRecordings = Array(repeating: nil, count: negativeCarriers.count)
            phase = .confusable
        } else {
            phase = .review
        }
    }

    // MARK: confusable + finish

    /// Attach the contrastive negative to the DRAFT template from the recorded
    /// confusable carriers (still not stored — committed at `save()`).
    public func proceedWithNegative() async {
        guard let label = negativeLabel, let template = draftTemplate else { phase = .review; return }
        isWorking = true
        let clips: [VoiceprintCoordinator.EnrollmentClip] = zip(negativeCarriers, negativeRecordings).compactMap { text, data in
            data.map { VoiceprintCoordinator.EnrollmentClip(wav: $0, carrierText: text) }
        }
        draftTemplate = await services.coordinator.buildNegativeAttached(
            to: template, label: label, carriers: clips, transcribe: services.transcribe)
        isWorking = false
        phase = .review
    }

    /// Skip the confusable step (the user says they're not confusable).
    public func skipConfusable() { phase = .review }

    /// Commit: store the draft voiceprint (the SINGLE persist point), capture
    /// enrollment audio (consent + enabled gated), write the dictionary entry
    /// (term + aliases), and finish.
    public func save() {
        if let draftTemplate {
            services.coordinator.commit(draftTemplate)
        }
        // Capture raw enrollment clips for future re-derivation across encoder changes.
        // Gated on both enabled AND consented (SI-3: no storage without fresh consent).
        let policy = services.clipStoragePolicy()
        if policy.enabled && policy.consented {
            let positiveClips: [StoredEnrollmentClip] = zip(carriers, recordings).compactMap { text, data in
                data.map { StoredEnrollmentClip(wav: $0, carrierText: text, role: .positive, negativeLabel: nil) }
            }
            let negativeClips: [StoredEnrollmentClip]
            if let label = negativeLabel {
                negativeClips = zip(negativeCarriers, negativeRecordings).compactMap { text, data in
                    data.map { StoredEnrollmentClip(wav: $0, carrierText: text, role: .negative, negativeLabel: label) }
                }
            } else {
                negativeClips = []
            }
            let allClips = positiveClips + negativeClips
            if !allClips.isEmpty {
                services.coordinator.storeEnrollmentClips(termID: termID, allClips)
            }
        }
        onEnrolled(term, outcome?.harvestedAliases ?? [])
        phase = .done
    }

    /// Abandon the wizard. Nothing was stored (storage is deferred to `save()`),
    /// so this is a pure in-memory discard of the draft — no store mutation.
    public func cancel() {
        draftTemplate = nil
    }

    /// A fresh recorder configured for the current mic settings (for the view).
    public func makeRecorder() -> AudioRecorder { services.makeRecorder() }
}
#endif
