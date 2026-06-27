// VoiceprintDemo / VoiceprintCoordinator — the productized voice-enrollment
// acoustic-disambiguation feature.
//
// `VoiceprintCoordinator` owns the per-term voiceprint lifecycle in the
// running app: enrollment (`buildPositive` / `buildNegativeAttached` build a
// DRAFT template from recorded carrier sentences; `commit` is the single point
// that stores + persists it — the wizard defers commit to Save), the runtime
// acoustic gate that vetoes/reverts an
// over-firing dictionary correction (`enforcementGateFactory` →
// Concord's VoiceprintGate, e.g. keep the fruit "kiwi" instead of the app
// "Keavi"), and encrypted-at-rest persistence (`loadPersisted` /
// `restoreTemplate` / `removeVoiceprint`). Pipeline:
//   real dictation → Parakeet encoder features → Concord's VoiceprintGate.
// All of the Concord gate logic is gated behind `#if Concord`, so the public
// (trait-off) build compiles the gate out entirely; the env flags + capture
// arming below stay trait-independent (see `VoiceprintDemo`).
//
// DEBUG-ONLY FLYWHEEL PATH (armed by `PARLEQ_VOICEPRINT_DEMO=1`, env-gated and
// inert otherwise): `runStartupEnrollment` + `evaluateShadow` build a baked-in
// "Keavi"/"kiwi" voiceprint from the maintainer's flywheel corpus, self-check
// the held-out clips, and (shadow mode) log the gate's ACCEPT/REJECT decision
// on real dictation WITHOUT changing paste/output. These two methods and the
// hardcoded windows are the maintainer's evaluation harness, NOT the shipping
// enrollment path that users drive from Dictionary Settings.
//
// COMPLIANCE: every log line below carries ONLY the dictionary term name,
// the literal evaluated token ("kiwi" — itself the enrolled negative, not
// user content), and decision/similarity NUMBERS. No surrounding transcript
// text, no audio, no embeddings are ever logged or persisted. The voiceprint
// templates live in Concord's in-memory `VoiceprintStore` (process memory,
// wiped on quit; biometric-sensitive — see VoiceprintGate.swift header).

import FluidAudio
import Foundation

/// Always-available (trait-independent) gate for the demo. Kept OUT of the
/// `#if Concord` block because `LocalASR` consults it unconditionally to
/// decide whether to arm encoder-feature capture. When the env var is unset
/// this is `false` and the whole feature is inert with zero overhead.
public enum VoiceprintDemo {
    /// True iff `PARLEQ_VOICEPRINT_DEMO=1` is set in the environment.
    public static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["PARLEQ_VOICEPRINT_DEMO"] == "1"

    /// True iff the demo should ENFORCE (actually veto the over-correction) rather than only run
    /// the shadow log. Requires the demo to be enabled; `PARLEQ_VOICEPRINT_ENFORCE=1`. Off → the
    /// gate is shadow-only and output is unchanged (the safe default).
    public static let isEnforcing: Bool =
        isEnabled && ProcessInfo.processInfo.environment["PARLEQ_VOICEPRINT_ENFORCE"] == "1"
}

// MARK: - Shared helpers (trait-independent)

extension VoiceprintDemo {
    /// A word-group from the ASR token timings: the joined token text plus the
    /// span [start, end] seconds it covers. Groups are split on leading-space
    /// token boundaries (FluidAudio prefixes a word-initial token with a space).
    struct WordGroup {
        let text: String
        let startSeconds: Double
        let endSeconds: Double
    }

    /// Group raw token timings into word-groups on leading-space boundaries.
    /// `frames[t]` style timing → a word-group's span is [first token start,
    /// last token end].
    static func wordGroups(from timings: [TokenTiming]) -> [WordGroup] {
        var groups: [WordGroup] = []
        var curText = ""
        var curStart = 0.0
        var curEnd = 0.0
        var have = false
        func flush() {
            guard have else { return }
            let trimmed = curText.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                groups.append(WordGroup(text: trimmed, startSeconds: curStart, endSeconds: curEnd))
            }
        }
        for t in timings {
            let startsWord = t.token.hasPrefix(" ") || !have
            if startsWord {
                flush()
                curText = t.token
                curStart = t.startTime
                curEnd = t.endTime
                have = true
            } else {
                curText += t.token
                curEnd = t.endTime
            }
        }
        flush()
        return groups
    }

    /// The first word-group whose (lowercased, punctuation-stripped) text
    /// contains "kiwi". FluidAudio writes BOTH the company "Keavi" and the
    /// fruit "kiwi" as a kiwi-ish token, so this finds the candidate span for
    /// either utterance. Returns nil if no kiwi-token group is present.
    static func kiwiCandidateGroup(in timings: [TokenTiming]) -> WordGroup? {
        for g in wordGroups(from: timings) {
            let normalized = g.text.lowercased().filter { $0.isLetter }
            if normalized.contains("kiwi") {
                return g
            }
        }
        return nil
    }
}

// MARK: - Concord-gated enrollment + gate evaluation

#if Concord
import Combine
import Concord

/// MainActor coordinator owning the in-memory voiceprint store + acoustic gate.
/// Always constructed (see main.swift). The PRODUCTIZED surface — wizard-driven
/// `buildPositive`/`buildNegativeAttached`/`commit`, `removeVoiceprint`/`removeAll`, and the
/// `enforcementGateFactory` wired into Concord — is generic over any term. The
/// `runStartupEnrollment` + `evaluateShadow` + hardcoded Keavi/kiwi windows below
/// are the DEBUG flywheel path, active only under `PARLEQ_VOICEPRINT_DEMO=1`.
@MainActor
public final class VoiceprintCoordinator {
    /// Debug flywheel demo term/negative (used only by `runStartupEnrollment`).
    public static let termID = "Keavi"
    static let negativeLabel = "kiwi"

    /// Assertable outcome of `runStartupEnrollment`. Mirrors the numbers in the
    /// `[voiceprint]` / `[voiceprint-selftest]` log lines so a harness (or the
    /// verification unit test) can assert on the held-out results rather than
    /// scraping stderr. Additive — the logging is unchanged.
    public struct SelfTestResult: Sendable, Equatable {
        /// Number of Keavi enrollment clips that yielded a usable embedding.
        public let enrolledClips: Int
        /// Number of kiwi negative clips that yielded a usable embedding.
        public let negativeClips: Int
        /// Mean leave-one-out self-similarity of the surviving Keavi clips.
        public let survivingMeanSelfSim: Float
        /// Whether the enrolled template failed the quality bar.
        public let lowQuality: Bool
        /// Held-out Keavi clips the gate ACCEPTED (true positives).
        public let keaviHeldoutAccepted: Int
        /// Total held-out Keavi clips that produced an embedding.
        public let keaviHeldoutTotal: Int
        /// Held-out kiwi clips the gate FALSE-accepted (should be 0).
        public let kiwiHeldoutFalseAccepted: Int
        /// Total held-out kiwi clips that produced an embedding.
        public let kiwiHeldoutTotal: Int

        public init(enrolledClips: Int, negativeClips: Int, survivingMeanSelfSim: Float,
                    lowQuality: Bool, keaviHeldoutAccepted: Int, keaviHeldoutTotal: Int,
                    kiwiHeldoutFalseAccepted: Int, kiwiHeldoutTotal: Int) {
            self.enrolledClips = enrolledClips
            self.negativeClips = negativeClips
            self.survivingMeanSelfSim = survivingMeanSelfSim
            self.lowQuality = lowQuality
            self.keaviHeldoutAccepted = keaviHeldoutAccepted
            self.keaviHeldoutTotal = keaviHeldoutTotal
            self.kiwiHeldoutFalseAccepted = kiwiHeldoutFalseAccepted
            self.kiwiHeldoutTotal = kiwiHeldoutTotal
        }
    }

    private var store = VoiceprintStore()
    private let gate = VoiceprintGate()

    /// Fired after any store mutation (enroll / negative / remove). AppState
    /// wires this to re-install the gate factory, because the factory snapshots
    /// the store BY VALUE at creation time — without a re-install, a voiceprint
    /// enrolled later (e.g. via the wizard, after the factory was installed)
    /// would never reach the live gate.
    public var onStoreChanged: (() -> Void)?

    /// Encrypted-at-rest persistence backend (biometric data). nil → in-memory
    /// only (wiped on quit). Set by main.swift before `loadPersisted()`.
    public var persistence: VoiceprintPersistence?

    /// Enrollment-audio persistence backend (raw WAV clips for future re-derivation).
    /// nil → in-memory only. Set by main.swift after the coordinator is wired.
    public var audioPersistence: EnrollmentAudioPersistence?

    /// Templates loaded from the blob that could NOT be kept in the store
    /// (unknown encoder stamp) but are non-empty and therefore potentially
    /// migratable. Populated by `loadPersisted`; consumed by a future migration
    /// pass. Empty until `loadPersisted` is called. Reset on each call.
    /// `private(set)` so tests can assert without a public setter.
    public private(set) var pendingMigration: [VoiceprintTemplate] = []

    /// Count of voiceprints that could NOT be auto-migrated and therefore need a
    /// manual re-enroll (no stored audio to re-derive from, or the re-derivation
    /// failed the quality bar). Set by `migrateIfNeeded`. A later task surfaces a
    /// banner that OBSERVES this count — deliberately no banner type is referenced
    /// here (R7).
    @Published public private(set) var needsReEnrollCount: Int = 0

    private func notifyStoreChanged() {
        onStoreChanged?()
        // Persist the current set (best-effort; encrypted at rest by the backend).
        if let persistence {
            let templates = store.termIDs.compactMap { store.template(for: $0) }
            try? persistence.save(templates)
        }
    }

    /// Load persisted voiceprints into the store, then install the gate.
    ///
    /// KEEP predicate (R3): a template is upserted iff its encoder stamp is the
    /// current `voiceprintEncoderIdentity` OR a declared `legacyCompatibleStamp`,
    /// AND its voiceprint slice is non-empty.
    ///
    /// SI-1 invariant: `loadPersisted` NEVER writes to the persistence backend.
    /// The on-disk blob is left exactly as found. Pruning/migration is deferred to
    /// a separate migration pass (a later task) that owns all write decisions.
    /// This eliminates the footgun where loading with an empty kept-set would
    /// silently call `save([])` → `deleteAll()`, wiping the user's enrolled data.
    ///
    /// Unknown-stamp non-empty templates are placed into `pendingMigration` so
    /// a future migration pass can re-stamp or re-enroll them.
    ///
    /// A FAILED load (missing key, decode error, downgrade) installs the gate
    /// without touching the blob.
    public func loadPersisted() {
        guard let persistence else { return }
        pendingMigration = []
        let loaded: [VoiceprintTemplate]
        do {
            loaded = try persistence.load()
        } catch {
            // Compliance: log the error TYPE only, never the interpolated
            // value (an error description could echo file paths / blob bytes).
            log("[voiceprint] loadPersisted FAILED (blob preserved): \(type(of: error))")
            onStoreChanged?()   // install gate (empty); do NOT persist → blob preserved
            return
        }
        let current = BundledASREngine.voiceprintEncoderIdentity
        var kept = 0
        for t in loaded {
            let compatible = (t.modelVersion == current
                || BundledASREngine.legacyCompatibleStamps.contains(t.modelVersion))
            if compatible && !t.voiceprint.isEmpty {
                store.upsert(t); kept += 1
            } else if !t.voiceprint.isEmpty {
                // Unknown stamp but non-empty — potentially migratable; park for
                // a future migration pass. Empty templates are silently dropped
                // (nothing to migrate).
                pendingMigration.append(t)
            }
        }
        log("[voiceprint] loadPersisted: loaded=\(loaded.count) kept=\(kept) pending=\(pendingMigration.count) current-model=\(current)")
        onStoreChanged?()   // install gate; do NOT persist (SI-1)
    }

    public init() {}

    /// True once a "Keavi" template has been enrolled (gates shadow eval).
    public var isEnrolled: Bool { store.template(for: Self.termID) != nil }

    private func log(_ message: String) {
        if let data = (message + "\n").data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    // MARK: - Productized enrollment (wizard-driven, generic over any term)

    /// One recorded carrier clip plus the sentence the user read, so the
    /// coordinator can locate the term's (or confusable's) word slot.
    public struct EnrollmentClip: Sendable {
        public let wav: Data
        public let carrierText: String
        public init(wav: Data, carrierText: String) {
            self.wav = wav
            self.carrierText = carrierText
        }
    }

    /// Outcome of a positive enrollment. `harvestedAliases` are the distinct
    /// words FluidAudio heard at the term's slot that differ from the term —
    /// the ground-truth aliases (the wizard then spell-checks them to find
    /// real-word confusables worth a contrastive negative).
    public struct EnrollmentOutcome: Sendable, Equatable {
        public let enrolledClips: Int
        public let survivingMeanSelfSim: Float
        public let lowQuality: Bool
        public let harvestedAliases: [String]
        public init(enrolledClips: Int, survivingMeanSelfSim: Float,
                    lowQuality: Bool, harvestedAliases: [String]) {
            self.enrolledClips = enrolledClips
            self.survivingMeanSelfSim = survivingMeanSelfSim
            self.lowQuality = lowQuality
            self.harvestedAliases = harvestedAliases
        }
    }

    /// True once `termID` has a voiceprint (generic; productized callers use this).
    public func hasVoiceprint(_ termID: String) -> Bool { store.template(for: termID) != nil }
    /// The current template for a term.
    public func template(for termID: String) -> VoiceprintTemplate? { store.template(for: termID) }
    /// All enrolled term IDs.
    public var enrolledTermIDs: [String] { store.termIDs }
    /// Forget one term's voiceprint (privacy delete; also called when its
    /// dictionary term is removed).
    public func removeVoiceprint(termID: String) {
        store.remove(termID: termID)
        try? audioPersistence?.remove(termID: termID)
        notifyStoreChanged()
    }
    /// Forget every voiceprint ("delete all my voiceprints").
    public func removeAll() {
        store.removeAll()
        try? audioPersistence?.deleteAll()
        notifyStoreChanged()
    }

    /// Persist raw enrollment clips for `termID`, merging with any existing map.
    /// Best-effort (errors silently ignored). Logs count only — never audio or text.
    public func storeEnrollmentClips(termID: String, _ clips: [StoredEnrollmentClip]) {
        var map = (try? audioPersistence?.load()) ?? [:]
        map[termID] = clips
        try? audioPersistence?.save(map)
        log("[voiceprint-audio] storeEnrollmentClips term=\(termID) count=\(clips.count)")
    }

    /// Letters-only lowercase normalization (matches the gate's slot key).
    private static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter } }

    /// Index of the carrier word holding `term` (its first sub-word for a
    /// multi-word term). nil if the term isn't found in the sentence.
    static func termSlotIndex(term: String, in carrierText: String) -> Int? {
        let needle = norm(term.split(separator: " ").first.map(String.init) ?? term)
        guard !needle.isEmpty else { return nil }
        let words = carrierText.split(separator: " ").map(String.init)
        return words.firstIndex { norm($0) == needle }
    }

    /// Pool the embedding of the word at `slotIndex` in a transcribed clip, plus
    /// the (normalized) token FluidAudio produced there. nil when the clip yields
    /// no features or the slot is out of range.
    private func localizedSpan(
        wav: Data, slotIndex: Int,
        transcribe: (Data) async throws -> ASRResult?
    ) async -> (embedding: [Float], heard: String)? {
        guard let result = try? await transcribe(wav),
              let timings = result.tokenTimings,
              let features = result.encoderFeatures else { return nil }
        let groups = VoiceprintDemo.wordGroups(from: timings)
        guard slotIndex >= 0, slotIndex < groups.count else { return nil }
        let g = groups[slotIndex]
        guard let emb = features.pooledEmbedding(
            startSeconds: g.startSeconds, endSeconds: g.endSeconds) else { return nil }
        return (emb, Self.norm(g.text))
    }

    /// BUILD (don't store) the POSITIVE voiceprint for `term` from recorded
    /// carriers, harvesting the ground-truth aliases. Returns the DRAFT template
    /// plus the outcome, or nil if no clip produced a usable span. Storage and
    /// persistence are DEFERRED to `commit(_:)` (called from the wizard's Save) —
    /// so an abandoned/cancelled enrollment leaves NOTHING on disk or in the
    /// store. The template is built even when low-quality (the caller warns /
    /// offers re-enroll); a low-quality or absent template simply leaves the gate
    /// quiet (no veto) — never a corruption.
    public func buildPositive(
        termID: String, term: String, carriers: [EnrollmentClip],
        transcribe: (Data) async throws -> ASRResult?
    ) async -> (template: VoiceprintTemplate, outcome: EnrollmentOutcome)? {
        var embeddings: [[Float]] = []
        var heardTokens: [String] = []
        for clip in carriers {
            guard let slot = Self.termSlotIndex(term: term, in: clip.carrierText) else { continue }
            guard let span = await localizedSpan(wav: clip.wav, slotIndex: slot, transcribe: transcribe)
            else { continue }
            embeddings.append(span.embedding)
            heardTokens.append(span.heard)
        }
        guard !embeddings.isEmpty else {
            log("[voiceprint] build term=\(termID): no usable spans")
            return nil
        }
        let result = VoiceprintEnroller.enroll(
            termID: termID, embeddings: embeddings,
            modelVersion: BundledASREngine.voiceprintEncoderIdentity)

        let termKey = Self.norm(term)
        var seen = Set<String>(); var aliases: [String] = []
        for t in heardTokens where t != termKey && !t.isEmpty && !seen.contains(t) {
            seen.insert(t); aliases.append(t)
        }
        log("[voiceprint] built term=\(termID) clips=\(embeddings.count) survivingMeanSelfSim=\(String(format: "%.3f", result.survivingMeanSelfSim)) lowQuality=\(result.template.lowQuality) aliases=\(aliases.count) (not committed)")
        let outcome = EnrollmentOutcome(
            enrolledClips: embeddings.count,
            survivingMeanSelfSim: result.survivingMeanSelfSim,
            lowQuality: result.template.lowQuality,
            harvestedAliases: aliases)
        return (result.template, outcome)
    }

    /// BUILD (don't store) a per-confusable NEGATIVE prototype and attach it to
    /// the DRAFT `template`, from carriers in which the user read the confusable
    /// `label`. Returns the updated draft template (unchanged if no usable
    /// negative span was pooled). Like `buildPositive`, this never touches the
    /// store — `commit(_:)` is the single persist point.
    public func buildNegativeAttached(
        to template: VoiceprintTemplate, label: String, carriers: [EnrollmentClip],
        transcribe: (Data) async throws -> ASRResult?
    ) async -> VoiceprintTemplate {
        var embeddings: [[Float]] = []
        for clip in carriers {
            guard let slot = Self.termSlotIndex(term: label, in: clip.carrierText) else { continue }
            guard let span = await localizedSpan(wav: clip.wav, slotIndex: slot, transcribe: transcribe)
            else { continue }
            embeddings.append(span.embedding)
        }
        guard !embeddings.isEmpty else { return template }
        // withNegative returns self unchanged if nothing usable survived.
        let updated = template.withNegative(label: label, embeddings: embeddings)
        log("[voiceprint] negative-built term=\(template.termID) label=\(label) clips=\(embeddings.count) (not committed)")
        return updated
    }

    /// Commit a DRAFT template into the store — the SINGLE point at which a
    /// voiceprint is stored AND persisted to disk (via `notifyStoreChanged`).
    /// Called from the wizard's Save, so nothing biometric lands on disk before
    /// the user explicitly commits.
    public func commit(_ template: VoiceprintTemplate) {
        store.upsert(template)
        notifyStoreChanged()
    }

    // MARK: - Encoder-change migration (non-destructive, quality-gated; SI-1)

    /// Re-derive a voiceprint for `termID` from its STORED enrollment clips under
    /// the CURRENT encoder (`transcribe` is the live encoder), pooling positives
    /// into the term's voiceprint and attaching each distinct confusable's
    /// negative. Returns the re-stamped DRAFT template plus its quality verdict,
    /// or nil when no positive clip produced a usable span (nothing to migrate).
    /// Pure builder — does NOT touch the store or persistence (`migrateIfNeeded`
    /// owns the install/persist decisions).
    public func buildTemplate(
        from clips: [StoredEnrollmentClip], termID: String,
        transcribe: (Data) async throws -> ASRResult?
    ) async -> (template: VoiceprintTemplate, lowQuality: Bool)? {
        let positives = clips
            .filter { $0.role == .positive }
            .map { EnrollmentClip(wav: $0.wav, carrierText: $0.carrierText) }
        guard let (template, outcome) = await buildPositive(
            termID: termID, term: termID, carriers: positives, transcribe: transcribe)
        else { return nil }

        // Attach one negative prototype per distinct confusable label, preserving
        // first-seen order so the build is deterministic.
        var byLabel: [String: [EnrollmentClip]] = [:]
        var labelOrder: [String] = []
        for clip in clips where clip.role == .negative {
            guard let label = clip.negativeLabel else { continue }
            if byLabel[label] == nil { labelOrder.append(label) }
            byLabel[label, default: []].append(
                EnrollmentClip(wav: clip.wav, carrierText: clip.carrierText))
        }
        var finalTemplate = template
        for label in labelOrder {
            finalTemplate = await buildNegativeAttached(
                to: finalTemplate, label: label, carriers: byLabel[label] ?? [], transcribe: transcribe)
        }
        return (finalTemplate, outcome.lowQuality)
    }

    /// Auto-migrate any `pendingMigration` voiceprints (loaded under an unknown
    /// encoder stamp) by RE-DERIVING them from the stored enrollment audio under
    /// the current encoder. NON-DESTRUCTIVE (R1/SI-1):
    /// - If the audio store fails to load, BAIL without writing — the blob is
    ///   preserved exactly as found.
    /// - A term with no stored audio, or whose re-derivation fails the quality
    ///   bar, stays INERT (kept in `pendingMigration` with its OLD stamp) and is
    ///   counted into `needsReEnrollCount` — never silently dropped.
    /// - We persist only when at least one term migrated, and the payload is the
    ///   active store ∪ the still-inert pending templates, so the on-disk blob
    ///   keeps the inert ones (old stamp) and never collapses to `save([])`.
    /// Logging is COUNT-ONLY (no term text, no audio, no embeddings).
    public func migrateIfNeeded(transcribe: (Data) async throws -> ASRResult?) async {
        guard !pendingMigration.isEmpty, let audioPersistence else { return }
        let audioMap: [String: [StoredEnrollmentClip]]
        do {
            audioMap = try audioPersistence.load()
        } catch {
            // R1: audio unavailable → bail, NO save. The voiceprint blob is left
            // exactly as found (the inert templates keep their old stamp on disk).
            log("[voiceprint] migrate: audio load failed (\(type(of: error))) — blob preserved")
            return
        }
        var migrated = 0
        var discarded = 0
        var stillInert: [VoiceprintTemplate] = []
        for t in pendingMigration {
            guard let clips = audioMap[t.termID], !clips.isEmpty else {
                // No stored audio → can't re-derive; stays inert (needs manual re-enroll).
                stillInert.append(t); discarded += 1; continue
            }
            guard let built = await buildTemplate(from: clips, termID: t.termID, transcribe: transcribe),
                  !built.lowQuality else {
                // Re-derivation failed or low quality → don't install a bad gate; stay inert.
                stillInert.append(t); discarded += 1; continue
            }
            store.upsert(built.template); migrated += 1
        }
        needsReEnrollCount = discarded
        if migrated > 0 {
            // R1: persist active store ∪ still-inert pending. `all` is non-empty
            // (migrated > 0), so this never degrades to save([]) → deleteAll().
            let all = store.termIDs.compactMap { store.template(for: $0) } + stillInert
            try? persistence?.save(all)
        }
        pendingMigration = stillInert
        onStoreChanged?()   // re-install the gate to see the migrated templates
        log("[voiceprint] migrate: migrated=\(migrated) discarded=\(discarded)")
    }

    // MARK: Startup enrollment

    /// Flywheel ts windows (UTC, ISO8601) the maintainer recorded for the demo.
    /// Inclusive bounds.
    private static let keaviWindow = ("2026-06-25T11:15:28Z", "2026-06-25T11:16:35Z")
    private static let kiwiWindow = ("2026-06-25T11:12:45Z", "2026-06-25T11:14:05Z")

    /// One flywheel manifest row (only the fields we need).
    private struct ManifestRow: Decodable {
        let id: String
        let audio: String
        let ts: String
    }

    /// Read the maintainer's flywheel, enroll "Keavi" + a "kiwi" negative, then
    /// self-check the held-out clips through the gate. Idempotent (no-op if
    /// already enrolled). All clip selection is by ts window; the LAST 2 of each
    /// window are held out as a test set and never enrolled.
    ///
    /// `transcribe` decodes a flywheel WAV and returns the raw FluidAudio result
    /// (with encoder features). Injected so this stays testable / decoupled from
    /// LocalASR's concrete type.
    @discardableResult
    public func runStartupEnrollment(
        transcribe: (Data) async throws -> ASRResult?
    ) async -> SelfTestResult? {
        guard !isEnrolled else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let flywheel = home.appendingPathComponent(".parleq/flywheel", isDirectory: true)
        let manifest = flywheel.appendingPathComponent("manifest.jsonl")
        guard let raw = try? String(contentsOf: manifest, encoding: .utf8) else {
            log("[voiceprint] enrollment skipped: no flywheel manifest at ~/.parleq/flywheel/manifest.jsonl")
            return nil
        }

        let decoder = JSONDecoder()
        var keaviRows: [ManifestRow] = []
        var kiwiRows: [ManifestRow] = []
        for line in raw.split(separator: "\n") {
            guard let row = try? decoder.decode(ManifestRow.self, from: Data(line.utf8)) else { continue }
            if row.ts >= Self.keaviWindow.0 && row.ts <= Self.keaviWindow.1 {
                keaviRows.append(row)
            } else if row.ts >= Self.kiwiWindow.0 && row.ts <= Self.kiwiWindow.1 {
                kiwiRows.append(row)
            }
        }
        // Stable chronological order so "last 2 held out" is deterministic.
        keaviRows.sort { $0.ts < $1.ts }
        kiwiRows.sort { $0.ts < $1.ts }

        guard keaviRows.count >= 3, kiwiRows.count >= 1 else {
            log("[voiceprint] enrollment skipped: insufficient flywheel clips (Keavi=\(keaviRows.count), kiwi=\(kiwiRows.count))")
            return nil
        }

        // Hold out the last 2 of each window as a test set.
        let keaviHoldout = Array(keaviRows.suffix(2))
        let keaviEnroll = Array(keaviRows.dropLast(2))
        let kiwiHoldout = Array(kiwiRows.suffix(2))
        let kiwiEnroll = Array(kiwiRows.dropLast(2))

        // Pool a candidate embedding per clip.
        func embeddings(for rows: [ManifestRow]) async -> [[Float]] {
            var out: [[Float]] = []
            for row in rows {
                let wavURL = flywheel.appendingPathComponent(row.audio)
                guard let data = try? Data(contentsOf: wavURL) else { continue }
                guard let result = try? await transcribe(data),
                      let timings = result.tokenTimings,
                      let features = result.encoderFeatures else { continue }
                guard let group = VoiceprintDemo.kiwiCandidateGroup(in: timings) else { continue }
                guard let emb = features.pooledEmbedding(
                    startSeconds: group.startSeconds, endSeconds: group.endSeconds) else { continue }
                out.append(emb)
            }
            return out
        }

        let keaviEmb = await embeddings(for: keaviEnroll)
        let kiwiEmb = await embeddings(for: kiwiEnroll)

        guard !keaviEmb.isEmpty else {
            log("[voiceprint] enrollment failed: no usable Keavi candidate embeddings")
            return nil
        }

        let result = VoiceprintEnroller.enroll(
            termID: Self.termID,
            embeddings: keaviEmb,
            modelVersion: BundledASREngine.voiceprintEncoderIdentity
        )
        let template = result.template.withNegative(label: Self.negativeLabel, embeddings: kiwiEmb)
        store.upsert(template)
        notifyStoreChanged()

        log("[voiceprint] enrolled term=\(Self.termID) clips=\(keaviEmb.count) negativeClips=\(kiwiEmb.count) survivingMeanSelfSim=\(String(format: "%.3f", result.survivingMeanSelfSim)) lowQuality=\(template.lowQuality)")

        // SELF-CHECK on held-out clips.
        let keaviTestEmb = await embeddings(for: keaviHoldout)
        let kiwiTestEmb = await embeddings(for: kiwiHoldout)
        var keaviAccept = 0
        for e in keaviTestEmb where gate.decide(candidate: e, against: template).accept { keaviAccept += 1 }
        var kiwiFalseAccept = 0
        for e in kiwiTestEmb where gate.decide(candidate: e, against: template).accept { kiwiFalseAccept += 1 }
        log("[voiceprint-selftest] Keavi held-out accept \(keaviAccept)/\(keaviTestEmb.count), kiwi held-out false-accept \(kiwiFalseAccept)/\(kiwiTestEmb.count)")

        return SelfTestResult(
            enrolledClips: keaviEmb.count,
            negativeClips: kiwiEmb.count,
            survivingMeanSelfSim: result.survivingMeanSelfSim,
            lowQuality: template.lowQuality,
            keaviHeldoutAccepted: keaviAccept,
            keaviHeldoutTotal: keaviTestEmb.count,
            kiwiHeldoutFalseAccepted: kiwiFalseAccept,
            kiwiHeldoutTotal: kiwiTestEmb.count
        )
    }

    // MARK: Live shadow evaluation

    /// SHADOW evaluation on a real dictation. When a "kiwi"-token word-group
    /// appears in this utterance, pool its embedding from the utterance's
    /// encoder features and run the gate against the enrolled "Keavi" template.
    /// LOGS the decision only — never modifies the transcript/paste. No-op when
    /// no voiceprint is enrolled, the utterance has no encoder features, or no
    /// kiwi-token group is present.
    public func evaluateShadow(diagnostics: ASRDiagnostics?) {
        guard let template = store.template(for: Self.termID) else { return }
        guard let diagnostics, let features = diagnostics.encoderFeatures else { return }
        let timings = diagnostics.tokenTimings.map {
            TokenTiming(token: $0.token, tokenId: $0.tokenId,
                        startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence)
        }
        guard let group = VoiceprintDemo.kiwiCandidateGroup(in: timings) else { return }
        guard let emb = features.pooledEmbedding(
            startSeconds: group.startSeconds, endSeconds: group.endSeconds) else { return }

        let decision = gate.decide(candidate: emb, against: template)
        let verdict = decision.accept ? "ACCEPT(\(Self.termID))" : "REJECT"
        let neg = decision.worstNegativeSimilarity.map { String(format: "%.3f", $0) } ?? "n/a"
        log("[voiceprint-shadow] heard 'kiwi'-token -> gate: \(verdict) termSim=\(String(format: "%.3f", decision.termSimilarity)) negSim=\(neg) margin=\(String(format: "%.3f", decision.margin))  (SHADOW: output unchanged)")
    }

    // MARK: Live ENFORCEMENT gate

    /// A word group with its pooled acoustic embedding — a Sendable snapshot so the returned
    /// `AcousticGate` closure captures only value types (decoupled from FluidAudio's non-Sendable
    /// `EncoderFeatureSequence`). Pooled ONCE per utterance, reusing already-computed encoder
    /// features.
    private struct SpanEmbedding: Sendable {
        let normalizedText: String   // letters-only, lowercased (text-locator fallback)
        let groupIndex: Int          // position among the utterance's word groups
        let startSeconds: Double     // the word's audio window (primary locator)
        let endSeconds: Double
        let embedding: [Float]
    }

    /// A `@Sendable` factory the Concord provider holds: given an utterance's diagnostics it returns
    /// the acoustic gate (or nil). It captures only a Sendable snapshot of the enrolled
    /// `VoiceprintStore` + stateless gate, so it runs safely off the MainActor inside
    /// `generateStreaming`. Returns nil unless enforcement is on AND a voiceprint is enrolled.
    public func enforcementGateFactory() -> @Sendable (ASRDiagnostics?) -> AcousticGate? {
        let store = self.store    // value-type snapshot
        let gate = self.gate
        return { diagnostics in
            Self.buildGate(diagnostics: diagnostics, store: store, gate: gate)
        }
    }

    /// Build the acoustic gate the engine consults for one utterance, or nil when enforcement is off
    /// / nothing is enrolled / the utterance carries no encoder features. Pools each word group's
    /// embedding ONCE (reusing already-computed encoder features) into a Sendable snapshot, then
    /// returns a `@Sendable` closure that, for a substitution to a gate-known term, locates the
    /// heard word's span by text (disambiguating repeats via the engine's word index) and returns
    /// accept/reject. A term with no voiceprint — or a span it cannot locate/pool — yields
    /// `.noOpinion`, so the engine behaves exactly as if no gate were present (the gate only ever
    /// REMOVES an over-fire it can confirm; it never introduces new harm).
    nonisolated static func buildGate(diagnostics: ASRDiagnostics?,
                                      store: VoiceprintStore,
                                      gate: VoiceprintGate) -> AcousticGate? {
        // Self-gating: with nothing enrolled there is no gate at all (zero overhead,
        // byte-identical baseline). Enrollment presence — not an env flag — turns it on.
        guard store.count > 0 else { return nil }
        guard let diagnostics, let features = diagnostics.encoderFeatures else { return nil }

        let timings = diagnostics.tokenTimings.map {
            TokenTiming(token: $0.token, tokenId: $0.tokenId,
                        startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence)
        }
        let wordGroups = VoiceprintDemo.wordGroups(from: timings)
        var singleWordSpans: [SpanEmbedding] = []
        var windowSpans: [SpanEmbedding] = []

        // Single-word spans (original behavior — preserved in full).
        for (i, g) in wordGroups.enumerated() {
            guard let emb = features.pooledEmbedding(
                startSeconds: g.startSeconds, endSeconds: g.endSeconds) else { continue }
            let normalized = g.text.lowercased().filter { $0.isLetter }
            singleWordSpans.append(SpanEmbedding(normalizedText: normalized, groupIndex: i,
                                                  startSeconds: g.startSeconds, endSeconds: g.endSeconds,
                                                  embedding: emb))
        }

        // Adjacent 2-word windows — enables merged-span queries (e.g. "Ki V" → "Keavi").
        // Stored separately so the text+occurrence fallback can exclude them (their
        // concatenated normalizedText, e.g. "kiv", would produce spurious .contains matches).
        for i in 0..<(wordGroups.count - 1) {
            let first = wordGroups[i], second = wordGroups[i + 1]
            guard let emb = features.pooledEmbedding(
                startSeconds: first.startSeconds, endSeconds: second.endSeconds) else { continue }
            let normalized = (first.text + second.text).lowercased().filter { $0.isLetter }
            windowSpans.append(SpanEmbedding(normalizedText: normalized, groupIndex: i,
                                              startSeconds: first.startSeconds, endSeconds: second.endSeconds,
                                              embedding: emb))
        }

        // Adjacent 3-word windows.
        for i in 0..<(wordGroups.count - 2) {
            let first = wordGroups[i], last = wordGroups[i + 2]
            guard let emb = features.pooledEmbedding(
                startSeconds: first.startSeconds, endSeconds: last.endSeconds) else { continue }
            let normalized = (wordGroups[i].text + wordGroups[i + 1].text + wordGroups[i + 2].text)
                .lowercased().filter { $0.isLetter }
            windowSpans.append(SpanEmbedding(normalizedText: normalized, groupIndex: i,
                                              startSeconds: first.startSeconds, endSeconds: last.endSeconds,
                                              embedding: emb))
        }

        guard !singleWordSpans.isEmpty || !windowSpans.isEmpty else { return nil }
        // `frozenSpans` = single-word only; used by the text+occurrence fallback (prevents
        // concatenated window text, e.g. "kiv", from producing spurious .contains matches).
        // `allFrozenSpans` = single-word + windows; used by the IoU / nearest-start locators
        // so multi-word merged-span queries still find the right pooled window.
        let frozenSpans = singleWordSpans
        let allFrozenSpans = singleWordSpans + windowSpans

        return { ctx in
            guard let template = store.template(for: ctx.termID) else { return .noOpinion }
            // Locate the candidate span. PREFER the engine-provided audio window (robust to a
            // biasing rewrite, where the word's TEXT no longer matches the raw token label).
            // When both start and end are provided, pick the stored span with the highest IoU
            // against the query window — this correctly prefers the exact single-word span
            // (IoU 1.0) over a wider window for a single-word query, while also preferring
            // the right multi-word pooled window for a merged-span query. Fall back to
            // nearest-start when endSeconds is unset or no span overlaps the query window.
            // Fall back to text + occurrence when no audio window is provided (HTTP ASR path).
            let span: SpanEmbedding
            if let start = ctx.startSeconds {
                if let end = ctx.endSeconds {
                    // IoU-based locator: pick the pooled span with the best overlap.
                    // Uses allFrozenSpans (single-word + windows) so multi-word merged-span
                    // queries (e.g. "Ki V" → "Keavi") can find the right pooled window.
                    let bestByIoU = allFrozenSpans.max { lhs, rhs in
                        let interL = max(0.0, min(lhs.endSeconds, end) - max(lhs.startSeconds, start))
                        let unionL = (lhs.endSeconds - lhs.startSeconds) + (end - start) - interL
                        let iouL   = unionL > 0 ? interL / unionL : 0.0
                        let interR = max(0.0, min(rhs.endSeconds, end) - max(rhs.startSeconds, start))
                        let unionR = (rhs.endSeconds - rhs.startSeconds) + (end - start) - interR
                        let iouR   = unionR > 0 ? interR / unionR : 0.0
                        return iouL < iouR
                    }
                    guard let best = bestByIoU else { return .noOpinion }
                    let inter = max(0.0, min(best.endSeconds, end) - max(best.startSeconds, start))
                    let union = (best.endSeconds - best.startSeconds) + (end - start) - inter
                    if union > 0 && inter / union > 0 {
                        span = best
                    } else {
                        // No overlap — fall back to nearest-start (all spans).
                        guard let nearest = allFrozenSpans.min(by: {
                            abs($0.startSeconds - start) < abs($1.startSeconds - start)
                        }) else { return .noOpinion }
                        span = nearest
                    }
                } else {
                    // endSeconds not set — nearest-start (original behavior, HTTP ASR path).
                    // Uses allFrozenSpans for maximum locator accuracy.
                    guard let best = allFrozenSpans.min(by: {
                        abs($0.startSeconds - start) < abs($1.startSeconds - start)
                    }) else { return .noOpinion }
                    span = best
                }
            } else {
                // No audio window at all — text + occurrence fallback.
                let needle = ctx.originalWord.lowercased().filter { $0.isLetter }
                guard !needle.isEmpty else { return .noOpinion }
                let matches = frozenSpans
                    .filter { $0.normalizedText == needle || $0.normalizedText.contains(needle) }
                    .sorted { $0.groupIndex < $1.groupIndex }
                guard !matches.isEmpty else { return .noOpinion }
                span = ctx.occurrence < matches.count ? matches[ctx.occurrence] : matches[matches.count - 1]
            }
            // The DECISION POLICY lives in Concord's `VoiceprintGate.evaluate`. Validation mode
            // (the ASR emitted the term itself — a likely biasing recovery) reverts only on a
            // confident negative margin; substitution mode (Concord wants to swap an alias → term)
            // vetoes when the audio is a confusable. The revert-margin floor and the near-tie
            // "keep the term" rule are Concord's, not the caller's.
            let termKey = ctx.termID.lowercased().filter { $0.isLetter }
            let needle = ctx.originalWord.lowercased().filter { $0.isLetter }
            let mode: GateMode = (needle == termKey) ? .validation : .substitution
            return gate.evaluate(candidate: span.embedding, against: template, mode: mode)
        }
    }
}
#endif
