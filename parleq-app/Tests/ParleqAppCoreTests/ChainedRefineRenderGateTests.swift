import XCTest
@testable import ParleqAppCore

/// Unit tests for the streaming-overlay render gate used by the
/// chained-refine fix. The predicate decides whether an in-flight
/// cleanup/refine stream may paint its chunks onto the overlay.
///
/// CRITICAL phase fact this gate depends on: `finalizeCapture` sets
/// `phase = .cleaning` for BOTH the fresh-dictation cleanup AND a voice
/// refine before it spawns the streaming task. The `.refining` phase
/// only covers the audio hold; once the hotkey is released the LLM pass
/// — cleanup or refine alike — streams under `.cleaning`. So a normal
/// refine's chunks render (phase .cleaning, no chain); only the
/// chained-cleanup half (chain flag set) is suppressed. The single
/// streaming call site that passes this gate is finalizeCapture's;
/// switchModelAndRecleanup / runPreset use the default always-true gate.
///
/// This is the deterministic decision logic; the wiring that calls it
/// per chunk is exercised by the morning live test.
final class ChainedRefineRenderGateTests: XCTestCase {
    // NOTE: the three `*_renders_*` cases below intentionally call the
    // identical predicate inputs (.cleaning, false). They document three
    // DISTINCT real-world streaming scenarios — a fresh cleanup, a normal
    // voice refine, and a chained refine's own post-flag-clear stream —
    // that all legitimately collapse to the same gate inputs because
    // every LLM pass streams under .cleaning with the chain flag false.
    // Kept separate (rather than merged) so a future change to the
    // predicate's signature or to any one scenario's actual inputs surfaces
    // as a named, scenario-specific failure rather than a single opaque one.
    func test_renders_during_normal_cleaning() {
        XCTAssertTrue(
            chainedRefineShouldRender(phase: .cleaning, refineChainedDuringCleanup: false)
        )
    }

    // Regression guard: a NORMAL voice refine streams under `.cleaning`
    // with the chain flag false (it was never chained), so its chunks
    // must render — preserving the progressive streaming preview. (A
    // prior review mis-assumed refines stream under `.refining`, which
    // would have wrongly suppressed them; they do not.)
    func test_renders_during_normal_voice_refine_stream() {
        XCTAssertTrue(
            chainedRefineShouldRender(phase: .cleaning, refineChainedDuringCleanup: false)
        )
    }

    func test_suppressed_when_refine_chained_during_cleaning() {
        XCTAssertFalse(
            chainedRefineShouldRender(phase: .cleaning, refineChainedDuringCleanup: true)
        )
    }

    // The chained refine clears the flag before IT streams (under
    // .cleaning), so its own chunks render normally.
    func test_chained_refine_own_stream_renders_after_flag_cleared() {
        XCTAssertTrue(
            chainedRefineShouldRender(phase: .cleaning, refineChainedDuringCleanup: false)
        )
    }

    func test_suppressed_outside_cleaning_phase() {
        // No streaming pass actually runs under these phases (every LLM
        // pass streams under .cleaning), but the gate is conservatively
        // false for them anyway.
        for phase in [AppState.Phase.idle, .capturing, .refining, .awaitingAccept, .pasting, .staging] {
            XCTAssertFalse(
                chainedRefineShouldRender(phase: phase, refineChainedDuringCleanup: false),
                "phase \(phase) should not render a cleanup stream"
            )
        }
    }
}
