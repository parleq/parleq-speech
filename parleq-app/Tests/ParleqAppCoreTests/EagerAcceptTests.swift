import XCTest
@testable import ParleqAppCore

/// C1 (lost-dictation safety net): accepting (Enter) during `.cleaning` should
/// no longer paste a half-streamed fragment + cancel the LLM. When the cleaned
/// result isn't final yet, the accept DEFERS — it arms a pending-accept and the
/// full cleaned text is auto-accepted the instant the stream completes (Jeff's
/// hasty-Enter fix). The one case that stays an instant accept: the raw/prior
/// transcript is fully shown provisionally (the user is deliberately taking the
/// raw as-is), which is already a complete, non-lossy choice.
final class EagerAcceptTests: XCTestCase {

    func testProvisionalRawFullyShownAcceptsNow() {
        // Raw-first overlay: ASR returned, cleanup hasn't streamed a chunk yet.
        // The full raw is on screen — accepting it is a legitimate "skip
        // cleanup, take raw" choice, not a loss. Keep today's instant accept.
        XCTAssertEqual(
            EagerAccept.resolve(provisionalRawShown: true, visibleIsEmpty: false),
            .acceptVisibleNow)
    }

    func testPartialStreamDefers() {
        // The lossy case: a cleanup chunk has replaced the provisional, so the
        // overlay shows a partial fragment. Accepting now would paste the
        // fragment + discard the rest. Defer and auto-accept the full result.
        XCTAssertEqual(
            EagerAccept.resolve(provisionalRawShown: false, visibleIsEmpty: false),
            .deferUntilComplete)
    }

    func testNothingShownYetDefers() {
        // Enter pressed right after release — ASR not back yet, overlay empty.
        // Today this beeps and drops the keypress; instead defer so the full
        // cleaned result is auto-accepted when it lands.
        XCTAssertEqual(
            EagerAccept.resolve(provisionalRawShown: false, visibleIsEmpty: true),
            .deferUntilComplete)
    }

    func testProvisionalButEmptyDefers() {
        // Defensive: provisional flag set but nothing meaningful on screen —
        // there's nothing to accept now, so wait for the result.
        XCTAssertEqual(
            EagerAccept.resolve(provisionalRawShown: true, visibleIsEmpty: true),
            .deferUntilComplete)
    }
}
