// EagerAccept — C1: resolve what an Enter pressed during `.cleaning` should do.
//
// The old "kill-it" semantics pasted whatever was visible and cancelled the LLM
// stream. A hasty double-Enter before the cleaned text finished streaming would
// paste a fragment (or beep on empty) and discard the rest — Jeff's reported
// lost-dictation case. This resolver defers the accept whenever the result
// isn't final yet: the caller arms a pending-accept and auto-accepts the FULL
// cleaned text when the stream completes. The single instant-accept case is the
// raw/prior transcript shown provisionally in full — a deliberate, complete
// "take the raw as-is" choice, not a loss.
//
// Pure + testable; the wiring (arm the flag, fire on cleanup completion) lives
// in AppState.accept() / applyResult().
import Foundation

public enum CleaningAcceptDecision: Equatable, Sendable {
    /// Paste the visible text now and cancel the in-flight stream — only when
    /// the full raw/prior transcript is on screen (provisional, complete).
    case acceptVisibleNow
    /// Don't paste a partial/empty fragment. Arm a pending-accept and auto-
    /// accept the full cleaned result the instant streaming completes.
    case deferUntilComplete
}

public enum EagerAccept {
    /// - Parameters:
    ///   - provisionalRawShown: the overlay is still showing the raw/prior
    ///     transcript provisionally (no cleanup chunk has replaced it yet).
    ///   - visibleIsEmpty: the visible text is empty (ASR not back / nothing
    ///     streamed yet).
    public static func resolve(
        provisionalRawShown: Bool,
        visibleIsEmpty: Bool
    ) -> CleaningAcceptDecision {
        // Full raw/prior on screen → accepting it is a complete choice.
        if provisionalRawShown && !visibleIsEmpty { return .acceptVisibleNow }
        // A partial cleanup stream, or nothing shown yet → wait for the result.
        return .deferUntilComplete
    }
}
