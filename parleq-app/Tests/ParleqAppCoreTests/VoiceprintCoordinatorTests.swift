import XCTest
@testable import ParleqAppCore

#if Concord
import Concord
import FluidAudio

/// Records persistence calls; load result is injectable to exercise failure paths.
private final class StubPersistence: VoiceprintPersistence, @unchecked Sendable {
    var loadResult: Result<[VoiceprintTemplate], Error>
    private(set) var saved: [[VoiceprintTemplate]] = []
    private(set) var deletedCount = 0
    init(_ loadResult: Result<[VoiceprintTemplate], Error>) { self.loadResult = loadResult }
    func load() throws -> [VoiceprintTemplate] { try loadResult.get() }
    func save(_ templates: [VoiceprintTemplate]) throws { saved.append(templates) }
    func deleteAll() throws { deletedCount += 1 }
}

private struct StubError: Error {}

private func tmpl(_ id: String, version: String = "test-v") -> VoiceprintTemplate {
    VoiceprintTemplate(termID: id, voiceprint: [0.1, 0.2, 0.3],
                       negatives: ["kiwi": [0.9, 0.8, 0.7]], dim: 3,
                       lowQuality: false, modelVersion: version)
}

@MainActor
final class VoiceprintCoordinatorTests: XCTestCase {

    // MARK: persistence (fix A: a FAILED load must never wipe the blob)

    func test_loadPersisted_failure_does_not_save() {
        let c = VoiceprintCoordinator()
        let stub = StubPersistence(.failure(StubError()))
        c.persistence = stub
        var gateInstalls = 0
        c.onStoreChanged = { gateInstalls += 1 }
        c.loadPersisted()
        XCTAssertEqual(stub.saved, [], "a failed load must NOT persist (would wipe the blob)")
        XCTAssertEqual(stub.deletedCount, 0)
        XCTAssertGreaterThan(gateInstalls, 0, "gate is still installed after a failed load")
    }

    func test_loadPersisted_happy_path_does_not_rewrite() {
        let c = VoiceprintCoordinator()
        // A template stamped with a legacy-compatible stamp is kept without
        // re-stamping. Use the ACTUAL legacy stamp (the 0.29.0-era value in
        // legacyCompatibleStamps), NOT BundledASREngine.fluidAudioVersion — those
        // two diverged once fluidAudioVersion bumped past 0.15.4-encoder.1 (the
        // flywheel stamp moves with FluidAudio bumps; the voiceprint legacy set
        // is frozen because the encoder graph is unchanged).
        let v = BundledASREngine.legacyCompatibleStamps.first!  // "0.15.4-encoder.1"
        let stub = StubPersistence(.success([tmpl("Keavi", version: v)]))
        c.persistence = stub
        c.loadPersisted()
        XCTAssertTrue(c.hasVoiceprint("Keavi"))
        XCTAssertEqual(stub.saved, [], "no pruning → no redundant rewrite")
    }

    /// R1: loadPersisted NEVER calls save/deleteAll (SI-1 — the blob is never
    /// emptied by a load, even when an unknown-stamp template is encountered).
    /// Unknown-stamp templates land in `pendingMigration`; migration owns writes.
    func test_loadPersisted_unknown_version_parks_in_pendingMigration_not_resaved() {
        let c = VoiceprintCoordinator()
        let stub = StubPersistence(.success([tmpl("Old", version: "ancient-version")]))
        c.persistence = stub
        c.loadPersisted()
        XCTAssertFalse(c.hasVoiceprint("Old"), "unknown-stamp template not upserted into store")
        XCTAssertEqual(stub.saved.count, 0,
            "loadPersisted must NOT write (SI-1) — migration pass owns the re-persist")
        XCTAssertEqual(c.pendingMigration.count, 1, "unknown non-empty template is pending migration")
        XCTAssertEqual(c.pendingMigration.first?.termID, "Old")
    }

    // MARK: commit is the single store/persist point (deferred from analyze to Save)

    func test_commit_stores_and_persists() {
        let c = VoiceprintCoordinator()
        let stub = StubPersistence(.success([]))
        c.persistence = stub
        let t = tmpl("Keavi")
        XCTAssertFalse(c.hasVoiceprint("Keavi"))
        c.commit(t)
        XCTAssertEqual(c.template(for: "Keavi"), t)
        XCTAssertTrue(c.hasVoiceprint("Keavi"))
        XCTAssertEqual(stub.saved.count, 1, "commit is the persist point")
    }

    /// The rename-cleanup invariant the edit sheet relies on: removing the OLD-key
    /// voiceprint after a rename→enroll must NOT disturb the newly-enrolled term's
    /// print (they're keyed by distinct terms). Regression guard for the rename→
    /// enroll→close path that previously rebaselined originalTerm and orphaned old.
    func test_removeVoiceprint_old_key_leaves_new_term_intact() {
        let c = VoiceprintCoordinator()
        c.persistence = StubPersistence(.success([]))
        c.commit(tmpl("Keavi"))   // old (pre-rename) print
        c.commit(tmpl("Keavy"))   // new term, freshly enrolled after the rename
        c.removeVoiceprint(termID: "Keavi")   // cleanupOrphanedVoiceprintOnRename drops only OLD
        XCTAssertFalse(c.hasVoiceprint("Keavi"), "stale old-term orphan removed")
        XCTAssertTrue(c.hasVoiceprint("Keavy"), "just-enrolled new-term print survives")
    }

    /// buildPositive / buildNegativeAttached must NOT touch the store: a draft is
    /// only committed at Save, so an abandoned wizard leaves nothing behind. With
    /// a nil-transcribe stub buildPositive yields no usable spans (returns nil) —
    /// either way the store stays empty until commit.
    func test_build_does_not_store_until_commit() async {
        let c = VoiceprintCoordinator()
        let stub = StubPersistence(.success([]))
        c.persistence = stub
        let clips = [VoiceprintCoordinator.EnrollmentClip(wav: Data([1]), carrierText: "Keavi is here")]
        let built = await c.buildPositive(termID: "Keavi", term: "Keavi", carriers: clips,
                                          transcribe: { _ in nil })
        XCTAssertNil(built, "no usable spans → nil")
        XCTAssertFalse(c.hasVoiceprint("Keavi"))
        XCTAssertEqual(stub.saved, [], "build never persists")

        // buildNegativeAttached returns the (unchanged) draft without storing.
        let updated = await c.buildNegativeAttached(to: tmpl("Keavi"), label: "kiwi", carriers: clips,
                                                    transcribe: { _ in nil })
        XCTAssertEqual(updated, tmpl("Keavi"))
        XCTAssertFalse(c.hasVoiceprint("Keavi"))
        XCTAssertEqual(stub.saved, [], "build never persists")
    }

    /// Deterministic synthetic ASRResult: the carrier "I use <word> every day" with `word`
    /// planted at slot index 2, and an `EncoderFeatureSequence` whose (single, uniform) window
    /// carries `frameValue` at every position — so the slot's pooled embedding is exactly
    /// `[frameValue, frameValue, frameValue, frameValue]`. Two clips at the SAME frameValue are
    /// perfectly self-similar (cosine 1.0); a clip at the OPPOSITE-sign frameValue is
    /// anti-correlated (cosine -1.0) with a centroid of the others — reliably below
    /// `VoiceprintEnroller.defaultQualityFloor` (0.70), so it's dropped by the leave-one-out gate.
    private static func makeSlotResult(word: String, frameValue: Float) -> ASRResult {
        let words = ["I", "use", word, "every", "day"]
        var timings: [TokenTiming] = []
        var t = 0.0
        for (i, w) in words.enumerated() {
            let token = i == 0 ? w : " " + w
            timings.append(TokenTiming(token: token, tokenId: 1, startTime: t, endTime: t + 0.4, confidence: 1.0))
            t += 0.5
        }
        let window = EncoderFeatureSequence.Window(
            frames: Array(repeating: [Float](repeating: frameValue, count: 4), count: 40),
            globalFrameOffset: 0)
        let features = EncoderFeatureSequence(windows: [window], hiddenSize: 4, secondsPerFrame: 0.1)
        return ASRResult(text: words.joined(separator: " "), confidence: 1.0, duration: 2.5,
                         processingTime: 0.1, tokenTimings: timings, encoderFeatures: features)
    }

    /// Regression guard for b1a9f5c: a mis-localized enrollment clip whose span the LOO quality
    /// gate DROPS must not contribute its heard token as a harvested alias/confusable. Four
    /// carriers: THREE normal clips (heard="keavi", embedding +0.5 — mutually identical, so each
    /// survives the leave-one-out gate with self-similarity 1.0 regardless of the outlier's
    /// presence in its LOO centroid, since cosine only depends on direction and the outlier can't
    /// flip the centroid's sign with 3-to-1 normal clips outweighing it), and one OUTLIER clip
    /// (heard="is" — a plausible onset-clipped mishear — embedding -0.5, opposite sign) whose LOO
    /// cosine to the centroid of the 3 normal clips is exactly -1.0, far under the 0.70 floor, so
    /// `VoiceprintEnroller.enroll` reports it in `droppedIndices` while the 3 normal clips survive
    /// (asserted via `survivingMeanSelfSim`). Before b1a9f5c, buildPositive harvested from EVERY
    /// localized span regardless of the gate's verdict, so "is" would have leaked into
    /// `harvestedAliases` even though the surviving centroid excluded it.
    func test_buildPositive_excludes_droppedClip_heard_token_from_harvestedAliases() async {
        let c = VoiceprintCoordinator()
        c.persistence = StubPersistence(.success([]))

        let carrierText = "I use Keavi every day"
        let clip1 = VoiceprintCoordinator.EnrollmentClip(wav: Data([1]), carrierText: carrierText)
        let clip2 = VoiceprintCoordinator.EnrollmentClip(wav: Data([2]), carrierText: carrierText)
        let clip3 = VoiceprintCoordinator.EnrollmentClip(wav: Data([3]), carrierText: carrierText)
        let outlierClip = VoiceprintCoordinator.EnrollmentClip(wav: Data([4]), carrierText: carrierText)

        let normalResult = Self.makeSlotResult(word: "keavi", frameValue: 0.5)
        let outlierResult = Self.makeSlotResult(word: "is", frameValue: -0.5)

        let transcribe: @Sendable (Data) async throws -> ASRResult? = { wav in
            switch wav {
            case Data([1]), Data([2]), Data([3]): return normalResult
            case Data([4]): return outlierResult
            default: return nil
            }
        }

        let built = await c.buildPositive(termID: "Keavi", term: "Keavi",
                                          carriers: [clip1, clip2, clip3, outlierClip],
                                          transcribe: transcribe)
        guard let (_, outcome) = built else {
            XCTFail("expected buildPositive to yield a draft template")
            return
        }
        XCTAssertEqual(outcome.enrolledClips, 4, "all 4 clips produced a usable localized span")
        XCTAssertEqual(outcome.survivingMeanSelfSim, 1.0, accuracy: 0.0001,
            "the 3 normal clips survive the LOO gate at perfect self-similarity — only the " +
            "opposite-sign outlier is dropped, not the whole batch")
        XCTAssertFalse(outcome.lowQuality, "3 surviving clips at meanSelfSim 1.0 clears the quality bar")
        XCTAssertFalse(outcome.harvestedAliases.contains("is"),
            "the dropped clip's heard token must NOT become a harvested alias — the LOO gate " +
            "already judged its span an outlier")
    }

    func test_termSlotIndex_finds_single_word_term() {
        XCTAssertEqual(VoiceprintCoordinator.termSlotIndex(term: "Keavi", in: "I use Keavi every day"), 2)
        XCTAssertEqual(VoiceprintCoordinator.termSlotIndex(term: "Keavi", in: "Keavi is what I meant."), 0)
        XCTAssertEqual(VoiceprintCoordinator.termSlotIndex(term: "Keavi", in: "Tell me about Keavi."), 3)
    }

    func test_termSlotIndex_is_case_and_punctuation_insensitive() {
        XCTAssertEqual(VoiceprintCoordinator.termSlotIndex(term: "keavi", in: "Open KEAVI, please."), 1)
    }

    func test_termSlotIndex_multiword_term_uses_first_subword() {
        XCTAssertEqual(VoiceprintCoordinator.termSlotIndex(term: "Keavi LLC", in: "I work at Keavi LLC now"), 3)
    }

    func test_termSlotIndex_nil_when_absent() {
        XCTAssertNil(VoiceprintCoordinator.termSlotIndex(term: "Keavi", in: "I had a kiwi for lunch"))
    }

    func test_remove_and_query_on_empty_store() {
        let c = VoiceprintCoordinator()
        XCTAssertFalse(c.hasVoiceprint("Keavi"))
        XCTAssertEqual(c.enrolledTermIDs, [])
        c.removeVoiceprint(termID: "Keavi")   // no crash on absent
        c.removeAll()
    }

    // MARK: 7086 — deletion must not resurrect pending templates

    /// (a) removeVoiceprint of a pending-only term must actually delete it:
    /// after reload the store must be empty (not resurrected from the on-disk blob).
    func test_7086_removeVoiceprint_of_pending_only_term_is_gone_after_reload() {
        let c = VoiceprintCoordinator()
        let stub = StubPersistence(.success([tmpl("Old", version: "ancient")]))
        c.persistence = stub
        c.loadPersisted()
        XCTAssertFalse(c.hasVoiceprint("Old"), "pending-only term not in active store")
        XCTAssertEqual(c.pendingMigration.count, 1, "parked in pendingMigration")
        XCTAssertEqual(c.needsReEnrollCount, 0, "not yet bumped by migration")

        // Delete the pending-only term via removeVoiceprint.
        c.removeVoiceprint(termID: "Old")

        XCTAssertEqual(c.pendingMigration.count, 0, "pending slot cleared on delete")
        // The saved payload must NOT contain "Old" — if it does, a new load would
        // resurrect it.
        guard let saved = stub.saved.last else {
            XCTFail("removeVoiceprint must have persisted (notifyStoreChanged)")
            return
        }
        XCTAssertFalse(saved.map { $0.termID }.contains("Old"),
                       "deleted pending-only term must not appear in the saved payload")
    }

    /// (b) removeAll with mixed active + pending leaves the store empty on reload —
    /// no resurrected biometric templates.
    func test_7086_removeAll_mixed_active_and_pending_leaves_empty_on_reload() {
        let c = VoiceprintCoordinator()
        // Load: one current (active) + one stale (pending).
        let current = BundledASREngine.voiceprintEncoderIdentity
        let stub = StubPersistence(.success([
            tmpl("Active", version: current),
            tmpl("Old", version: "ancient"),
        ]))
        c.persistence = stub
        c.loadPersisted()
        XCTAssertTrue(c.hasVoiceprint("Active"))
        XCTAssertEqual(c.pendingMigration.count, 1)

        c.removeAll()

        // Both the active store and pendingMigration must be cleared.
        XCTAssertFalse(c.hasVoiceprint("Active"), "active template removed")
        XCTAssertEqual(c.pendingMigration.count, 0, "pendingMigration cleared on removeAll")
        XCTAssertEqual(c.needsReEnrollCount, 0, "needsReEnrollCount reset on removeAll")
        // The saved payload must be empty — a future load sees an empty store.
        guard let saved = stub.saved.last else {
            XCTFail("removeAll must have persisted (notifyStoreChanged)")
            return
        }
        XCTAssertTrue(saved.isEmpty,
                      "saved payload must be empty after removeAll — no resurrected templates")
    }

    /// (c) A normal commit still preserves an unrelated pending template — no
    /// regression of 7027/7032 behavior.
    func test_7086_commit_preserves_unrelated_pending_template() {
        let c = VoiceprintCoordinator()
        let stub = StubPersistence(.success([tmpl("Old", version: "ancient")]))
        c.persistence = stub
        c.loadPersisted()
        XCTAssertEqual(c.pendingMigration.count, 1)

        // Commit a fresh, unrelated term.
        let current = BundledASREngine.voiceprintEncoderIdentity
        c.commit(VoiceprintTemplate(termID: "NewTerm", voiceprint: [1, 0, 0, 0],
                                    negatives: [:], dim: 4, lowQuality: false,
                                    modelVersion: current))

        // The inert "Old" template must still be in the saved union — not dropped.
        guard let saved = stub.saved.last else {
            XCTFail("commit must persist")
            return
        }
        let ids = Set(saved.map { $0.termID })
        XCTAssertTrue(ids.contains("Old"),
                      "inert pending template must survive an unrelated commit (7027/7032)")
        XCTAssertTrue(ids.contains("NewTerm"), "newly committed term present")
        XCTAssertEqual(c.pendingMigration.count, 1, "commit of an unrelated term must not touch pendingMigration")
    }
}

#endif
