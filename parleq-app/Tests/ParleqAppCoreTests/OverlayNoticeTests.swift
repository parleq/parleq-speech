import XCTest
@testable import ParleqAppCore

/// RoboRev follow-up (0.25.1): the B1 dead-input notice (`transientNotice`) has
/// a 2.5s auto-dismiss timer. `OverlayModel.update()` — called by every show() —
/// must clear `transientNotice`, otherwise a fresh capture started within that
/// window renders the dead-mic notice over the live capture AND the pending
/// timer fires mid-capture and hides the active overlay (a dictation-loss
/// vector). Flagged across the B1 / B3 / B2 reviews.
@MainActor
final class OverlayNoticeTests: XCTestCase {

    func testUpdateClearsTransientNotice() {
        let model = OverlayModel()
        model.transientNotice = "Didn't catch any audio — check your microphone."
        // Starting a fresh capture routes through update() — the notice must go.
        model.update(state: .capturing, text: "")
        XCTAssertNil(model.transientNotice)
    }

    func testUpdateClearsNoticeIntoAnyRealPhase() {
        for state in [OverlayState.capturing, .cleaning, .awaitingAccept, .refining, .staging] {
            let model = OverlayModel()
            model.transientNotice = "stale notice"
            model.update(state: state, text: "x")
            XCTAssertNil(model.transientNotice, "notice should clear into \(state)")
        }
    }

    func testUpdateIntoInitializingPreservesNotice() {
        // `.initializing` is the notice's OWN display vehicle: showTransientNotice
        // sets the notice and then calls show(.initializing) → update(). If
        // update() cleared unconditionally it would null the notice the instant
        // it's shown — the regression that broke B1. The notice must survive an
        // update into .initializing.
        let model = OverlayModel()
        model.transientNotice = "Didn't catch any audio — check your microphone."
        model.update(state: .initializing, text: "")
        XCTAssertEqual(model.transientNotice, "Didn't catch any audio — check your microphone.")
    }
}
