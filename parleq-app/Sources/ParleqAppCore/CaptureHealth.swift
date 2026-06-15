// CaptureHealth — A3: classify a finished capture so finalizeCapture can tell a
// DEAD microphone (engine ran but delivered ~zero samples — a capture failure)
// apart from genuine quiet or too-short input. Pure + testable; the thresholds
// match the inline guards finalizeCapture used to apply, plus the new
// dead-input distinction that lets B1 surface "didn't catch any audio" instead
// of silently hiding the overlay (the "as if I never dictated" loss).
import Foundation

public enum CaptureHealth: Equatable, Sendable {
    case ok            // has voiced speech (or unanalyzable) → run the pipeline
    case tooShort      // below the minimum hold → accidental tap
    case deadInput     // long enough but ~zero samples → the mic delivered silence (FAILURE)
    case quietSilence  // long enough, live mic (nonzero floor), but no voiced speech
}

extension CaptureHealth {
    /// Minimum hold to be considered a deliberate utterance.
    public static let minUtteranceSeconds: TimeInterval = 0.2
    /// Below this much voiced audio, the user almost certainly didn't speak.
    public static let minVoicedSeconds: TimeInterval = 0.05
    /// Peak RMS at/below this is effectively all-zero — a dead input, not a
    /// quiet room (a live mic's noise floor is well above this).
    public static let deadInputPeakRMS: Float = 0.0001

    public static func classify(
        durationSeconds: TimeInterval,
        peakRMS: Float,
        voicedSeconds: TimeInterval,
        isAnalyzable: Bool
    ) -> CaptureHealth {
        if durationSeconds < minUtteranceSeconds { return .tooShort }
        // Can't analyze (defensive: malformed buffer) → don't suppress; ASR decides.
        guard isAnalyzable else { return .ok }
        if voicedSeconds < minVoicedSeconds {
            return peakRMS <= deadInputPeakRMS ? .deadInput : .quietSilence
        }
        return .ok
    }
}
