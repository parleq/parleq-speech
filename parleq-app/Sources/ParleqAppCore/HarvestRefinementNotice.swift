import AppKit

#if Concord
/// One-time heads-up shown to EXISTING voice-enrollment users on the upgrade that
/// introduced correction-time voiceprint refinement (negative harvesting). Those
/// users enrolled under a prior build that derived embeddings only from enrollment
/// carrier clips; after this upgrade Parleq also refines their existing voiceprints
/// from a corrected word's dictation audio (a new source), so we tell them rather
/// than letting it begin silently, and point at the off-switch.
///
/// New enrollees never see this — they get the disclosure on the enrollment consent
/// card instead. Fresh installs and users with no voiceprints are marked seen
/// silently (nothing to disclose yet).
///
/// The "seen" flag is UI-acknowledgment state, not a setting, so it lives in
/// UserDefaults (`seenKey`) rather than the Config schema — same as `PerAppModesNotice`.
@MainActor
public enum HarvestRefinementNotice {
    /// UserDefaults key for the one-time "seen" flag.
    public static let seenKey = "parleq.harvestRefinementNoticeSeen"

    /// What to do about the notice on this launch. `wait` ⇒ leave the seen flag
    /// UNSET and re-evaluate next launch (so a deferred notice isn't lost).
    public enum Decision: Equatable { case show, markSeenSilently, wait }

    /// Pure gating decision (unit-testable without AppKit). Call only when the
    /// seen flag is not already set.
    /// - Fresh install (wizard not completed): silent — onboards with the feature
    ///   and the enrollment-card disclosure.
    /// - Existing user, but the wizard or the per-app-modes notice is showing this
    ///   launch: `wait` — don't stack modals; retry next launch.
    /// - Existing user, clear to show: `show` iff they already have enrolled
    ///   voiceprints (the affected cohort); otherwise `markSeenSilently` (they'll
    ///   see the enrollment-card disclosure if/when they enroll).
    public nonisolated static func decide(wizardCompleted: Bool, showingWizard: Bool,
                                          perAppNoticeSeen: Bool,
                                          hasEnrolledVoiceprints: Bool) -> Decision {
        guard wizardCompleted else { return .markSeenSilently }
        guard !showingWizard, perAppNoticeSeen else { return .wait }
        return hasEnrolledVoiceprints ? .show : .markSeenSilently
    }

    /// Present the one-time notice modally. "Voiceprint Settings…" opens the
    /// Dictionary pane (where the off-switch lives); "Got It" dismisses.
    public static func show() {
        // The app is LSUIElement, so it may be inactive at launch — activate so
        // the alert is visible and frontmost.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Your voiceprints now improve from corrections"
        alert.informativeText = """
            When an enrolled term fires by mistake on a similar-sounding everyday \
            word, correcting it — by undoing the correction or editing the word \
            back — now refines that term's voiceprint so the mistake stops \
            recurring. It's on-device: only an encrypted voice embedding is stored \
            (never audio), and it's deleted with the voiceprint.

            You can turn this off any time under Settings → Dictionary \
            ("Refine voiceprints from corrections").
            """
        alert.addButton(withTitle: "Voiceprint Settings…")
        alert.addButton(withTitle: "Got It")
        if alert.runModal() == .alertFirstButtonReturn {
            ParleqAppWindowController.shared.show(settingsPane: .dictionary)
        }
    }
}
#endif
