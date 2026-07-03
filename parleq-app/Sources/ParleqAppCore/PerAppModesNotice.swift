import AppKit

/// One-time heads-up shown to EXISTING users on the upgrade that introduced
/// per-app cleanup modes (the per-target feature). Terminals, code editors, and
/// spreadsheets now default to Instant (on-device, literal), so an upgrading
/// user's dictation into those apps changes behavior — this explains it rather
/// than letting it flip silently. New installs onboard with the feature already
/// present and never see this (the launch logic in main.swift marks the flag
/// seen for them without showing anything).
///
/// The "seen" flag is UI-acknowledgment state, not a setting, so it lives in
/// UserDefaults (`perAppModesNoticeSeenKey`) rather than the Config schema.
@MainActor
public enum PerAppModesNotice {
    /// UserDefaults key for the one-time "seen" flag.
    public static let seenKey = "parleq.perAppModesNoticeSeen"

    /// Present the one-time notice modally. "Review App Behavior…" opens the
    /// App-behavior editor (the Presets pane); "Got It" just dismisses.
    public static func show() {
        // The app is LSUIElement, so it may be inactive at launch — activate so
        // the alert is visible and frontmost.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Parleq now adapts cleanup to each app"
        alert.informativeText = """
            Terminals, code editors, and spreadsheets now use Instant cleanup — \
            fast, on-device, and literal (no rewriting). Everything else keeps \
            your configured cleanup.

            You can review or change any app's mode under Presets → App behavior.
            """
        alert.addButton(withTitle: "Review App Behavior…")
        alert.addButton(withTitle: "Got It")
        if alert.runModal() == .alertFirstButtonReturn {
            ParleqAppWindowController.shared.show(settingsPane: .presets)
        }
    }
}
