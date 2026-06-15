// LaunchPermissions — pure launch-time decisions for #82. Parleq used to fire
// the *prompting* Accessibility dialog at launch (inside HotkeyListener.start)
// and exit(1) on denial, before the wizard could explain why it's needed. Now
// launch uses a non-prompting check, never exits, and defers the explained
// prompt to the wizard; the hotkey listener is armed once access is granted.
// These helpers encode the branching so it's testable without the CGEventTap /
// PermissionsModel machinery wired in main.swift.
import ApplicationServices
import Foundation

public enum LaunchPermissions {
    /// Whether to show the setup wizard at launch. Fresh installs always see it;
    /// #82 also (re)shows it when Accessibility is missing — even for a returning
    /// user (wizardCompleted == true) — so a revoked permission gets the explained
    /// re-grant step instead of a silently dead hotkey.
    public static func shouldShowWizardAtLaunch(
        wizardCompleted: Bool, accessibilityGranted: Bool
    ) -> Bool {
        !wizardCompleted || !accessibilityGranted
    }

    /// What to do about arming the global hotkey listener.
    public enum ArmingDecision: Equatable, Sendable {
        case arm                  // accessibility granted, not yet armed → install the tap
        case waitForAccessibility // missing → do NOT exit; arm later when granted
        case alreadyArmed         // tap already installed → ignore (no second tap)
    }

    public static func armingDecision(armed: Bool, accessibilityGranted: Bool) -> ArmingDecision {
        if armed { return .alreadyArmed }
        return accessibilityGranted ? .arm : .waitForAccessibility
    }

    /// Non-prompting check of whether Accessibility is currently granted. Public
    /// bridge so the app target (main.swift) can drive the arming/wizard
    /// decisions without exposing the whole internal `Permissions` API. Uses the
    /// thread-safe non-prompting `AXIsProcessTrusted()` directly (same call the
    /// internal `Permissions.accessibility` wraps) to stay free of MainActor
    /// isolation, since launch wiring calls it from mixed contexts.
    public static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }
}
