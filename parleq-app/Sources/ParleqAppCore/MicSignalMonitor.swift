// MicSignalMonitor — B2: a live "are we hearing you?" watchdog over the raw mic
// peak during capture. The overlay's wave bars already give an always-on level
// readout; this adds the escalation the maintainer asked for — when the input
// stays flat-zero (a DEAD mic delivering no samples) for ~1.5 s while holding,
// flip a "⚠ not hearing your mic" warning so the user finds out DURING the
// dictation instead of losing it silently (the "as if I never dictated" case).
//
// Keyed off the raw peak amplitude, NOT the overlay's normalized 0…1 level —
// the normalized level clamps everything below -50 dBFS to 0, so a quiet room
// and a dead mic both read 0. The raw peak distinguishes them: a live mic's
// noise floor sits well above `deadPeak` (the same threshold A3's CaptureHealth
// uses), while a dead mic delivers ~0. That keeps a brief pre-speech pause from
// false-triggering the warning.
//
// Pure + testable; the wiring (feed peaks in, reflect `notHearing` to the
// overlay) lives in AppState / AudioRecorder.
import Foundation

public struct MicSignalMonitor {
    /// Peak amplitude at/below this is effectively no signal — a dead input,
    /// not a quiet room. Matches CaptureHealth.deadInputPeakRMS.
    public static let deadPeak: Float = 0.0001
    /// Flat-zero must persist this long before we warn, so a normal pause
    /// before the user starts speaking doesn't flash the warning.
    public static let warnAfterSeconds: TimeInterval = 1.5

    private var flatZeroSeconds: TimeInterval = 0
    /// True once flat-zero input has persisted past the threshold. Cleared the
    /// instant any real signal arrives.
    public private(set) var notHearing: Bool = false

    public init() {}

    /// Feed one capture chunk's peak amplitude (0…1) and its duration.
    /// Returns the current `notHearing` state for convenience.
    @discardableResult
    public mutating func update(peak: Float, dt: TimeInterval) -> Bool {
        if peak <= Self.deadPeak {
            flatZeroSeconds += dt
            if flatZeroSeconds >= Self.warnAfterSeconds { notHearing = true }
        } else {
            flatZeroSeconds = 0
            notHearing = false
        }
        return notHearing
    }

    /// Reset between captures so a prior dictation's flat-zero tail doesn't
    /// carry into the next hold.
    public mutating func reset() {
        flatZeroSeconds = 0
        notHearing = false
    }
}
