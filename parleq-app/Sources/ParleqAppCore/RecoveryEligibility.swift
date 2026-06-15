// RecoveryEligibility — B3: decide whether "recover last dictation" (hold+R or
// the menu-bar item) can run. Recovery re-runs ASR + cleanup on the retained
// audio of the most recent FRESH capture. It's only possible when such a buffer
// is in hand; a dead-input capture (the all-zero "as if I never dictated" case)
// is never retained, so this pairs with B1 rather than replacing it.
//
// Pure + testable; the buffer lifecycle + re-run wiring live in AppState.
import Foundation

public enum RecoveryEligibility {
    /// - Parameter hasRetainedAudio: a fresh-capture audio buffer is retained
    ///   in memory (AppState.lastDictationAudio != nil).
    public static func canRecover(hasRetainedAudio: Bool) -> Bool {
        return hasRetainedAudio
    }
}
