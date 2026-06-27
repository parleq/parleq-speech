import XCTest
@testable import ParleqAppCore

#if Concord
import Concord

// MARK: - Stub

/// Records calls to `deleteAll`; load/save/remove are no-ops.
private final class StubAudioPersistence: EnrollmentAudioPersistence, @unchecked Sendable {
    private(set) var deleteAllCallCount = 0
    func load() throws -> [String: [StoredEnrollmentClip]] { [:] }
    func save(_ byTerm: [String: [StoredEnrollmentClip]]) throws {}
    func remove(termID: String) throws {}
    func deleteAll() throws { deleteAllCallCount += 1 }
}

// MARK: - Tests

@MainActor
final class ClipStorageEnforceTests: XCTestCase {

    /// SI-2: `enforceClipStoragePolicy(enabled: false)` must call `deleteAll` once.
    func test_enforceOff_deletesAll() {
        let c = VoiceprintCoordinator()
        let stub = StubAudioPersistence()
        c.audioPersistence = stub
        c.enforceClipStoragePolicy(enabled: false)
        XCTAssertEqual(stub.deleteAllCallCount, 1,
            "clip storage disabled → deleteAll must be called exactly once")
    }

    /// SI-2: `enforceClipStoragePolicy(enabled: true)` must NOT call `deleteAll`.
    func test_enforceOn_doesNotDelete() {
        let c = VoiceprintCoordinator()
        let stub = StubAudioPersistence()
        c.audioPersistence = stub
        c.enforceClipStoragePolicy(enabled: true)
        XCTAssertEqual(stub.deleteAllCallCount, 0,
            "clip storage enabled → deleteAll must NOT be called")
    }

    /// SI-2: calling with a nil `audioPersistence` must not crash.
    func test_enforceOff_nilPersistence_noCrash() {
        let c = VoiceprintCoordinator()
        // audioPersistence defaults to nil
        XCTAssertNil(c.audioPersistence)
        // Must not crash regardless of enabled flag.
        c.enforceClipStoragePolicy(enabled: false)
        c.enforceClipStoragePolicy(enabled: true)
    }
}

#endif
