import XCTest
@testable import ParleqAppCore

/// Truth-table tests for the LatchedComposeState transition function.
/// Each case in the spec's state diagram should map to a test here so
/// future refactors of the state machine can't silently change a
/// transition. Illegal transitions are explicitly asserted to be
/// no-ops (state unchanged) so robustness against race-prone event
/// orderings is part of the contract.
final class LatchedComposeStateTests: XCTestCase {

    // MARK: - Happy-path transitions from the spec

    func test_idle_hotkeyDown_to_recording() {
        XCTAssertEqual(
            nextComposeState(.idle, event: .hotkeyDown),
            .recording
        )
    }

    func test_recording_release_without_space_to_idle() {
        // The dominant case — v1 release-submits behavior is the .idle
        // return. AppState fires the existing submit pipeline.
        XCTAssertEqual(
            nextComposeState(.recording, event: .hotkeyUp(spaceWasPressedDuringHold: false)),
            .idle
        )
    }

    func test_recording_release_with_space_to_pickerOpen() {
        XCTAssertEqual(
            nextComposeState(.recording, event: .hotkeyUp(spaceWasPressedDuringHold: true)),
            .pickerOpen
        )
    }

    func test_pickerOpen_pickerDismissed_to_latched() {
        XCTAssertEqual(
            nextComposeState(.pickerOpen, event: .pickerDismissed),
            .latched
        )
    }

    func test_pickerOpen_hotkeyDown_is_noop_in_state_machine() {
        // The "user impatient with picker, presses hotkey while it's
        // open" case is handled in AppState by FIRST dismissing the
        // picker (which transitions .pickerOpen → .latched via
        // .pickerDismissed) and THEN transitioning .latched →
        // .latchedRecording via .hotkeyDown. The state machine
        // itself returns the unchanged state because we want
        // dismissPicker() to be the single source of truth for
        // picker-close side effects.
        XCTAssertEqual(
            nextComposeState(.pickerOpen, event: .hotkeyDown),
            .pickerOpen
        )
    }

    func test_latched_hotkeyDown_to_latchedRecording() {
        // The dominant "resume dictation after attaching a ref" path.
        XCTAssertEqual(
            nextComposeState(.latched, event: .hotkeyDown),
            .latchedRecording
        )
    }

    func test_latchedRecording_release_without_space_to_idle() {
        // Submit the multi-segment composition. AppState fires the
        // submit pipeline including any attached refs.
        XCTAssertEqual(
            nextComposeState(.latchedRecording, event: .hotkeyUp(spaceWasPressedDuringHold: false)),
            .idle
        )
    }

    func test_latchedRecording_release_with_space_to_pickerOpen() {
        // Add another reference mid-composition.
        XCTAssertEqual(
            nextComposeState(.latchedRecording, event: .hotkeyUp(spaceWasPressedDuringHold: true)),
            .pickerOpen
        )
    }

    // MARK: - Cancel transitions (Esc from any non-idle state)

    func test_esc_from_recording_to_idle() {
        XCTAssertEqual(nextComposeState(.recording, event: .esc), .idle)
    }

    func test_esc_from_pickerOpen_to_idle() {
        XCTAssertEqual(nextComposeState(.pickerOpen, event: .esc), .idle)
    }

    func test_esc_from_latched_to_idle() {
        XCTAssertEqual(nextComposeState(.latched, event: .esc), .idle)
    }

    func test_esc_from_latchedRecording_to_idle() {
        XCTAssertEqual(nextComposeState(.latchedRecording, event: .esc), .idle)
    }

    func test_esc_from_idle_is_noop() {
        // No active composition; nothing to cancel.
        XCTAssertEqual(nextComposeState(.idle, event: .esc), .idle)
    }

    // MARK: - Submit reset (fired by AppState after ASR completion)

    func test_submitted_from_any_state_returns_idle() {
        // The full reset path — AppState fires .submitted once the
        // ASR + LLM pipeline finishes and the next gesture should
        // start fresh.
        for state in [ComposeState.idle, .recording, .pickerOpen, .latched, .latchedRecording] {
            XCTAssertEqual(
                nextComposeState(state, event: .submitted),
                .idle,
                "submitted from \(state) should reset to .idle"
            )
        }
    }

    // MARK: - Illegal / out-of-order transitions (must be no-ops)

    func test_hotkeyDown_from_recording_is_noop() {
        // Hotkey is already down — duplicate keyDown events shouldn't
        // re-enter the state.
        XCTAssertEqual(
            nextComposeState(.recording, event: .hotkeyDown),
            .recording
        )
    }

    func test_hotkeyDown_from_latchedRecording_is_noop() {
        XCTAssertEqual(
            nextComposeState(.latchedRecording, event: .hotkeyDown),
            .latchedRecording
        )
    }

    func test_pickerDismissed_from_recording_is_noop() {
        // No picker open from .recording; stale event.
        XCTAssertEqual(
            nextComposeState(.recording, event: .pickerDismissed),
            .recording
        )
    }

    func test_pickerDismissed_from_latched_is_noop() {
        // Picker already dismissed; stale event.
        XCTAssertEqual(
            nextComposeState(.latched, event: .pickerDismissed),
            .latched
        )
    }

    func test_hotkeyUp_from_idle_is_noop() {
        // No hold in progress.
        XCTAssertEqual(
            nextComposeState(.idle, event: .hotkeyUp(spaceWasPressedDuringHold: false)),
            .idle
        )
        XCTAssertEqual(
            nextComposeState(.idle, event: .hotkeyUp(spaceWasPressedDuringHold: true)),
            .idle
        )
    }

    func test_hotkeyUp_without_space_from_latched_is_noop() {
        // Hotkey wasn't held in latched state — release-without-space
        // has no meaning. Only the with-space variant is meaningful,
        // and that's the overlay-"+"-to-picker transition tested
        // separately below.
        XCTAssertEqual(
            nextComposeState(.latched, event: .hotkeyUp(spaceWasPressedDuringHold: false)),
            .latched
        )
    }

    func test_hotkeyUp_with_space_from_latched_opens_picker() {
        // presentPicker() synthesizes .hotkeyUp(space:true) as its
        // "picker opened" signal so the same event handles the
        // .recording / .latchedRecording / .latched origins.
        // Without this transition, opening the picker from .latched
        // (e.g. via the overlay "+" button) would leave composeState
        // as .latched and the next hotkey-down would resume audio
        // with the picker still visible.
        XCTAssertEqual(
            nextComposeState(.latched, event: .hotkeyUp(spaceWasPressedDuringHold: true)),
            .pickerOpen
        )
    }

    func test_hotkeyUp_from_pickerOpen_is_noop() {
        // Picker is open — the hotkey wasn't held when it opened
        // (audio paused at picker-open). Should be no-op until
        // picker dismisses and a new hold starts.
        XCTAssertEqual(
            nextComposeState(.pickerOpen, event: .hotkeyUp(spaceWasPressedDuringHold: false)),
            .pickerOpen
        )
    }

    // MARK: - End-to-end gesture sequences

    func test_simple_dictation_sequence_stays_idle_in_compose_state() {
        // Hold → speak → release without space → submit. Composes
        // state never enters the latched flow.
        var state = ComposeState.idle
        state = nextComposeState(state, event: .hotkeyDown)
        XCTAssertEqual(state, .recording)
        state = nextComposeState(state, event: .hotkeyUp(spaceWasPressedDuringHold: false))
        XCTAssertEqual(state, .idle)
    }

    func test_latched_compose_sequence_attaches_and_submits() {
        // Hold → speak → space → release → pick → hold → speak → release.
        // The canonical latched-compose workflow.
        var state = ComposeState.idle
        state = nextComposeState(state, event: .hotkeyDown)
        XCTAssertEqual(state, .recording)
        state = nextComposeState(state, event: .hotkeyUp(spaceWasPressedDuringHold: true))
        XCTAssertEqual(state, .pickerOpen)
        state = nextComposeState(state, event: .pickerDismissed)
        XCTAssertEqual(state, .latched)
        state = nextComposeState(state, event: .hotkeyDown)
        XCTAssertEqual(state, .latchedRecording)
        state = nextComposeState(state, event: .hotkeyUp(spaceWasPressedDuringHold: false))
        XCTAssertEqual(state, .idle)
    }

    func test_multi_ref_attach_then_submit() {
        // Hold → space → release → pick → hold → space → release →
        // pick again → hold → release → submit.
        var state = ComposeState.idle
        state = nextComposeState(state, event: .hotkeyDown)
        state = nextComposeState(state, event: .hotkeyUp(spaceWasPressedDuringHold: true))
        state = nextComposeState(state, event: .pickerDismissed)
        XCTAssertEqual(state, .latched, "After first picker dismiss")
        state = nextComposeState(state, event: .hotkeyDown)
        state = nextComposeState(state, event: .hotkeyUp(spaceWasPressedDuringHold: true))
        state = nextComposeState(state, event: .pickerDismissed)
        XCTAssertEqual(state, .latched, "After second picker dismiss")
        state = nextComposeState(state, event: .hotkeyDown)
        state = nextComposeState(state, event: .hotkeyUp(spaceWasPressedDuringHold: false))
        XCTAssertEqual(state, .idle, "After final submit")
    }

    func test_tap_to_send_after_attach() {
        // The "I attached a ref and don't want to speak more" case.
        // Hold → space → release → pick → hold + release (no speech).
        var state = ComposeState.idle
        state = nextComposeState(state, event: .hotkeyDown)
        state = nextComposeState(state, event: .hotkeyUp(spaceWasPressedDuringHold: true))
        state = nextComposeState(state, event: .pickerDismissed)
        XCTAssertEqual(state, .latched)
        // No speech in this hold; still a release-without-space.
        state = nextComposeState(state, event: .hotkeyDown)
        state = nextComposeState(state, event: .hotkeyUp(spaceWasPressedDuringHold: false))
        XCTAssertEqual(state, .idle, "Tap-to-send should submit")
    }

    func test_cancel_mid_composition() {
        // Hold → space → release → pick → escape entire composition.
        var state = ComposeState.idle
        state = nextComposeState(state, event: .hotkeyDown)
        state = nextComposeState(state, event: .hotkeyUp(spaceWasPressedDuringHold: true))
        state = nextComposeState(state, event: .pickerDismissed)
        XCTAssertEqual(state, .latched)
        state = nextComposeState(state, event: .esc)
        XCTAssertEqual(state, .idle, "Esc from latched should cancel all")
    }
}
