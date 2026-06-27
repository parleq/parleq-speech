import XCTest
@testable import ParleqAppCore

#if Concord
import Concord

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
        // The legacy 0.29.0 stamp ("0.15.4-encoder.1" == fluidAudioVersion) is in
        // legacyCompatibleStamps, so the template is kept without re-stamping.
        let v = BundledASREngine.fluidAudioVersion  // "0.15.4-encoder.1"
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
}

#endif
