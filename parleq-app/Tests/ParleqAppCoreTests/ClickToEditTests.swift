import XCTest
@testable import ParleqAppCore

/// Click-to-edit: the content-area layout rule and the scroll math that keeps
/// the clicked line under the mouse.
@MainActor
final class ClickToEditTests: XCTestCase {
    // MARK: OverlayContentLayout

    func testScrollsWhenTallAndReviewing() {
        XCTAssertTrue(OverlayContentLayout.usesScrollContainer(
            measuredHeight: 2000, threshold: 1350, editing: false))
    }

    func testDirectWhenShortAndReviewing() {
        XCTAssertFalse(OverlayContentLayout.usesScrollContainer(
            measuredHeight: 1350, threshold: 1350, editing: false))
    }

    func testNeverScrollContainerWhileEditing() {
        // Crossing the branch mid-edit rebuilds the editor and drops focus.
        for height: CGFloat in [52, 1350, 1351, 5000] {
            XCTAssertFalse(OverlayContentLayout.usesScrollContainer(
                measuredHeight: height, threshold: 1350, editing: true), "\(height)")
        }
    }

    // MARK: clipOriginY

    func testFlippedClipScrollsDownWhenLineSitsBelowClick() {
        // Line top 100pt below where it should be (screen y is up) → content
        // moves up → flipped origin grows by 100.
        XCTAssertEqual(EditorCaretPlacement.clipOriginY(
            currentOriginY: 500, lineTopOnScreen: 300, wantedTopOnScreen: 400,
            clipIsFlipped: true), 600)
    }

    func testFlippedClipScrollsUpWhenLineSitsAboveClick() {
        XCTAssertEqual(EditorCaretPlacement.clipOriginY(
            currentOriginY: 500, lineTopOnScreen: 450, wantedTopOnScreen: 400,
            clipIsFlipped: true), 450)
    }

    func testUnflippedClipMovesTheOtherWay() {
        XCTAssertEqual(EditorCaretPlacement.clipOriginY(
            currentOriginY: 500, lineTopOnScreen: 300, wantedTopOnScreen: 400,
            clipIsFlipped: false), 400)
    }

    func testNoChangeWhenAlreadyAligned() {
        XCTAssertEqual(EditorCaretPlacement.clipOriginY(
            currentOriginY: 42, lineTopOnScreen: 400, wantedTopOnScreen: 400,
            clipIsFlipped: true), 42)
    }
}
