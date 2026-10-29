import XCTest
@testable import ParleqAppCore

/// #132: the footer Edit button is enabled exactly when AppState.enterEditMode
/// would act (awaitingAccept and not already editing).
@MainActor
final class OverlayCanEnterEditTests: XCTestCase {
    func testTrueWhenAwaitingAcceptAndNotEditing() {
        let model = OverlayModel()
        model.update(state: .awaitingAccept, text: "hi")
        model.editing = false
        XCTAssertTrue(model.canEnterEdit)
    }

    func testFalseWhileEditing() {
        let model = OverlayModel()
        model.update(state: .awaitingAccept, text: "hi")
        model.editing = true
        XCTAssertFalse(model.canEnterEdit)
    }

    func testFalseOutsideAwaitingAccept() {
        for state in [OverlayState.capturing, .cleaning] {
            let model = OverlayModel()
            model.update(state: state, text: "hi")
            model.editing = false
            XCTAssertFalse(model.canEnterEdit, "\(state)")
        }
    }
}
