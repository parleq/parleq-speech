// UpdatesView — the Settings → Updates detail pane.
//
// Two controls:
//   - "Automatically check for updates" toggle. Bound via @AppStorage
//     to `SUEnableAutomaticChecks`, the same UserDefaults key Sparkle
//     reads from its own preference-loading path. SwiftUI's setter
//     writes through to standardUserDefaults; Sparkle's background
//     timer picks up the new value on its next read. No NotificationCenter
//     hop needed for this one because both sides already agree on
//     the storage key.
//   - "Check for Updates Now" button. Posts `.parleqCheckForUpdates`
//     which ParleqApp.main observes and forwards to the retained
//     SPUStandardUpdaterController. Same decoupling pattern Settings
//     uses for the "Run Setup Again" button.
//
// Why no live "Last checked" display: Sparkle's controller does
// expose `lastUpdateCheckDate`, but it's not @Published and updating
// it would require either a polling Timer or wiring an
// SPUUpdaterDelegate just to republish into SwiftUI. The "Check Now"
// button surfaces all the feedback a user actually needs (Sparkle
// shows either "you're up to date" or the "update available"
// prompt), so the timestamp doesn't earn its keep.

import SwiftUI

@MainActor
struct UpdatesSectionContent: View {
    /// Bound to Sparkle's `SUEnableAutomaticChecks` preference key.
    /// Default = true (matches Sparkle's behavior on first-run after
    /// the user opts in to background checks). SwiftUI's setter
    /// writes through to UserDefaults; Sparkle reads it on its next
    /// timer tick.
    @AppStorage("SUEnableAutomaticChecks") private var automaticChecks = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Parleq checks parleq.app for newer releases and prompts you to install. Each release is signed with an Ed25519 key the app verifies before downloading, so a tampered update can't be pushed by anyone other than the maintainer.")
                .font(.system(size: 13))
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Automatically check for updates", isOn: $automaticChecks)
                    SettingsCaption("When on, Parleq checks for a newer release on launch and once every 24 hours afterwards. When off, only the “Check for Updates Now” button below (and the menu-bar “Check for Updates…” item) trigger a check.")
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Check for an update now")
                        .font(.callout.weight(.medium))
                    SettingsCaption("Hits the parleq.app appcast immediately. If there's a newer release, Sparkle walks you through the download and relaunch; otherwise you'll see a brief “you're up to date” confirmation.")
                    HStack(spacing: 8) {
                        Button("Check for Updates Now") {
                            NotificationCenter.default.post(
                                name: .parleqCheckForUpdates,
                                object: nil
                            )
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}
