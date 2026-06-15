import XCTest
@testable import ParleqAppCore

/// B3 (lost-dictation safety net): "recover last dictation" can only run when a
/// fresh-capture audio buffer is retained in memory. No buffer (fresh launch,
/// or the last capture was dead-input and never retained) → nothing to recover.
final class RecoveryEligibilityTests: XCTestCase {

    func testCanRecoverWhenBufferRetained() {
        XCTAssertTrue(RecoveryEligibility.canRecover(hasRetainedAudio: true))
    }

    func testCannotRecoverWithoutBuffer() {
        XCTAssertFalse(RecoveryEligibility.canRecover(hasRetainedAudio: false))
    }
}
