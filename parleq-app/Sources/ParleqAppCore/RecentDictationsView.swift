// RecentDictationsView — the landing page of the new Parleq app
// (0.14.0 PR 3, #218).
//
// Replaces the menu-bar's "Recent Dictations ▶" submenu (deleted in
// the same PR) with a scrollable card-based history browser. Each
// entry shows the full cleaned text + metadata (timestamp, target
// app, reference count, raw-fallback badge) with per-card Copy +
// "Paste here" actions and a × to delete a single entry. A bulk
// "Clear all dictation history" button at the bottom mirrors the
// old "Clear Recent" item.
//
// Memory-only: matches the existing TranscriptHistory invariant —
// entries vanish on app quit, never touch disk. PR 6 (#221) adds
// MDM-configurable retention limits on top of this surface.
//
// First-launch banner: shown once after upgrading from 0.13.x so
// users notice that View Managed Configuration / Reset ASR / About
// / Recent Dictations all live in this new window. Dismissed
// state persists in UserDefaults under
// `parleq.appShell.upgradeBannerDismissed`.

import AppKit
import SwiftUI

@MainActor
struct RecentDictationsView: View {
    @ObservedObject var history: TranscriptHistory
    /// AppKit hook used by per-card "Paste here" to route into the
    /// app the user was pointing at when they opened Parleq. nil
    /// disables the button (no usable target captured).
    let pasteTargetProvider: () -> PasteTarget?

    @State private var showClearAllConfirm = false
    @State private var copiedEntryID: UUID?
    /// True while a paste operation is in flight. Disables every
    /// card's Copy + Paste-here buttons until the in-flight paste
    /// completes. Paster.paste snapshots + restores the system
    /// pasteboard around its synthesized Cmd-V, and overlapping
    /// pastes can interleave those snapshots — restoring the wrong
    /// text and losing what the user had previously copied.
    /// Serializing through a single in-flight flag keeps the
    /// pasteboard mutation cleanly bracketed.
    @State private var isPasting = false

    /// UserDefaults key for the one-time upgrade banner. UserDefaults
    /// (not Config) per the design spec — UI-only one-shot flag,
    /// conventional UserDefaults territory.
    private let bannerDismissKey = "parleq.appShell.upgradeBannerDismissed"

    @AppStorage("parleq.appShell.upgradeBannerDismissed") private var bannerDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            if !bannerDismissed {
                upgradeBanner
            }
            sectionHeader
            if history.entries.isEmpty {
                emptyState
            } else {
                entryList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Section header for the Recent landing: title + trailing
    /// "Clear all" affordance. Mirrors StatsView's inline title and
    /// gives the bulk-clear action a stable, scroll-independent home
    /// — the prior placement at the bottom of the scroll content
    /// forced users to scroll through their entire history before
    /// reaching the clear button.
    ///
    /// Clear all is shown whenever there's anything to wipe — visible
    /// cards OR metrics-only records. Hiding it when both are empty
    /// removes a no-op affordance from the empty-state UI; surfacing
    /// it when metrics persist past visible cards (cap-pruned text)
    /// matches the prior empty-state-with-metrics branch's intent.
    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Recent")
                .font(.title2.weight(.semibold))
            Spacer()
            if !history.entries.isEmpty || !history.metricsRecords.isEmpty {
                clearAllButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Sub-views

    /// One-time dismissible callout shown after upgrading from 0.13.x.
    private var upgradeBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(SettingsView.brandAccent)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("Things moved in 0.14.0.")
                    .font(.callout.weight(.semibold))
                Text("Settings, About, and Reset speech model all live in this Parleq app now. Open it via Show Parleq… in the menu bar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: { bannerDismissed = true }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(SettingsView.brandAccent.opacity(0.08))
        .overlay(
            Rectangle()
                .fill(SettingsView.brandAccent.opacity(0.30))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No dictations yet this session")
                .font(.title3.weight(.medium))
            Text("Your accepted dictations will appear here. History lives in memory only — it clears when you quit Parleq.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(history.entries) { entry in
                    RecentDictationCard(
                        entry: entry,
                        copyHighlighted: copiedEntryID == entry.id,
                        actionsDisabled: isPasting,
                        onCopy: { copy(entry: entry) },
                        onPaste: { paste(entry: entry) },
                        onDelete: { history.remove(id: entry.id) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    /// Trailing-of-header bulk wipe action. Confirmation alert
    /// elaborates on what gets dropped — visible cards plus the
    /// underlying metrics records that feed Stats — so the user
    /// understands this resets the session's dashboard counters,
    /// not just the visible list.
    private var clearAllButton: some View {
        Button(role: .destructive) {
            showClearAllConfirm = true
        } label: {
            Label("Clear all", systemImage: "trash")
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .alert("Wipe all dictation history from this session?",
               isPresented: $showClearAllConfirm) {
            Button("Clear All", role: .destructive) {
                history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Drops \(history.entries.count) visible \(history.entries.count == 1 ? "entry" : "entries") and resets the Stats section's session counters. Dictation history lives in memory only — it would clear when you quit Parleq anyway, but this wipes it immediately. Cannot be undone.")
        }
    }

    // MARK: - Actions

    private func copy(entry: TranscriptEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        // Flash "Copied" on the relevant card for ~1.2s. Re-clicking
        // before the timeout extends it (set the same id again);
        // the async dispatch dismisses based on the generation
        // captured in the closure so a later click doesn't trigger
        // an earlier dismiss.
        copiedEntryID = entry.id
        let myID = entry.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedEntryID == myID {
                copiedEntryID = nil
            }
        }
    }

    private func paste(entry: TranscriptEntry) {
        // Guard against re-entry. The actionsDisabled binding on
        // each card disables the buttons while this is true, but
        // the guard is belt-and-suspenders defense against
        // ordering quirks (e.g. an accessibility-driven action
        // that bypasses the disabled state).
        guard !isPasting else { return }
        guard let target = pasteTargetProvider() else {
            // No target captured — fall back to clipboard copy so
            // the user still gets something useful out of the
            // click. Rare path (Finder / Dock as prior frontmost).
            copy(entry: entry)
            return
        }
        isPasting = true
        Task { @MainActor in
            defer { isPasting = false }
            do {
                try await Paster.paste(text: entry.text, into: target)
                // Successful paste — dismiss the Parleq window. By
                // the time we get here Paster has already activated
                // the target app and posted Cmd-V into it; the user
                // wants to see their pasted text in the target's
                // window, not Parleq's. Keeping Parleq open after a
                // "Paste here" click would just cover the target.
                ParleqAppWindowController.shared.close()
            } catch {
                // Paste failed — typically because the target app
                // quit or restarted between the Parleq window
                // opening and the paste attempt. Fall back to
                // clipboard copy so the click still produces a
                // useful side effect. Also flash the "Copied ✓"
                // state on the card so the user knows the click
                // did something even though the paste didn't land.
                // Window stays open so the user can see the badge
                // and decide what to do next.
                copy(entry: entry)
            }
        }
    }
}

/// One card in the Recent Dictations scroll list.
@MainActor
private struct RecentDictationCard: View {
    let entry: TranscriptEntry
    let copyHighlighted: Bool
    /// True while a paste operation is in flight elsewhere in the
    /// list — disables every card's Copy + Paste-here buttons so
    /// the pasteboard mutation is bracketed. See `isPasting`
    /// docstring in `RecentDictationsView`.
    let actionsDisabled: Bool
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onDelete: () -> Void

    @State private var showFullText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            bodyText
            footer
        }
        .padding(14)
        .background(SettingsView.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(SettingsView.cardBorder, lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Periodic refresh so "2 min ago" stays accurate without
            // user interaction. 60-second cadence matches the
            // RelativeDateTimeFormatter's minute-resolution output;
            // sub-minute updates would be wasted work.
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                Text(Self.relativeFormatter.localizedString(
                    for: entry.timestamp, relativeTo: context.date
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            if let app = entry.targetAppName {
                Text("·")
                    .foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 12, height: 12)
                    }
                    Text(app)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if entry.referenceCount > 0 {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(entry.referenceCount) ref\(entry.referenceCount == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(entry.referenceLabels.joined(separator: ", "))
            }
            if !entry.wasCleanupSuccessful {
                rawBadge
            }
            Spacer(minLength: 4)
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this entry from history")
        }
    }

    private var rawBadge: some View {
        Text("raw")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.orange.opacity(0.15))
            )
            .help("Cleanup failed for this dictation; the text below is the raw ASR transcript.")
    }

    @ViewBuilder
    private var bodyText: some View {
        Text(entry.text)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .lineLimit(showFullText ? nil : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        if !showFullText && needsExpansion {
            Button("Show more") { showFullText = true }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SettingsView.brandAccent)
        }
    }

    /// Heuristic: assume the text needs expansion if it has more
    /// than 6 line breaks OR more than 480 characters (an
    /// approximation of "would exceed 6 lines at the rendered
    /// width"). Avoids the more expensive measure-then-test pass
    /// that would require a GeometryReader.
    private var needsExpansion: Bool {
        let newlines = entry.text.filter { $0.isNewline }.count
        return newlines >= 6 || entry.text.count > 480
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(action: onCopy) {
                Label(copyHighlighted ? "Copied ✓" : "Copy",
                      systemImage: "doc.on.doc")
                    .font(.system(size: 11))
                    // Stable width so the label swap doesn't
                    // reflow the row.
                    .frame(minWidth: 70, alignment: .center)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(actionsDisabled)
            Button(action: onPaste) {
                Label("Paste here", systemImage: "arrow.right.to.line.compact")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(actionsDisabled)
        }
    }

    // MARK: - Helpers

    /// Shared formatter for the periodic-refresh header text. One
    /// instance is fine — RelativeDateTimeFormatter is thread-safe
    /// for `localizedString(for:relativeTo:)` use.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// Looks up the target app's icon via NSWorkspace using the
    /// stored bundleID — wait, TranscriptEntry stores targetAppName
    /// (the human-readable label), not bundleID. To get an icon we'd
    /// need bundleID; PR 3 returns nil here and the card renders
    /// without an icon. A small follow-up could augment
    /// TranscriptEntry to store bundleID for icon lookup; not
    /// blocking the rest of this PR.
    private var appIcon: NSImage? {
        nil
    }
}
