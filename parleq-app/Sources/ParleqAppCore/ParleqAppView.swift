// ParleqAppView — root SwiftUI view for the 0.14.0 app shell.
//
// NavigationSplitView with a sidebar listing the four top-level
// sections (Recent / Stats / Settings / About) + a detail pane
// that renders the selected section. PR 1 ships placeholders for
// Recent, Stats, and About; the Settings section embeds the
// existing SettingsView directly. PR 2 restructures Settings into
// a nested sub-sidebar; PRs 3 + 5 implement Recent + Stats.

import SwiftUI

@MainActor
struct ParleqAppView: View {
    @ObservedObject var selectedSection: SectionBox
    @ObservedObject var settingsModel: SettingsModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        // Tint the entire app shell with Parleq's brand amber so the
        // sidebar selection highlight, prominent buttons (Copy +
        // Paste here), and other `.tint`-driven affordances match
        // the Settings UX. Without this, NavigationSplitView falls
        // back to NSColor.controlAccentColor (the user's macOS
        // accent — typically blue) and the new app-shell surfaces
        // diverge visually from the legacy Settings card styles
        // that hard-code `.accentColor(brandAccent)` at their root.
        .tint(SettingsView.brandAccent)
        .accentColor(SettingsView.brandAccent)
        // Reload Settings from disk whenever the user navigates INTO
        // the Settings section. Matches the legacy
        // SettingsWindowController.show() behavior — config can
        // change underneath the UI from the setup wizard, the menu
        // bar microphone picker, keychain edits, or manual edits to
        // ~/.parleq/config.json. Without this, the Settings section
        // would render whatever state the SettingsModel happened to
        // have at app-launch and a subsequent save would clobber
        // newer config. Triggers on transition INTO .settings only;
        // bouncing within Settings or navigating to other sections
        // doesn't refire (preserves in-progress edits).
        .onChange(of: selectedSection.value) { _, newValue in
            if newValue == .settings {
                settingsModel.reload()
            }
        }
        // Also reload on first appearance if Settings is the
        // landing section (it isn't by default — landing is Recent
        // — but a future "remember last section" feature could
        // change that, and this branch costs nothing).
        .onAppear {
            if selectedSection.value == .settings {
                settingsModel.reload()
            }
        }
    }

    /// Sidebar — fixed list of the four top-level sections. Using a
    /// List with `selection:` binding gives us native macOS sidebar
    /// affordances (highlight, keyboard navigation) for free.
    private var sidebar: some View {
        List(
            ParleqAppSection.allCases,
            selection: Binding(
                get: { selectedSection.value },
                set: { selectedSection.value = $0 ?? .recent }
            )
        ) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedSection.value {
        case .recent:   recentSection
        case .stats:    statsSection
        case .settings: settingsSection
        case .about:    aboutSection
        }
    }

    // MARK: - Section placeholders (PR 1)

    /// Recent Dictations landing — the user's session history with
    /// per-card Copy + Paste-here + delete actions, plus a first-
    /// launch banner and bulk Clear-all. PR 3 (#218).
    private var recentSection: some View {
        RecentDictationsView(
            history: TranscriptHistory.shared,
            pasteTargetProvider: {
                ParleqAppWindowController.shared.priorFrontmostTarget
            }
        )
    }

    /// Stats dashboard — four metric clusters (dictation count,
    /// speaking time + latencies, tokens + cost, quality + ref
    /// rates) with today + this-week summaries and 7-day
    /// sparklines. PR 5 (#220).
    private var statsSection: some View {
        StatsView(history: TranscriptHistory.shared)
    }

    /// Settings — embeds the existing SettingsView directly in PR 1
    /// so all current settings remain functional during the app-shell
    /// rollout. PR 2 restructures this into a nested sidebar (Hotkey
    /// / Audio / … each as a sub-section) instead of the current
    /// horizontal-tabs layout, but the underlying SettingsModel +
    /// per-tab content stays unchanged.
    private var settingsSection: some View {
        SettingsView(model: settingsModel)
    }

    /// About section — the brand mark, version, source link, and
    /// licenses entry point. Matches the content that used to live
    /// behind the menu bar's "About Parleq" (`NSApp`'s standard
    /// about panel) plus "Open Source Licenses…" items.
    private var aboutSection: some View {
        VStack(spacing: 16) {
            // The actual orange Parleq mark macOS uses for the Dock /
            // Finder / standard about panel. Reads the running app's
            // icon image rather than a separately-bundled SVG so we
            // can never drift between the About page and the system
            // icon — they're literally the same NSImage.
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
            }
            Text("Parleq")
                .font(.largeTitle.weight(.semibold))
            Text("Version \(versionString)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Voice dictation for macOS — speak naturally, edit deliberately, paste anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.top, 4)
            HStack(spacing: 8) {
                Link(destination: URL(string: "https://parleq.app")!) {
                    Label("Website", systemImage: "globe")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Link(destination: URL(string: "https://github.com/parleq/parleq-speech")!) {
                    Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Link(destination: URL(string: "https://github.com/parleq/parleq-speech/blob/main/THIRD_PARTY_LICENSES.md")!) {
                    Label("Open source licenses", systemImage: "doc.text")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 8)
            Text("Copyright © 2026 Parleq contributors. Apache-2.0 licensed.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Read the bundle's marketing version + build number for the
    /// About page. Falls back to "unknown" if Info.plist somehow
    /// doesn't carry the keys (defensive — shouldn't happen in a
    /// signed app build, but guards against the SwiftPM-test
    /// in-process load where Info.plist isn't set).
    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}
