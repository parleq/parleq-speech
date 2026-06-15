import XCTest
@testable import ParleqAppCore

/// Regression guard for the 0.19.0 fast-double-tap bug: a chatter-rejection floor
/// of 40 ms silently rejected genuine fast double-taps (measured at 29–33 ms,
/// worse under Karabiner-Elements), breaking quick mode + continuous recording.
/// The floor is now 12 ms — chatter still rejected, fast human taps accepted.
final class DoubleTapGapTests: XCTestCase {

    func testFastHumanDoubleTapsAreAccepted() {
        // The exact gaps measured from the bug report.
        for gap in [0.029, 0.033, 0.052] {
            XCTAssertTrue(HotkeyListener.classifiesAsDoubleTap(gap: gap),
                          "a \(Int(gap * 1000))ms gap should register as a double-tap")
        }
    }

    func testChatterIsRejected() {
        // Near-instant re-emits (driver chatter) stay rejected.
        XCTAssertFalse(HotkeyListener.classifiesAsDoubleTap(gap: 0.006))
        XCTAssertFalse(HotkeyListener.classifiesAsDoubleTap(gap: 0.0))
    }

    func testGapBeyondWindowIsNotADoubleTap() {
        // Two separate presses, not a double-tap.
        XCTAssertFalse(HotkeyListener.classifiesAsDoubleTap(gap: 0.35))
        XCTAssertFalse(HotkeyListener.classifiesAsDoubleTap(gap: 2.0))
    }
}
