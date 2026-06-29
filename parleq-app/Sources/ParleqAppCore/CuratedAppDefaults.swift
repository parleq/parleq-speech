import Foundation

/// A tone preset Parleq *suggests* (never auto-applies) for a curated
/// Polished app. Surfaced as a one-tap, dismissable chip in the App-behavior
/// editor; `Config.behaviorForApp` deliberately never returns these as an
/// applied preset (suggestions stay off until the user accepts them).
public enum SuggestedTone: Equatable, Sendable {
    case friendlyConcise
    case professional
}

/// Curated per-app cleanup defaults, copied verbatim from the per-target
/// design spec's "Curated default map" appendix. These live in code (not
/// config) so the feature demonstrates itself out of the box; `Config`
/// stores only user *overrides*. Resolution order is enforced by
/// `Config.behaviorForApp`: user override → curated default mode → Polished.
///
/// `mode` is auto-applied; `suggestedTone` is only a one-tap suggestion.
///
/// NOTE: Several bundle IDs are version/variant-dependent and carry a
/// `TODO(verify-id)` marker — verify them at build time. User-added apps are
/// captured live via the Settings "Add app" affordance, not typed.
public enum CuratedAppDefaults {

    /// The curated mode for a bundle ID, or `nil` when the app is unlisted
    /// (the resolver then falls back to Polished).
    public static func mode(for bundleID: String) -> TargetMode? {
        if let entry = curated[bundleID] { return entry.mode }
        // JetBrains IDEs (IntelliJ, PyCharm, GoLand, …) share a
        // `com.jetbrains.*` bundle-ID prefix; treat the whole family as
        // Instant (code-editing context).
        if bundleID.hasPrefix("com.jetbrains.") { return .instant } // TODO(verify-id)
        return nil
    }

    /// The curated *suggested* tone for a bundle ID, or `nil`. Suggested
    /// only — `Config.behaviorForApp` never applies it automatically.
    public static func suggestedTone(for bundleID: String) -> SuggestedTone? {
        curated[bundleID]?.tone
    }

    // MARK: - The map

    private struct Curation {
        let mode: TargetMode
        let tone: SuggestedTone?
        init(_ mode: TargetMode, _ tone: SuggestedTone? = nil) {
            self.mode = mode
            self.tone = tone
        }
    }

    private static let curated: [String: Curation] = [
        // MARK: Instant — terminals, code editors/IDEs, spreadsheets
        "com.apple.Terminal": Curation(.instant),
        "com.googlecode.iterm2": Curation(.instant),
        "com.mitchellh.ghostty": Curation(.instant),
        "dev.warp.Warp-Stable": Curation(.instant),               // TODO(verify-id)
        "com.github.wez.wezterm": Curation(.instant),
        "net.kovidgoyal.kitty": Curation(.instant),
        "org.alacritty": Curation(.instant),
        "com.microsoft.VSCode": Curation(.instant),
        "com.todesktop.230313mzl4w4u92": Curation(.instant),      // TODO(verify-id) — Cursor
        "dev.zed.Zed": Curation(.instant),
        "com.sublimetext.4": Curation(.instant),                  // TODO(verify-id)
        "com.panic.Nova": Curation(.instant),
        "com.apple.dt.Xcode": Curation(.instant),
        "com.google.android.studio": Curation(.instant),
        "com.apple.iWork.Numbers": Curation(.instant),
        "com.microsoft.Excel": Curation(.instant),
        // (JetBrains com.jetbrains.* handled by prefix in mode(for:).)

        // MARK: Polished + suggested "Friendly & concise" — communication
        "com.tinyspeck.slackmacgap": Curation(.polished, .friendlyConcise),
        "com.hnc.Discord": Curation(.polished, .friendlyConcise),
        "com.microsoft.teams2": Curation(.polished, .friendlyConcise),    // TODO(verify-id)
        "com.apple.MobileSMS": Curation(.polished, .friendlyConcise),
        "org.whispersystems.signal-desktop": Curation(.polished, .friendlyConcise),
        "ru.keepcoder.Telegram": Curation(.polished, .friendlyConcise),   // TODO(verify-id)
        "net.whatsapp.WhatsApp": Curation(.polished, .friendlyConcise),   // TODO(verify-id)
        "us.zoom.xos": Curation(.polished, .friendlyConcise),

        // MARK: Polished + suggested "Professional" — email
        "com.apple.mail": Curation(.polished, .professional),
        "com.microsoft.Outlook": Curation(.polished, .professional),
        "com.readdle.smartemail-Mac": Curation(.polished, .professional), // TODO(verify-id)
        "it.bloop.airmail2": Curation(.polished, .professional),          // TODO(verify-id)
        "com.mimestream.Mimestream": Curation(.polished, .professional),

        // MARK: Polished, no suggested tone — word processors / slides / notes / long-form
        "com.apple.iWork.Pages": Curation(.polished),
        "com.microsoft.Word": Curation(.polished),
        "com.apple.iWork.Keynote": Curation(.polished),
        "com.microsoft.Powerpoint": Curation(.polished),                  // TODO(verify-id)
        "com.microsoft.onenote.mac": Curation(.polished),                 // TODO(verify-id)
        "notion.id": Curation(.polished),
        "md.obsidian": Curation(.polished),
        "com.apple.Notes": Curation(.polished),
        "net.shinyfrog.bear": Curation(.polished),
        "com.agiletortoise.Drafts-OSX": Curation(.polished),
        "com.apple.TextEdit": Curation(.polished),
        // (Ulysses / iA Writer bundle IDs are variant-dependent; captured
        //  live via "Add app" rather than guessed here.)

        // MARK: Polished — browsers (URL-targeting splits them later)
        "com.apple.Safari": Curation(.polished),
        "com.google.Chrome": Curation(.polished),
        "company.thebrowser.Browser": Curation(.polished),                // Arc
        "com.microsoft.edgemac": Curation(.polished),
        "com.brave.Browser": Curation(.polished),
        "org.mozilla.firefox": Curation(.polished),
    ]
}
