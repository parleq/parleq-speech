// HotkeyGestures — the minimal configurable gesture→action layer (#84). Today
// the double-tap entry gestures are hardcoded (double-tap-and-hold = quick mode);
// this lets the user remap them, and gives #83's continuous-recording gesture a
// home. Scope is deliberately small: only the two double-tap entry gestures are
// configurable. The single hold (always dictate), the during-hold combos
// (hold+P/C/Space), and the overlay review keys stay fixed. Full free-form
// remapping is deferred.
import Foundation

/// Pure timing classifier for the double-tap-and-release gesture (#83). Kept
/// here (not on HotkeyListener) so it's free of MainActor isolation and unit-
/// testable. The CGEventTap measures `holdDuration`; this decides intent.
public enum GestureTiming {
    /// Default release window: a double-tap whose second press is released
    /// within this is a "tap" → continuous recording; held longer → quick mode.
    public static let continuousReleaseWindow: TimeInterval = 0.35

    /// True when a double-tap's second press was released quickly enough to mean
    /// "double-tap-and-release" (continuous) rather than "double-tap-and-hold".
    public static func isContinuousRelease(
        wasDoubleTapDown: Bool, holdDuration: TimeInterval, threshold: TimeInterval
    ) -> Bool {
        wasDoubleTapDown && holdDuration < threshold
    }
}

/// What a configurable gesture does. Raw values are the on-disk config tokens.
public enum GestureAction: String, Sendable, CaseIterable {
    case dictate              // same as a plain hold: push-to-talk
    case quickMode = "quick"  // double-tap-and-hold's historical behavior
    case continuousRecording = "continuous"  // latched record until stopped (#83)
    case disabled             // gesture does nothing
}

/// The configurable entry gestures. Raw values are the on-disk config keys.
public enum HotkeyGesture: String, Sendable, CaseIterable {
    case doubleTapHold = "double-tap-hold"
    case doubleTapRelease = "double-tap-release"
}

/// Immutable map from each configurable gesture to its action, resolved from
/// config with per-gesture defaults that preserve today's behavior.
public struct GestureMap: Sendable, Equatable {
    private let actions: [HotkeyGesture: GestureAction]

    public init(actions: [HotkeyGesture: GestureAction]) {
        self.actions = actions
    }

    /// Default mapping: double-tap-and-hold keeps its historical quick-mode
    /// meaning; double-tap-and-release starts continuous recording (#83).
    public static let defaults = GestureMap(actions: [
        .doubleTapHold: .quickMode,
        .doubleTapRelease: .continuousRecording,
    ])

    /// The action for a gesture, falling back to that gesture's default when
    /// unset (so an absent or partial config never disables a gesture).
    public func action(for gesture: HotkeyGesture) -> GestureAction {
        actions[gesture] ?? GestureMap.defaults.actions[gesture] ?? .disabled
    }

    /// Build from the raw `[gestureKey: actionToken]` config dict. Unknown
    /// gesture keys are ignored; unknown action tokens fall back to the
    /// gesture's default (a typo must not silently disable a gesture).
    public static func parse(_ raw: [String: String]) -> GestureMap {
        var resolved = defaults.actions
        for (key, token) in raw {
            guard let gesture = HotkeyGesture(rawValue: key) else { continue }
            if let action = GestureAction(rawValue: token) {
                resolved[gesture] = action
            }
            // else: keep the default already in `resolved`.
        }
        return GestureMap(actions: resolved)
    }

    /// The config dict for persistence (every gesture, explicit).
    public func serialized() -> [String: String] {
        var out: [String: String] = [:]
        for gesture in HotkeyGesture.allCases {
            out[gesture.rawValue] = action(for: gesture).rawValue
        }
        return out
    }
}
