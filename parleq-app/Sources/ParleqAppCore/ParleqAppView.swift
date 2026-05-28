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
    /// Whether the Settings disclosure group in the sidebar is
    /// expanded. Starts expanded when the current selection is a
    /// Settings pane (e.g. a restart-into-Settings reopen) so the
    /// selected pane is visible; otherwise collapsed to keep the
    /// sidebar short. 0.15.0 unified navigation (#62).
    @State private var settingsExpanded: Bool

    /// Sidebar column visibility. Auto-collapses to `.detailOnly` when
    /// the window gets narrow (so a small / low-res viewport gives the
    /// whole width to the detail pane) and restores to `.all` when it
    /// widens again. An explicit toolbar toggle lets the user bring it
    /// back (or dismiss it) at any width — chosen over hover-to-reveal
    /// because a deterministic button is the accessible option for the
    /// low-vision / motor-impaired users this narrow-viewport work is
    /// for. #61/#62.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Tracks whether the window is currently in the auto-hidden
    /// (narrow) state. We only flip `columnVisibility` when the width
    /// crosses OUT of the hysteresis band, not on every width change,
    /// so a manual toggle survives further resizing while still narrow.
    @State private var isNarrow = false

    /// Hysteresis band for sidebar auto-hide. The sidebar hides once
    /// the window drops below `hideBelowWidth` and only re-appears once
    /// it grows back past the wider `showAboveWidth`. The gap is what
    /// stops the sidebar from flickering — and the layout from
    /// appearing to "jump" — when a live resize-drag hovers right at a
    /// single threshold (sub-pixel jitter would otherwise re-cross it
    /// every frame). `hideBelowWidth` is set so the sidebar tucks away
    /// BEFORE its ~200pt column would squeeze the detail pane below the
    /// Settings content's readable width — i.e. before the user would
    /// be forced to scroll horizontally.
    private let hideBelowWidth: CGFloat = 720
    private let showAboveWidth: CGFloat = 820

    init(selectedSection: SectionBox, settingsModel: SettingsModel) {
        self.selectedSection = selectedSection
        self.settingsModel = settingsModel
        _settingsExpanded = State(initialValue: selectedSection.value.isSettings)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        // Explicit, always-available sidebar toggle. NavigationSplitView
        // surfaces this in the title bar; it's the deterministic way to
        // bring the sidebar back after it auto-hides on a narrow window.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation { toggleSidebar() }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Show or hide the sidebar")
            }
        }
        // Observe the shell's content width to drive auto-hide. A clear
        // background GeometryReader reports the NavigationSplitView's
        // own width (stable — hiding the sidebar doesn't change it, so
        // there's no oscillation).
        .background(
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.width) { _, width in
                        adjustSidebar(forWidth: width)
                    }
                    .onAppear { adjustSidebar(forWidth: geo.size.width) }
            }
        )
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
        .onChange(of: selectedSection.value) { oldValue, newValue in
            // Reload Settings from disk on transition INTO any
            // Settings pane (config can change underneath the UI from
            // the wizard, the mic picker, keychain edits, or manual
            // ~/.parleq/config.json edits). Only fires when crossing
            // from a non-Settings selection so bouncing between panes
            // doesn't clobber in-progress edits.
            if newValue.isSettings && !oldValue.isSettings {
                settingsModel.reload()
            }
            // Persist the last-visited Settings pane so a restart-
            // initiated reopen (show(section: .settings)) lands back
            // on it. Reuses the legacy key the old in-Settings
            // sub-sidebar used.
            if case .settings(let pane) = newValue {
                UserDefaults.standard.set(pane.rawValue, forKey: "parleq.settings.selection")
                if !settingsExpanded { settingsExpanded = true }
            }
        }
        .onAppear {
            if selectedSection.value.isSettings {
                settingsModel.reload()
                settingsExpanded = true
            }
        }
    }

    /// Auto-hide the sidebar when the window narrows below
    /// `hideBelowWidth`, restore it once it grows back past
    /// `showAboveWidth`. The hysteresis gap (and the `isNarrow` latch)
    /// mean a live resize that lingers near the boundary can't make the
    /// sidebar flicker, and a manual toggle isn't clobbered by every
    /// resize tick while still narrow.
    private func adjustSidebar(forWidth width: CGFloat) {
        if !isNarrow && width < hideBelowWidth {
            isNarrow = true
            withAnimation { columnVisibility = .detailOnly }
        } else if isNarrow && width > showAboveWidth {
            isNarrow = false
            withAnimation { columnVisibility = .all }
        }
    }

    /// Flip the sidebar between hidden and shown. On a narrow window
    /// `.all` shows it as an overlay; on a wide window it sits in its
    /// own column.
    private func toggleSidebar() {
        columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
    }

    /// Single unified sidebar (0.15.0): Recent / Stats / Settings
    /// (expandable into its panes) / About. Folding the Settings
    /// sub-sections in here collapses the old 3-column Settings layout
    /// to 2 columns, which is what fits small / low-res viewports.
    private var sidebar: some View {
        List(selection: selectionBinding) {
            Label(ParleqAppSection.recent.title, systemImage: ParleqAppSection.recent.systemImage)
                .tag(ParleqAppSelection.recent)
            Label(ParleqAppSection.stats.title, systemImage: ParleqAppSection.stats.systemImage)
                .tag(ParleqAppSelection.stats)
            DisclosureGroup(isExpanded: $settingsExpanded) {
                ForEach(SettingsView.SettingsSection.allCases) { pane in
                    Label(pane.label, systemImage: pane.icon)
                        .tag(ParleqAppSelection.settings(pane))
                }
            } label: {
                // Make the whole Settings row toggle the group, not
                // just the disclosure chevron — clicking the small
                // chevron directly is fiddly. contentShape makes the
                // full row width hit-testable; the chevron still works
                // on its own too.
                Label(ParleqAppSection.settings.title, systemImage: ParleqAppSection.settings.systemImage)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation { settingsExpanded.toggle() }
                    }
            }
            Label(ParleqAppSection.about.title, systemImage: ParleqAppSection.about.systemImage)
                .tag(ParleqAppSelection.about)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        .listStyle(.sidebar)
    }

    /// Selection binding into the SectionBox. nil (e.g. user clicks
    /// empty sidebar space) coalesces to .recent so the detail pane
    /// always has something to show.
    private var selectionBinding: Binding<ParleqAppSelection?> {
        Binding(
            get: { selectedSection.value },
            set: { selectedSection.value = $0 ?? .recent }
        )
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch selectedSection.value {
            case .recent:            recentSection
            case .stats:             statsSection
            case .settings(let s):   settingsSection(s)
            case .about:             aboutSection
            }
        }
        // Fill the detail column; the window's single minimum size
        // (set on the NSWindow, sizingOptions = []) is now the only
        // floor — uniform across panes, so the resize limit no longer
        // wobbles as you navigate (#62). No per-pane minWidth/minHeight
        // here on purpose: a minHeight would overflow + clip the pane
        // when the window is shorter than it (Stats couldn't scroll to
        // the clipped cards), and a minWidth would stop the window
        // before the detail got narrow enough to engage the Settings
        // horizontal-scroll accessibility fallback.
        //
        // topLeading alignment: panes shorter than the viewport pin to
        // the top-left instead of floating to the vertical center
        // (which looked broken on tall windows with short panes).
        // Panes that fill (the ScrollView-based ones) are unaffected.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    /// Settings — renders the single pane selected in the unified
    /// sidebar (0.15.0). SettingsView no longer owns a sub-sidebar;
    /// it just draws the pane for `section` (+ the restart banner).
    private func settingsSection(_ section: SettingsView.SettingsSection) -> some View {
        SettingsView(model: settingsModel, section: section)
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
