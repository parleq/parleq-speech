// Sounds — small acoustic feedback for hotkey events.
//
// Two cues, both standard macOS system sounds:
//   - "Tink" on hotkey-down: a short, dry tick. Tells the user
//     "capture started" without them needing to look at the overlay.
//   - "Pop" on hotkey-up: a soft pop. Tells the user "capture
//     ended; processing now."
//
// Sounds are loaded once at startup and reused; NSSound caches the
// underlying audio file. Playback is fire-and-forget (no completion
// handler), and silently no-ops if the sound files are unavailable
// (which would be surprising on macOS — system sounds are
// guaranteed to be present).
//
// M5+ will add a config knob to disable these via
// ~/.parleq/config.toml `[ui]` section; for now they're always on.

import AppKit

@MainActor
public enum Sounds {
    private static let down = NSSound(named: NSSound.Name("Tink"))
    private static let up = NSSound(named: NSSound.Name("Pop"))
    /// Set false (via Config.acousticFeedback) to silence both cues.
    /// The whole module no-ops when this is off.
    public static var enabled: Bool = true

    /// Play the capture-start cue. Safe to call repeatedly — NSSound
    /// rewinds and restarts if a previous play is still finishing.
    public static func playCaptureStart() {
        guard enabled else { return }
        logSound("capture-start Tink")
        down?.stop()
        down?.play()
    }

    /// Play the capture-end cue.
    public static func playCaptureEnd() {
        guard enabled else { return }
        logSound("capture-end Pop")
        up?.stop()
        up?.play()
    }

    private static func logSound(_ msg: String) {
        if let data = "[parleq] sounds: \(msg)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

/// Debounced wrapper around Sounds for the press-and-hold lifecycle.
///
/// Without debouncing, a double-tap-and-hold gesture plays the
/// start cue twice (once for the brief first tap, once for the
/// real hold) and the end cue twice as well — sounds jangly. With
/// debouncing, the start cue waits a fixed delay; if the user
/// releases before it fires, neither start nor end plays. So:
///
///   - Double-tap-and-hold:    1 start (for the hold), 1 end (on release)
///   - Single short tap:       0 cues (suppressed as accidental)
///   - Normal hold-and-talk:   1 start (after 150 ms), 1 end (on release)
///
/// The 150 ms threshold matches AppState's overlay-show debounce
/// and the short-utterance guard, so all three "this was an
/// accidental tap" decisions agree.
@MainActor
public final class HotkeySoundDebouncer {
    public init() {}

    /// Delay before the capture-start cue plays. Kept in lockstep
    /// with the dictation overlay's show delay (Config.overlayShowDelayMs,
    /// #56) so the audio cue, the visual overlay, and the
    /// hold-hotkey+P gesture all engage at the same moment. Without
    /// this sync the sound fired on its own fixed clock while the
    /// overlay waited the configurable delay — jarring at longer
    /// delays. Safe to delay: audio recording starts immediately at
    /// hotkey-down, so the cue is confirmation, not the actual
    /// capture-start; delaying it can't clip the first word.
    /// Wired from main.swift at launch + on .parleqOverlayDelayChanged.
    private var startDelay: TimeInterval = 0.20

    /// Update the start-cue delay to match the current overlay-show
    /// delay (#56). Main-actor isolated; called from the same paths
    /// that update HotkeyListener.pHoldThreshold.
    public func setStartDelay(_ seconds: TimeInterval) {
        startDelay = max(0, seconds)
    }

    private var pendingStart: Timer?
    private var startPlayed = false

    /// Call on hotkey-down. Schedules the start cue after a delay.
    public func scheduleStart() {
        cancelPendingStart()
        startPlayed = false
        // Delay 0 → play immediately (the user opted into an instant
        // overlay, so the cue should be instant too). Timer with a 0
        // interval still defers to the next runloop tick; fire
        // synchronously instead so "instant" really is instant.
        guard startDelay > 0 else {
            Sounds.playCaptureStart()
            startPlayed = true
            return
        }
        pendingStart = Timer.scheduledTimer(
            withTimeInterval: startDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                Sounds.playCaptureStart()
                self?.startPlayed = true
                self?.pendingStart = nil
            }
        }
    }

    /// Call on hotkey-up. Plays the end cue iff the start cue was
    /// played AND the caller didn't ask for it suppressed; otherwise
    /// just cancels the pending start (the press was too brief to
    /// deserve any audio feedback).
    ///
    /// suppressEnd is set true for quick-mode (double-tap-and-hold)
    /// captures: the visible paste itself is the end-cue, and the
    /// Pop colliding with the BT-routing click on engine.stop()
    /// sounded like a doubled end sound (issue #6).
    public func endOrCancel(suppressEnd: Bool = false) {
        cancelPendingStart()
        if startPlayed && !suppressEnd {
            Sounds.playCaptureEnd()
        }
        startPlayed = false
    }

    private func cancelPendingStart() {
        pendingStart?.invalidate()
        pendingStart = nil
    }
}
