import XCTest
@testable import ParleqAppCore

/// Regression: a runaway panel-resize feedback loop. The overlay sizes its
/// NSPanel to the SwiftUI-measured body height; a bistable layout (observed
/// live after an in-place-edit `TextEditor` teardown) makes that measurement
/// flip-flop between two values forever — set the panel to A and it measures B,
/// set it to B and it measures A. The exact-equality no-op in
/// `resizePanelToHeight` never catches a *two-value* cycle, so the panel
/// ping-pongs and pegs the CPU. A real session logged 92k+ resize lines
/// (184 ↔ 201) and ~900 MB RSS after an accepted in-place edit until the user
/// force-killed it.
///
/// `oscillationSettleHeight` is the pure loop-breaker: it fires only on a
/// SUSTAINED two-value cycle (the last four applied heights already alternate
/// A,B,A,B and the incoming measurement continues it), returning the LARGER of
/// the pair so content never clips. A lone grow-then-shrink reversal is left
/// alone (legitimate during editing).
final class OverlayResizeOscillationTests: XCTestCase {

    func testNoHistoryAppliesNormally() {
        XCTAssertNil(OverlayWindow.oscillationSettleHeight(incoming: 201, recentApplied: []))
        XCTAssertNil(OverlayWindow.oscillationSettleHeight(incoming: 201, recentApplied: [201]))
    }

    func testMonotonicGrowthIsNotOscillation() {
        // Streaming growth 150 → 184 → 201 → 217 must never be mistaken for a flap.
        XCTAssertNil(OverlayWindow.oscillationSettleHeight(incoming: 217, recentApplied: [150, 184, 201]))
        XCTAssertNil(OverlayWindow.oscillationSettleHeight(incoming: 233, recentApplied: [184, 201, 217, 225]))
    }

    func testDistinctNewValueIsNotOscillation() {
        // A genuine third value, not a continuation of an A,B,A,B cycle.
        XCTAssertNil(OverlayWindow.oscillationSettleHeight(incoming: 250, recentApplied: [184, 201, 184, 201]))
    }

    func testSingleReversalIsLeftAlone() {
        // Grow then shrink back to the same height once (e.g. type a wrapping
        // line in the editor, then delete it). Only ONE reversal — not a
        // sustained cycle — so the breaker must not engage and strand the
        // panel one line too tall.
        XCTAssertNil(OverlayWindow.oscillationSettleHeight(incoming: 201, recentApplied: [201, 184]))
        XCTAssertNil(OverlayWindow.oscillationSettleHeight(incoming: 201, recentApplied: [195, 201, 184]))
    }

    func testSustainedCycleDetectedAndSettlesAtLarger() {
        // The live 184↔201 flap: four alternating applied heights, incoming
        // continues the cycle. Settle at the larger (201) so nothing clips.
        XCTAssertEqual(
            OverlayWindow.oscillationSettleHeight(incoming: 201, recentApplied: [201, 184, 201, 184]), 201)
        // Phase-shifted: alternating the other way, incoming back to 184 →
        // still settle at the larger of the pair (201).
        XCTAssertEqual(
            OverlayWindow.oscillationSettleHeight(incoming: 184, recentApplied: [184, 201, 184, 201]), 201)
    }

    func testConvergesToNoOpAtTheCeiling() {
        // Once settled at the larger value, the breaker keeps resolving to it,
        // so resizePanelToHeight's exact-equality no-op kills the loop: with
        // the panel already at 201, the next reversal resolves to 201 == current.
        let settle = OverlayWindow.oscillationSettleHeight(incoming: 184, recentApplied: [184, 201, 184, 201])
        XCTAssertEqual(settle, 201)
    }

    func testSubPixelNoiseIsNotACycle() {
        // A <0.5pt wobble is the existing no-op's job; the two "values" aren't
        // distinct, so this isn't a real cycle.
        XCTAssertNil(
            OverlayWindow.oscillationSettleHeight(incoming: 201.2, recentApplied: [201.0, 201.1, 201.0, 201.1]))
    }
}
