// UpdatesView — the Settings → Updates detail pane.
//
// Two controls:
//   - "Automatically check for updates" toggle. Reads + writes
//     directly through `SPUUpdater.automaticallyChecksForUpdates`
//     via a Binding rather than @AppStorage. Two reasons: (a) on
//     the very first launch, before Sparkle's "do you want auto-
//     updates?" prompt has run, the underlying UserDefaults key is
//     unset — @AppStorage's default of `true` would show the toggle
//     as ON while Sparkle's actual behavior is "haven't been told
//     yet, awaiting the prompt." (b) Sparkle's getter encodes the
//     truth at any given moment; bypassing it would let SwiftUI
//     and Sparkle disagree.
//   - "Check for Updates Now" button. Posts `.parleqCheckForUpdates`
//     which ParleqApp.main observes and forwards to the retained
//     SPUStandardUpdaterController. Same decoupling pattern Settings
//     uses for the "Run Setup Again" button.
//
// The view reads the updater controller via the `SparkleHolder`
// shim that ParleqApp.main writes at launch — the alternative was
// threading the controller through SettingsWindowController +
// SettingsView + every section as a constructor parameter, which is
// disproportionate plumbing for a single toggle.
//
// Why no live "Last checked" display: Sparkle's controller does
// expose `lastUpdateCheckDate`, but it's not @Published and updating
// it would require either a polling Timer or wiring an
// SPUUpdaterDelegate just to republish into SwiftUI. The "Check Now"
// button surfaces all the feedback a user actually needs (Sparkle
// shows either "you're up to date" or the "update available"
// prompt), so the timestamp doesn't earn its keep.

import Sparkle
import SwiftUI

/// Process-wide handle on the live Sparkle updater controller.
/// ParleqApp.main sets `controller` at launch; UpdatesSectionContent
/// reads it on view construction. Treated as a write-once value: the
/// only writer is ParleqApp.main and the only reader is this file.
@MainActor
enum SparkleHolder {
    static weak var controller: SPUStandardUpdaterController?
}

@MainActor
struct UpdatesSectionContent: View {
    /// Triggers a SwiftUI re-render when the toggle is flipped. The
    /// actual source of truth is `SPUUpdater.automaticallyChecksForUpdates`
    /// (which writes to UserDefaults under the documented
    /// `SUEnableAutomaticChecks` key); this @State just forces the
    /// view to redraw so the Toggle's visual state catches up to the
    /// underlying-bool change.
    @State private var refreshTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Parleq checks parleq.app for newer releases and prompts you to install. Each release is signed with an Ed25519 key the app verifies before downloading, so a tampered update can't be pushed by anyone other than the maintainer.")
                .font(.system(size: 13))
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Automatically check for updates", isOn: automaticChecksBinding())
                    SettingsCaption("When on, Parleq checks for a newer release on launch and once every 24 hours afterwards. When off, only the “Check for Updates Now” button below (and the menu-bar “Check for Updates…” item) trigger a check. The very first time you launch a Parleq build with auto-updates, Sparkle asks for your choice via a prompt — this toggle reflects (and overrides) what you picked there.")
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

    /// SwiftUI Binding that reads/writes the live
    /// `SPUUpdater.automaticallyChecksForUpdates` value. Falls
    /// through to a no-op disabled state when SparkleHolder isn't
    /// populated yet — should never happen in shipping builds
    /// (ParleqApp.main writes the holder before any window opens)
    /// but the defensive fallback keeps the view harmless even if
    /// someone changes launch ordering later.
    private func automaticChecksBinding() -> Binding<Bool> {
        Binding(
            get: {
                _ = refreshTick
                return SparkleHolder.controller?.updater.automaticallyChecksForUpdates ?? false
            },
            set: { newValue in
                SparkleHolder.controller?.updater.automaticallyChecksForUpdates = newValue
                refreshTick &+= 1
            }
        )
    }
}
