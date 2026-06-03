// LearnBanner — the one-time, dismissible "new feature" nudge that tells
// users the opt-in "Learn from corrections" feature exists. Shown only
// while the feature is OFF (its discovery job is done once they enable
// it) and not dismissed. Two surfaces share state via UserDefaults:
//   • the in-app banner (Recent landing view), with a link to the toggle
//   • a line on the dictation review overlay carrying an inline toggle
//     that turns the feature on right there
// Dismissing from either surface hides both; the overlay line also
// auto-stops 24h after it's first shown so it never nags indefinitely.

import Foundation

enum LearnBanner {
    static let dismissedKey = "parleq.learnBanner.dismissed"
    /// `timeIntervalSinceReferenceDate` of the first overlay render; 0 = not shown yet.
    static let overlayFirstShownKey = "parleq.learnBanner.overlayFirstShownAt"
    /// How long the overlay line keeps showing after it first appears.
    static let overlayWindowSeconds: Double = 86_400  // 24h

    // MARK: - Persisted state (UserDefaults)

    static var dismissed: Bool {
        UserDefaults.standard.bool(forKey: dismissedKey)
    }

    /// Hide the nudge on both surfaces.
    static func dismiss() {
        UserDefaults.standard.set(true, forKey: dismissedKey)
    }

    /// Mark the feature as discovered (same persisted flag as dismiss).
    /// Called whenever the user enables it — so the one-time banner never
    /// reappears if they later turn the feature back off.
    static func markDiscovered() {
        UserDefaults.standard.set(true, forKey: dismissedKey)
    }

    /// Stamp the first-shown time once, so the 24h overlay window starts
    /// at the first overlay appearance. No-op after the first call.
    static func recordOverlayShownIfNeeded(now: Double = Date().timeIntervalSinceReferenceDate) {
        if UserDefaults.standard.double(forKey: overlayFirstShownKey) == 0 {
            UserDefaults.standard.set(now, forKey: overlayFirstShownKey)
        }
    }

    static var overlayFirstShownAt: Double? {
        let v = UserDefaults.standard.double(forKey: overlayFirstShownKey)
        return v == 0 ? nil : v
    }

    /// Turn the feature on (the overlay toggle). Returns whether the
    /// feature is effectively ON afterward, so the caller only updates the
    /// UI on real success. Respects MDM: if `learnFromCorrectionsEnabled`
    /// is pinned, this can't change it (returns the pinned value). Marks
    /// the banner discovered on success so it won't re-nag later.
    @MainActor @discardableResult
    static func enableFeature() -> Bool {
        var (config, _) = Config.load()
        // Pinned by MDM — can't toggle; report the effective value.
        if config.managedKeys.contains("learnFromCorrectionsEnabled") {
            return config.learnFromCorrectionsEnabled
        }
        if config.learnFromCorrectionsEnabled {
            markDiscovered()
            return true
        }
        config.learnFromCorrectionsEnabled = true
        try? Config.save(config)
        // Confirm it actually persisted before claiming success.
        guard Config.load().config.learnFromCorrectionsEnabled else { return false }
        CorrectionJournal.shared.applyRetentionLimits(from: config)
        markDiscovered()
        // Keep an already-open Settings window in sync: its SettingsModel
        // loaded the old value at init and would write a stale `false` back
        // on its next save, silently re-disabling the feature.
        NotificationCenter.default.post(name: .parleqLearnFeatureEnabledExternally, object: nil)
        return true
    }

    // MARK: - Pure visibility rules (unit-tested)

    static func shouldShowInApp(dismissed: Bool, featureEnabled: Bool, managed: Bool = false) -> Bool {
        // When the flag is MDM-pinned, the org controls it — don't nag the
        // user to enable (or advertise) something they can't change.
        !dismissed && !featureEnabled && !managed
    }

    static func shouldShowInOverlay(
        dismissed: Bool,
        featureEnabled: Bool,
        firstShownAt: Double?,
        now: Double,
        windowSeconds: Double = overlayWindowSeconds,
        managed: Bool = false
    ) -> Bool {
        guard !dismissed, !featureEnabled, !managed else { return false }
        guard let first = firstShownAt else { return true }  // not yet shown → show
        return now - first < windowSeconds
    }
}
