// LatchedComposeState — the state machine for Reference Windows v2's
// latched-compose flow. Factored out of AppState as a pure transition
// function so the gesture vocabulary is testable in isolation.
//
// The rule, expressed as code:
//
//     Releasing the hotkey submits the composition — unless Space was
//     pressed during that hold.
//
// Layered on top of AppState's existing Phase: when composeState is
// .idle, AppState behaves identically to v1 (release submits). The
// state transitions through .recording / .pickerOpen / .latched /
// .latchedRecording when the user presses Space during a hold, and
// resets to .idle on submit or Esc.
//
// This file contains NO side effects. Audio recorder transitions,
// picker open/close, overlay locking, ASR invocation — all of that
// happens at the AppState wiring level. The transition function
// returns the next state; the caller is responsible for executing
// whatever side effects the transition implies (e.g.
// .latched → .latchedRecording means "call recorder.resume()"
// somewhere in AppState).

import Foundation

/// State of the latched-compose gesture flow. Independent of
/// AppState.Phase — phase tracks the dictation lifecycle (capturing,
/// cleaning, awaiting accept), composeState tracks whether the user
/// is in the latched-compose flow and where in it.
public enum ComposeState: Equatable, Sendable {
    /// Not in latched flow. The next hotkey release submits via the
    /// existing UX (the v1 behavior preserved for users who never
    /// press Space during a hold).
    case idle

    /// Hotkey held, audio capturing, no Space pressed yet THIS hold.
    /// Release without Space → returns to .idle (submit fires via
    /// AppState's existing path). Release with Space → .pickerOpen.
    /// Esc → .idle (cancel).
    case recording

    /// Picker is showing, audio paused, overlay locked open. Reached
    /// from .recording or .latchedRecording when Space was pressed
    /// during the hold. Picker dismissal → .latched (regardless of
    /// whether a reference was selected — selection state lives in
    /// AppState, not here). The picker has its own Esc handler that
    /// closes the picker without selecting; that fires
    /// `.pickerDismissed` (NOT `.esc`), so picker-Esc returns to
    /// .latched rather than canceling the whole composition. Only
    /// the overlay-level Esc (fired from .latched / .latchedRecording
    /// when no picker is open) cancels — see `.esc` below.
    case pickerOpen

    /// Overlay locked open, picker closed, audio paused. The "I just
    /// pivoted into composition mode and I'm between speak/attach
    /// actions" state. The next hotkey-down transitions to
    /// .latchedRecording to resume audio capture; the next
    /// hotkey-down with Esc cancels the whole composition.
    case latched

    /// Hotkey held (second-or-later hold this session, after the
    /// initial latch was entered), audio capturing into an appended
    /// segment. Same release semantics as .recording, but submit
    /// fires the multi-segment composition flow rather than the
    /// single-utterance flow.
    case latchedRecording
}

/// Events that drive ComposeState transitions. Emitted by HotkeyListener
/// (hotkeyDown / hotkeyUp), the picker (pickerDismissed), the global
/// Esc handler (esc), and AppState's ASR completion (submitted).
public enum ComposeEvent: Equatable {
    /// Dictation hotkey pressed (any state).
    case hotkeyDown

    /// Dictation hotkey released. `spaceWasPressedDuringHold` carries
    /// the flag HotkeyListener tracks per-hold. False = submit-on-
    /// release (the dominant case); true = latch and open picker.
    case hotkeyUp(spaceWasPressedDuringHold: Bool)

    /// Picker has closed — for ANY reason. This covers user
    /// selecting a reference, user clicking outside the picker,
    /// and user pressing Esc while the picker has focus (the
    /// picker's own UI intercepts and dismisses itself before our
    /// .esc handler runs). All three close-reasons keep the
    /// composition in flight (state → .latched), matching the
    /// principle "Esc in a picker dismisses the picker, not the
    /// composing task" (Mac standard convention — like Esc in a
    /// file-open dialog only closes the dialog).
    case pickerDismissed

    /// User pressed Esc at the OVERLAY level — cancel the whole
    /// composition (drops segments + chips). Only reachable when
    /// no picker is open (.recording, .latched, or
    /// .latchedRecording); the picker's own Esc handler swallows
    /// the keystroke before this event would fire.
    case esc

    /// AppState's ASR + LLM pipeline finished and the result is on
    /// screen (or pasted, in quick mode). Resets composeState to
    /// .idle so the next gesture starts a fresh session.
    case submitted
}

/// Pure transition function. Given the current ComposeState and a
/// ComposeEvent, returns the next ComposeState. Caller (AppState) is
/// responsible for executing any side effects implied by the
/// transition (start / resume / pause audio; open / close picker;
/// fire submit pipeline; etc.).
///
/// Illegal or out-of-order transitions return the current state
/// unchanged rather than asserting — preserves robustness under
/// race conditions (e.g. a stale pickerDismissed event arriving
/// after Esc has already reset state). Callers should log unexpected
/// (current, event) pairs if they want to surface bugs.
public func nextComposeState(_ current: ComposeState, event: ComposeEvent) -> ComposeState {
    // .submitted always resets to .idle regardless of current state.
    // AppState fires this after ASR completion to clear the latched
    // session.
    if case .submitted = event { return .idle }

    // Esc cancels from any non-idle state. From .idle it's a no-op.
    if case .esc = event { return .idle }

    switch (current, event) {
    // From .idle — only hotkeyDown does anything meaningful.
    case (.idle, .hotkeyDown):
        return .recording

    // From .recording — release routes by space-flag; the existing
    // v1 release-without-space path is the .idle return.
    case (.recording, .hotkeyUp(spaceWasPressedDuringHold: false)):
        return .idle
    case (.recording, .hotkeyUp(spaceWasPressedDuringHold: true)):
        return .pickerOpen

    // From .pickerOpen — picker dismiss returns to latched.
    // hotkeyDown while picker is open is handled in AppState by
    // first dismissing the picker (which fires .pickerDismissed
    // and transitions to .latched), then transitioning via
    // .hotkeyDown (which transitions to .latchedRecording). The
    // direct .pickerOpen + .hotkeyDown → .latchedRecording case
    // was previously defined here as a single-step shortcut but
    // it's never used (AppState always takes the two-step path
    // to keep dismissPicker as the single source of truth for
    // picker-close side effects).
    case (.pickerOpen, .pickerDismissed):
        return .latched

    // From .latched — hotkeyDown resumes audio capture as a new
    // segment.
    case (.latched, .hotkeyDown):
        return .latchedRecording

    // From .latched — overlay's "+" button (or any other route that
    // opens the picker without the user holding the hotkey) walks
    // through presentPicker() in AppState. presentPicker synthesizes
    // .hotkeyUp(space:true) as the "picker opened" signal. Without
    // this case the .latched state survives the picker-open and the
    // next hotkey press takes the .latched → .latchedRecording resume
    // branch with the picker still visible, leading to audio resuming
    // alongside a stale picker. Routing to .pickerOpen here keeps
    // dismissPicker() as the only correct exit back to .latched.
    case (.latched, .hotkeyUp(spaceWasPressedDuringHold: true)):
        return .pickerOpen

    // From .latchedRecording — same release semantics as .recording,
    // but the "submit" path includes all accumulated segments + refs.
    case (.latchedRecording, .hotkeyUp(spaceWasPressedDuringHold: false)):
        return .idle
    case (.latchedRecording, .hotkeyUp(spaceWasPressedDuringHold: true)):
        return .pickerOpen

    // Anything else: state unchanged. This includes events that
    // don't apply to the current state (e.g. pickerDismissed when
    // we're already .latched — could happen if events overlap).
    default:
        return current
    }
}
