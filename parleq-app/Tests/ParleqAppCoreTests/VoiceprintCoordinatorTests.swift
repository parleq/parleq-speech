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
        // Match the model version the coordinator stamps so nothing is pruned.
        let v = BundledASREngine.fluidAudioVersion
        let stub = StubPersistence(.success([tmpl("Keavi", version: v)]))
        c.persistence = stub
        c.loadPersisted()
        XCTAssertTrue(c.hasVoiceprint("Keavi"))
        XCTAssertEqual(stub.saved, [], "no pruning → no redundant rewrite")
    }

    func test_loadPersisted_prunes_stale_version_and_resaves() {
        let c = VoiceprintCoordinator()
        let stub = StubPersistence(.success([tmpl("Old", version: "ancient-version")]))
        c.persistence = stub
        c.loadPersisted()
        XCTAssertFalse(c.hasVoiceprint("Old"), "stale model-version template dropped")
        XCTAssertEqual(stub.saved.count, 1, "pruned set re-persisted")
        XCTAssertEqual(stub.saved.first?.count, 0, "the empty (all-stale) set saved → blob pruned")
    }

    // MARK: restore (fix B mechanism: cancel can restore a prior template)

    func test_restoreTemplate_round_trips() {
        let c = VoiceprintCoordinator()
        let t = tmpl("Keavi")
        c.restoreTemplate(t)
        XCTAssertEqual(c.template(for: "Keavi"), t)
        XCTAssertTrue(c.hasVoiceprint("Keavi"))
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
