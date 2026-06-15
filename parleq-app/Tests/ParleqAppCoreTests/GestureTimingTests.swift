import XCTest
@testable import ParleqAppCore

/// Pure timing classifier for #83's double-tap-and-release gesture. The decision
/// is made at key-UP: a double-tap whose second press is released quickly (a
/// "tap", not a "hold") means continuous recording; held longer means today's
/// quick mode. The CGEventTap timing + AppState transition are wired separately.
final class GestureTimingTests: XCTestCase {
    private let threshold: TimeInterval = 0.35

    func testShortHoldAfterDoubleTapIsContinuousRelease() {
        XCTAssertTrue(GestureTiming.isContinuousRelease(
            wasDoubleTapDown: true, holdDuration: 0.10, threshold: threshold))
    }

    func testLongHoldAfterDoubleTapIsQuickModeNotContinuous() {
        XCTAssertFalse(GestureTiming.isContinuousRelease(
            wasDoubleTapDown: true, holdDuration: 1.0, threshold: threshold))
    }

    func testSingleTapHoldIsNeverContinuous() {
        XCTAssertFalse(GestureTiming.isContinuousRelease(
            wasDoubleTapDown: false, holdDuration: 0.10, threshold: threshold))
    }

    func testExactlyAtThresholdIsNotContinuous() {
        // At/over the threshold it's a hold (quick mode), not a release.
        XCTAssertFalse(GestureTiming.isContinuousRelease(
            wasDoubleTapDown: true, holdDuration: threshold, threshold: threshold))
    }
}
