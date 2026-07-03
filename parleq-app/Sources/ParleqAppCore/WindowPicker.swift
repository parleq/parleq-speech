// WindowPicker — Zoom-style window picker. Renders a grid of live
// thumbnails (one per capturable window) so the user can visually
// pick the window they want as a reference, exactly like Zoom's
// "Share Screen" picker.
//
// Pipeline:
//   1. SCK enumerates shareable windows (excludingDesktopWindows +
//      onScreenWindowsOnly:false so cross-Space apps appear).
//   2. We filter by self / bundle blocklist / size.
//   3. Entries are sorted: frontmost app first, then by app name, then
//      by title — the user's most likely pick lands at the top.
//   4. As soon as the Entry list resolves, the popover renders the
//      grid with placeholder cards (app icon + name).
//   5. A TaskGroup captures thumbnails concurrently via
//      SCScreenshotManager. Each thumbnail is rendered at ~280px wide
//      (downscaled from native by SCK), which is plenty for visual
//      recognition. Cards swap from placeholder → thumbnail as they
//      arrive. Memory: 30 thumbnails ≈ 3–4 MB total, freed when the
//      popover closes.
//   6. Click a card → the existing onPick(entry) callback fires; the
//      capture pipeline runs at full resolution + OCR.
//
// If Screen Recording permission hasn't been granted, the picker
// renders an explanatory state with a button that opens the
// relevant System Settings pane rather than silently surfacing
// "no windows available."

import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

/// SCWindow handle marked Sendable so it can ride a TaskGroup child
/// task into a background actor without Swift 6 strict-concurrency
/// rejecting the capture. SCWindow has no mutable state we touch from
/// here — we only call read-only properties and pass it to SCK — so
/// @unchecked is safe.
private struct WindowSource: @unchecked Sendable {
    let windowID: CGWindowID
    let scWindow: SCWindow
}

@MainActor
final class WindowPickerModel: ObservableObject {
    struct Entry: Identifiable {
        // Use the windowID directly as the identity — stable across
        // refreshes so ForEach can preserve row state.
        var id: CGWindowID { windowID }
        let windowID: CGWindowID
        let pid: pid_t
        let bundleID: String
        let appName: String   // user-facing app name, e.g. "Xcode"
        let title: String     // window title, or app name fallback
        let appIcon: NSImage?
    }

    @Published var entries: [Entry] = []
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var isLoading = false
    @Published var error: String?
    @Published var needsPermission = false

    /// Index of the currently-keyboard-selected entry. Drives the
    /// highlight ring on WindowThumbnailCard and is the target of
    /// the Enter key. nil when no entry is selected (e.g. immediately
    /// after the picker opens with no keyboard interaction yet, or
    /// when the entries list is empty / still loading). Index-based
    /// (rather than windowID-based) so the panel's arrow-key handler
    /// can do simple `index + 1` / `index + columnCount` arithmetic
    /// without rebuilding a position map after every refresh.
    @Published var selectedIndex: Int?

    /// Column count of the currently-rendered LazyVGrid, set by the
    /// view via a preference key. The grid is `.adaptive`, so the
    /// count varies with panel width; the panel's keyDown handler
    /// reads this to translate Up/Down arrows into the correct
    /// row-jump distance. Defaults to 1 so a never-rendered panel
    /// (test harness, very narrow window) still produces sensible
    /// navigation behavior — every arrow becomes a linear step.
    @Published var columnCount: Int = 1

    /// Bundle IDs whose windows we never want to surface as reference
    /// candidates. System UI surfaces / background helper windows that
    /// occasionally have titles but aren't user content.
    /// Internal (not private) so the App-behavior editor's "Add app" picker can
    /// reuse the same system-surface exclusions instead of duplicating them.
    static let systemBundleBlocklist: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.notificationcenterui",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
        "com.apple.AppShortcuts.AppShortcutsPreview",
        "com.apple.AppShortcuts",
        "com.1password.1password-launcher",
        "com.1password.1password.helper",
        "com.apple.systempreferences",
    ]

    static let systemBundlePrefixBlocklist: [String] = [
        "com.apple.AppShortcuts",
        "com.apple.controlcenter",
    ]

    /// Token bumps on every refresh so stale TaskGroup results from
    /// a previous refresh can't pollute the current thumbnails dict.
    private var thumbnailGeneration: Int = 0

    func refresh() {
        guard CGPreflightScreenCaptureAccess() else {
            needsPermission = true
            entries = []
            thumbnails = [:]
            // Clear here too — entries is being emptied, so any
            // stored selection points at nothing. The panel's
            // keyDown normalization returns early on empty
            // entries and wouldn't clamp this on its own.
            selectedIndex = nil
            isLoading = false
            return
        }
        needsPermission = false
        error = nil
        if entries.isEmpty {
            isLoading = true
        }

        thumbnailGeneration += 1
        let myGeneration = thumbnailGeneration

        Task { @MainActor in
            do {
                let (fresh, sources) = try await fetchEntriesAndSources()
                guard myGeneration == self.thumbnailGeneration else { return }
                self.entries = fresh
                self.thumbnails = [:]
                // Drop any stale keyboard selection when the entry
                // list changes — the previously-selected index might
                // now point to a removed entry, and the panel's
                // keyDown handler does its own clamping but the
                // model is the authoritative store so clearing here
                // makes the empty-selection state immediate for any
                // observer (including the SwiftUI grid's isSelected
                // binding, which would otherwise highlight the wrong
                // card on a list shuffle).
                self.selectedIndex = nil
                self.isLoading = false
                await self.captureThumbnails(for: sources, generation: myGeneration)
            } catch {
                guard myGeneration == self.thumbnailGeneration else { return }
                let ns = error as NSError
                if ns.domain == SCStreamErrorDomain,
                   ns.code == SCStreamError.Code.userDeclined.rawValue
                    || ns.code == SCStreamError.Code.missingEntitlements.rawValue {
                    self.needsPermission = true
                    self.entries = []
                    self.thumbnails = [:]
                    self.selectedIndex = nil
                } else {
                    self.error = "Couldn't list windows: \(error.localizedDescription)"
                }
                self.isLoading = false
            }
        }
    }

    /// Walk SCK's shareable content, build Entry records, and pair
    /// each Entry with its source SCWindow for downstream thumbnail
    /// capture.
    ///
    /// Shape: one entry per regular running application, represented
    /// by that app's largest currently-shareable window — the same
    /// shape Zoom's screen-share picker has, and similar to what
    /// Mission Control shows when switching apps. Multiple windows of
    /// the same app collapse into a single card so a user with 12
    /// browser windows + 3 Xcode windows still only sees two cards
    /// for those apps.
    private func fetchEntriesAndSources() async throws -> ([Entry], [WindowSource]) {
        let shareable = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let rawCount = shareable.windows.count

        // The authoritative list of user-facing apps. activationPolicy
        // == .regular excludes menu-bar-only utilities (.accessory,
        // including Parleq itself), background services (.prohibited),
        // and most auto-launched helper bundles (1Password Quick Access,
        // Apple's App Shortcuts preview, etc.) — without us having to
        // chase them by bundle ID one at a time.
        let regularBundleIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleIdentifier }
        )

        let minWidth: CGFloat = 120
        let minHeight: CGFloat = 80
        var drops: [String: Int] = [:]
        func drop(_ reason: String) { drops[reason, default: 0] += 1 }

        // Group eligible windows by bundle ID, keeping the largest
        // window per app as the representative thumbnail. Largest is
        // almost always the main window the user thinks of as "that
        // app." This is the same shape Zoom uses — one tile per app
        // with the current/main window pictured.
        var byApp: [String: SCWindow] = [:]
        for w in shareable.windows {
            guard let app = w.owningApplication else { drop("no_owner"); continue }
            guard app.processID != selfPID else { drop("self"); continue }
            guard regularBundleIDs.contains(app.bundleIdentifier) else {
                drop("not_regular:\(app.bundleIdentifier)")
                continue
            }
            if Self.systemBundleBlocklist.contains(app.bundleIdentifier) {
                drop("blocklist:\(app.bundleIdentifier)")
                continue
            }
            if Self.systemBundlePrefixBlocklist.contains(where: { app.bundleIdentifier.hasPrefix($0) }) {
                drop("prefix_blocklist:\(app.bundleIdentifier)")
                continue
            }
            guard w.frame.width >= minWidth, w.frame.height >= minHeight else {
                drop("too_small:\(app.bundleIdentifier)")
                continue
            }

            if let existing = byApp[app.bundleIdentifier] {
                let existingArea = existing.frame.width * existing.frame.height
                let newArea = w.frame.width * w.frame.height
                if newArea > existingArea {
                    byApp[app.bundleIdentifier] = w
                }
            } else {
                byApp[app.bundleIdentifier] = w
            }
        }

        var pairs: [(Entry, WindowSource)] = []
        for (bundleID, w) in byApp {
            guard let app = w.owningApplication else { continue }
            let appName = appDisplayName(for: bundleID) ?? app.applicationName
            let title: String = {
                if let t = w.title, !t.trimmingCharacters(in: .whitespaces).isEmpty {
                    return t
                }
                return appName
            }()
            let icon: NSImage?
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                icon = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                icon = nil
            }
            let entry = Entry(
                windowID: w.windowID,
                pid: app.processID,
                bundleID: bundleID,
                appName: appName,
                title: title,
                appIcon: icon
            )
            pairs.append((entry, WindowSource(windowID: w.windowID, scWindow: w)))
        }

        // Sort: frontmost app first, then alphabetical.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        pairs.sort { a, b in
            let aFront = (a.0.pid == frontmostPID)
            let bFront = (b.0.pid == frontmostPID)
            if aFront != bFront { return aFront }
            return a.0.appName.localizedCaseInsensitiveCompare(b.0.appName) == .orderedAscending
        }

        let kept = pairs.count
        let dropped = rawCount - kept
        var summary = "[parleq] window-picker raw=\(rawCount) kept=\(kept) dropped=\(dropped) apps=\(regularBundleIDs.count)"
        if !drops.isEmpty {
            let buckets = drops.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            summary += " (\(buckets))"
        }
        FileHandle.standardError.write((summary + "\n").data(using: .utf8) ?? Data())

        return (pairs.map(\.0), pairs.map(\.1))
    }

    /// Concurrent thumbnail capture. Each thumbnail is captured at
    /// ~280px wide; SCK downscales from native resolution. As each
    /// task completes, the result is folded into `thumbnails` on the
    /// main actor (driving SwiftUI re-render). Out-of-date results
    /// from a stale refresh are discarded via the generation token.
    private func captureThumbnails(for sources: [WindowSource], generation: Int) async {
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for source in sources {
                group.addTask {
                    let image = try? await Self.captureThumbnail(for: source.scWindow)
                    return (source.windowID, image)
                }
            }
            for await (id, image) in group {
                guard generation == self.thumbnailGeneration else { continue }
                if let image {
                    self.thumbnails[id] = image
                }
            }
        }
    }

    /// One-off, low-resolution thumbnail capture for picker preview.
    /// No OCR, no extra processing — just the pixels.
    private static func captureThumbnail(for window: SCWindow) async throws -> NSImage? {
        let targetWidth: CGFloat = 280
        // Preserve aspect from the source window. SCK requires
        // explicit width/height in the config.
        let aspect = window.frame.height / max(window.frame.width, 1)
        let width = Int(targetWidth)
        let height = Int(max(targetWidth * aspect, 60))  // floor so very-wide windows still render

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false
        config.capturesAudio = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private func appDisplayName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - View

struct WindowPickerView: View {
    @ObservedObject var model: WindowPickerModel
    let onPick: (WindowPickerModel.Entry) -> Void
    let onAddFile: () -> Void
    let onAddClipboard: () -> Void
    let onPickByClicking: () -> Void

    /// Feature-toggle snapshot read once per body evaluation.
    /// Gates which action buttons are visible. Kept in a struct so
    /// we pay the Config.load() disk-read cost exactly once per body
    /// evaluation instead of once per sub-property access.
    private struct FeatureState {
        let fileReferenceEnabled: Bool
        let clipboardReferenceEnabled: Bool
    }

    private var featureState: FeatureState {
        let cfg = Config.load().config
        return FeatureState(
            fileReferenceEnabled: cfg.fileReferenceEnabled,
            clipboardReferenceEnabled: cfg.clipboardReferenceEnabled
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Action button row — placed above the window grid header so
            // the three attachment paths are immediately visible on open.
            actionButtonRow

            HStack {
                Text("Click a window to attach it as a reference")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.entries.isEmpty {
                    Text("\(model.entries.count) windows")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Refresh window list")
                .accessibilityLabel("Refresh window list")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.bottom, 12)
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private var actionButtonRow: some View {
        // Read toggles once per render so every sub-access is free.
        let features = featureState
        HStack(spacing: 8) {
            if features.fileReferenceEnabled {
                Button(action: onAddFile) {
                    Label("Add file…", systemImage: "doc.badge.plus")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .help("Attach a file as a reference")
            }

            if features.clipboardReferenceEnabled {
                Button(action: onAddClipboard) {
                    Label("Add from clipboard", systemImage: "doc.on.clipboard")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .help("Attach the current clipboard contents as a reference")
            }

            Spacer()

            // "Pick by clicking" is always shown — it is the picker's
            // primary purpose. referenceWindowsEnabled=false already
            // prevents the picker from opening at all, so if we're
            // here, window-capture is permitted.
            Button(action: onPickByClicking) {
                Label("Pick by clicking on screen", systemImage: "cursorarrow.rays")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
            .help("Hide the picker and click on any visible window to attach it. Press Esc to cancel.")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.needsPermission {
            permissionState
        } else if model.entries.isEmpty && model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 28)
        } else if let error = model.error {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .padding(14)
        } else if model.entries.isEmpty {
            Text("No windows available.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(14)
        } else {
            entryGrid
        }
    }

    private var permissionState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screen Recording permission required")
                .font(.system(size: 12, weight: .medium))
            Text("Parleq needs Screen Recording to capture window content as a reference. Captured pixels stay on your device until you accept; only then is the OCR'd text sent to your configured LLM.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Open System Settings") {
                    Permissions.openScreenRecordingSettings()
                }
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(14)
    }

    /// Min/max bounds + spacing for the adaptive grid. Hoisted to
    /// constants so the keyboard-nav column-count calculation uses
    /// the exact same numbers as the grid layout — otherwise drift
    /// would silently break Up/Down arrow distances.
    private static let gridItemMin: CGFloat = 280
    private static let gridItemMax: CGFloat = 420
    private static let gridSpacing: CGFloat = 14

    private var entryGrid: some View {
        ScrollView {
            // `.adaptive` chooses the column count based on available
            // width — 2 cols in a narrow window, more in a wider one.
            // Minimum bumped from 240→280 in PR C: with the larger
            // default picker size (screen-relative, ~70% of visible
            // frame), the old floor made wide pickers add columns
            // rather than giving each thumbnail more visual weight.
            // The maximum bump (360→420) gives a single card more
            // room before SwiftUI inserts another column.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.gridItemMin,
                                             maximum: Self.gridItemMax),
                                   spacing: Self.gridSpacing)],
                spacing: Self.gridSpacing
            ) {
                ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                    WindowThumbnailCard(
                        entry: entry,
                        thumbnail: model.thumbnails[entry.windowID],
                        isSelected: model.selectedIndex == index,
                        onPick: { onPick(entry) }
                    )
                }
            }
            .padding(16)
            // Measure the GRID width (not per-card y) and compute
            // columnCount from the same SwiftUI formula used by
            // `.adaptive` GridItem: N = floor((width + spacing) /
            // (minimum + spacing)). This avoids the per-card y-row
            // detection that was unreliable when SwiftUI's adaptive
            // grid wrapped in ways the user didn't visually expect
            // (e.g. wide screen with N+M entries packing as one row
            // visually but laid out as two rows internally with
            // identical minYs differing by <2pt).
            .background(
                GeometryReader { gridGeo in
                    Color.clear.preference(
                        key: GridWidthPreferenceKey.self,
                        value: gridGeo.size.width
                    )
                }
            )
            .onPreferenceChange(GridWidthPreferenceKey.self) { width in
                // 32pt accounts for the .padding(16) on each side
                // applied above. spacing cancels in the formula
                // numerator + denominator (one fewer spacing than
                // columns), giving the floor expression below.
                let usable = max(0, width - 32)
                let computed = Int(floor((usable + Self.gridSpacing) /
                                         (Self.gridItemMin + Self.gridSpacing)))
                let clamped = max(1, min(computed, model.entries.count))
                if model.columnCount != clamped {
                    model.columnCount = clamped
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Live grid-content width, reported by a GeometryReader attached to
/// the LazyVGrid. Used to compute the column count deterministically
/// from the same formula SwiftUI's `.adaptive` GridItem uses, rather
/// than measuring per-card y positions (which can be ambiguous when
/// rows have identical minYs within sub-pixel jitter).
private struct GridWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > value { value = next }
    }
}

/// One window's card in the grid: thumbnail (or placeholder while
/// capturing) on top, app icon + name + title underneath.
private struct WindowThumbnailCard: View {
    let entry: WindowPickerModel.Entry
    let thumbnail: NSImage?
    /// True when this card is the keyboard-selected entry. Drives a
    /// stronger accent ring so the user can see what Enter will pick
    /// without having to hover. Independent of hovering — hover and
    /// keyboard-select can both be true simultaneously, and the
    /// keyboard selection wins visually.
    let isSelected: Bool
    let onPick: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 6) {
                thumbnailArea
                metadata
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(entry.appName) — \(entry.title) as reference")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering = $0 }
    }

    /// Border color + width — keyboard-selected wins over hover,
    /// hover over default. Centralized so the two callers (background
    /// stroke + thumbnail outline) stay visually consistent.
    private var borderColor: Color {
        if isSelected { return Color.accentColor }
        if hovering { return Color.accentColor.opacity(0.7) }
        return Color.secondary.opacity(0.25)
    }
    private var borderWidth: CGFloat {
        if isSelected { return 2.5 }
        if hovering { return 2 }
        return 1
    }

    private var thumbnailArea: some View {
        ZStack {
            // Background frame + border keeps cards uniform even
            // while thumbnails are still capturing. The Liquid Glass
            // styling routes through .parleqPanelBackground when
            // available; we keep this minimal solid fallback for the
            // placeholder phase before the thumbnail arrives.
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(borderColor, lineWidth: borderWidth)
                )

            if let thumbnail = thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .padding(2)
            } else {
                // Placeholder while the SCK capture runs. Big-app-icon
                // gives the user something recognizable instantly.
                VStack(spacing: 6) {
                    if let icon = entry.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                            .opacity(0.7)
                    }
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .frame(height: 165)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if let icon = entry.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.appName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if entry.title != entry.appName {
                    Text(entry.title)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }
}
