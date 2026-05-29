// ParleqAppWindow — the main app window introduced in 0.14.0.
//
// Replaces the prior `SettingsWindowController`-as-the-only-real-
// window architecture with a proper NSWindow + NavigationSplitView
// sidebar app. Sidebar sections in display order:
//
//   1. Recent Dictations — landing page (rich history browser, PR 3).
//   2. Stats             — counters dashboard (PR 5).
//   3. Settings          — what used to live in SettingsWindow (PR 2
//                          restructures into a nested sub-sidebar).
//   4. About             — version, contributors, licenses (PR 1
//                          ships a minimal version stub; PR 7 absorbs
//                          the Licenses content from the menu bar).
//
// PR 1 (this file) wires the shell + section routing only; Recent /
// Stats / About surfaces are placeholders. The Settings section
// embeds the existing SettingsView directly so all current settings
// are still reachable. PR 2 restructures Settings; subsequent PRs
// flesh out Recent + Stats.
//
// Single-window app shell: `ParleqAppWindowController.shared.show()`
// creates the NSWindow on first call and brings it to front on
// subsequent calls. Frame autosave (`"ParleqApp"`) persists size
// and position across launches.

import AppKit
import SwiftUI

/// Sidebar destinations. Codable so we can persist the last-visited
/// section across launches (UserDefaults) if we want to in a later
/// PR; PR 1 just defaults to .recent on every show().
public enum ParleqAppSection: String, Hashable, Identifiable, CaseIterable {
    case recent
    case stats
    case settings
    case about

    public var id: String { rawValue }

    /// Display title in the sidebar.
    var title: String {
        switch self {
        case .recent:   return "Recent"
        case .stats:    return "Stats"
        case .settings: return "Settings"
        case .about:    return "About"
        }
    }

    /// SF Symbol for the sidebar row.
    var systemImage: String {
        switch self {
        case .recent:   return "clock.arrow.circlepath"
        case .stats:    return "chart.bar.fill"
        case .settings: return "gearshape"
        case .about:    return "info.circle"
        }
    }
}

/// Fine-grained sidebar selection for the 0.15.0 unified navigation.
/// The primary sidebar now folds the Settings sub-sections directly
/// in (no more secondary Settings sidebar), so the selection has to
/// distinguish which Settings pane is active. `ParleqAppSection`
/// stays the top-level identity for the `show(section:)` API + menu
/// items; this is what the sidebar List + SectionBox actually bind to.
enum ParleqAppSelection: Hashable {
    case recent
    case stats
    /// Usage (token + cost ledger) is a top-level section in 0.15.0,
    /// promoted out of the Settings sub-sections; it still renders via
    /// SettingsView(section: .usage) but is selected from the primary
    /// sidebar rather than under Settings.
    case usage
    case settings(SettingsView.SettingsSection)
    case about

    /// True for any Settings pane — used by the reload-on-navigate-in
    /// trigger that refreshes SettingsModel from disk.
    var isSettings: Bool {
        if case .settings = self { return true }
        return false
    }

    /// Map a top-level section to a concrete selection. `.settings`
    /// resolves to a specific pane (the supplied `settingsSection`,
    /// or Hotkey as the default landing).
    static func from(
        _ section: ParleqAppSection,
        settingsSection: SettingsView.SettingsSection = .hotkey
    ) -> ParleqAppSelection {
        switch section {
        case .recent:   return .recent
        case .stats:    return .stats
        case .settings: return .settings(settingsSection)
        case .about:    return .about
        }
    }
}

/// Manages the lifecycle of the main app window. Singleton because
/// there's only ever one Parleq app window (Parleq is LSUIElement —
/// no Dock icon, no multi-window app semantics; the window is the
/// app's surface when summoned, period).
@MainActor
public final class ParleqAppWindowController: NSObject {
    public static let shared = ParleqAppWindowController()

    /// The canonical SettingsModel for the running session. Owned
    /// here in 0.14.0+ (PR 1); previously lived inside
    /// SettingsWindowController, which PR 2 removes entirely. Held
    /// at the controller (not the SwiftUI view) so the same model
    /// instance survives window hide/show cycles and so external
    /// wiring (main.swift's reset-ASR closure) has a stable place
    /// to land independent of view lifecycle.
    /// Internal (not public) because SettingsModel itself is
    /// module-internal; the only cross-module need is the reset-ASR
    /// closure wiring which goes through `setOnResetASR(_:)`.
    let settingsModel = SettingsModel()

    /// The PasteTarget the user was working in when they summoned
    /// the app. PR 3 (#218) uses this for the Recent Dictations
    /// "Paste here" button — that button pastes into the app the
    /// user was pointing at when they opened Parleq, NOT into the
    /// Parleq window itself (which is frontmost while the user
    /// browses history). Snapshotted in `show()` BEFORE we call
    /// `makeKeyAndOrderFront`, when NSWorkspace's
    /// frontmostApplication still reports the user's prior
    /// context. nil when no usable target was captured (rare —
    /// Finder / Dock are the typical "nothing usable" cases).
    private(set) var priorFrontmostTarget: PasteTarget?

    private var window: NSWindow?

    private override init() {}

    /// Show the app window. Creates on first call; brings to front
    /// on subsequent calls. The optional `section` parameter lets
    /// callers deep-link to a specific sidebar section (e.g. a
    /// future "Open Settings" affordance can pass .settings); nil
    /// preserves whatever section was last visible (or defaults to
    /// .recent on first creation).
    public func show(section: ParleqAppSection? = nil) {
        // Snapshot the user's prior context BEFORE we yank focus.
        // NSWorkspace.frontmostApplication still reports the user's
        // previous app at this moment; after makeKeyAndOrderFront
        // (or even the implicit activation that NSStatusItem clicks
        // sometimes cause) Parleq becomes frontmost and the
        // information is lost. Used by the Recent Dictations
        // "Paste here" button to route into the previously-focused
        // app rather than into the Parleq window itself.
        //
        // Filter the captured target before assigning:
        //
        //  - usable target → store it (the common case)
        //  - Parleq itself → preserve the previous target. This
        //    handles the "re-open the app after closing the
        //    window" path where Parleq is briefly frontmost again
        //    before show() is called; clobbering with Parleq's
        //    own bundle ID would force "Paste here" to fall back
        //    to copy on a fresh session-resume.
        //  - any other unusable target (Finder, Dock, system UI,
        //    nil bundle ID) → clear. These signal the user came
        //    from a context with nothing to paste into; "Paste
        //    here" should fall back to copy via the nil-target
        //    branch in RecentDictationsView, not silently route
        //    into a stale target from a much earlier session.
        let captured = Paster.captureFrontmost()
        switch Self.classifyPasteTarget(captured) {
        case .usable(let target):
            priorFrontmostTarget = target
        case .selfReactivation:
            break // keep the previous target
        case .unusable:
            priorFrontmostTarget = nil
        }
        // Default to .recent on every show() unless the caller passes
        // an explicit section. This means: hotkey-open and menu-bar
        // "Show Parleq" always land on the Recent landing page;
        // restart-initiated reopen (which always passes section:
        // .settings) lands back on Settings. The previous behavior
        // (leave selectedSection unchanged) caused the surprising
        // case where a user who'd closed the window while on Settings
        // got Settings again on next hotkey open instead of the
        // landing page they expected.
        // Map the top-level section to a concrete selection. For
        // .settings, restore the last-visited Settings pane (persisted
        // by ParleqAppView under "parleq.settings.selection") so a
        // restart-initiated reopen lands where the user was, defaulting
        // to Hotkey.
        let topLevel = section ?? .recent
        let resolved: ParleqAppSelection
        if topLevel == .settings {
            let lastPane = SettingsView.SettingsSection(
                rawValue: UserDefaults.standard.string(forKey: "parleq.settings.selection") ?? ""
            ) ?? .hotkey
            resolved = .settings(lastPane)
        } else {
            resolved = ParleqAppSelection.from(topLevel)
        }
        // Reuse the existing window whether it's currently visible OR
        // was closed. `isReleasedWhenClosed = false` keeps the NSWindow
        // (and its NSHostingController + SwiftUI state) alive after a
        // Cmd-W / close, so re-summoning re-displays the SAME window —
        // preserving sidebar expand/collapse, column visibility, the
        // last-restored frame, etc. The previous `existing.isVisible`
        // guard fell through to the else-branch on reopen and rebuilt a
        // brand-new window, resetting all that state every time.
        if let existing = window {
            selectedSection.value = resolved
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        selectedSection.value = resolved
        let root = ParleqAppView(
            selectedSection: selectedSection,
            settingsModel: settingsModel
        )
        let hosting = NSHostingController(rootView: root)
        // Do NOT let SwiftUI content drive the window's size at all.
        //
        // [.preferredContentSize] auto-grew the window to fit tall
        // content (pushed it off small displays); [.minSize] tied the
        // window's minimum to the content's min, which had three bad
        // effects: (a) the minimum differed per pane (NavigationSplitView
        // under-reports its detail column's min, so the floor wobbled
        // as you navigated); (b) a per-pane `minHeight` on the detail
        // could exceed the window NavigationSplitView allowed, so the
        // pane overflowed and was center-clipped beyond scroll reach
        // (Stats); and (c) a per-pane `minWidth` made the window's
        // minimum width wobble between panes.
        //
        // With [] the window's min/initial size is OURS alone (set via
        // w.minSize + setContentSize below) — one consistent floor for
        // every pane, and the ScrollView panes always receive the true
        // viewport height so they scroll instead of clipping. w.minSize
        // prevents the collapse-to-nothing that [] alone (no explicit
        // floor) used to cause. #61.
        hosting.sizingOptions = []
        let w = ParleqAppNSWindow(contentViewController: hosting)
        w.title = "Parleq"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Visible frame of the active screen (excludes menu bar +
        // Dock) — the hard ceiling for default + min size so the
        // window never exceeds the usable area on small/low-res
        // displays.
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // One pane-independent floor for the unified 2-column layout.
        // Narrow enough to be comfortable on small displays but still
        // wide enough that, with the sidebar auto-hidden, the detail
        // pane clears the Settings content's readable width (~420pt) so
        // panes stay usable without horizontal scrolling. Clamp to the
        // visible frame so a genuinely tiny display can still satisfy
        // minSize (otherwise AppKit lets the window exceed the screen to
        // honor an impossible minimum).
        w.minSize = NSSize(
            width: min(520, visible.width),
            height: min(420, visible.height)
        )
        // Initial frame: ~1040×720, clamped to the visible frame so it
        // fits small displays. Frame autosave overrides this on later
        // launches; the restored frame is re-clamped below.
        let defaultSize = NSSize(
            width: max(w.minSize.width, min(1040, visible.width)),
            height: max(w.minSize.height, min(720, visible.height))
        )
        w.setContentSize(defaultSize)
        w.center()
        // setFrameAutosaveName persists size + position across
        // launches. When a saved frame exists AppKit restores it after
        // this call, taking precedence over setContentSize above.
        w.setFrameAutosaveName("ParleqApp")
        // Re-clamp whatever frame is now in effect (default or restored
        // autosave) so the window can never sit partly off-screen.
        // Clamp into the screen the frame MOST overlaps — NOT always the
        // primary. A frame validly autosaved on a still-connected
        // secondary display must stay there; only a frame whose display
        // is gone (saved on an external, reopened on the laptop alone)
        // falls back to the main screen. #61.
        let clampTarget = Self.visibleFrame(bestOverlapping: w.frame)
        w.setFrame(Self.clampFrame(w.frame, into: clampTarget), display: false)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary]
        w.makeKeyAndOrderFront(nil)
        // We're LSUIElement; activate so the window can receive
        // keyboard focus + show its title bar in the foreground.
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    /// Backing storage for the currently-selected sidebar section.
    /// Wrapped in a `@Observable`-ish box so SwiftUI bindings work
    /// without making the controller itself ObservableObject (which
    /// would tangle the public API with SwiftUI lifecycle concerns).
    /// Default is .recent — the landing page.
    private let selectedSection = SectionBox(value: .recent)

    /// System / launcher bundle IDs that signal "no useful paste
    /// target right now" — Finder, the Dock, status-bar helpers.
    /// Capturing one of these means clearing the prior target so
    /// Recent Dictations' "Paste here" falls back to clipboard.
    private static let unusableSystemBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.WindowManager",
        "com.apple.Spotlight",
        "com.apple.notificationcenterui",
    ]

    /// Parleq's own bundle ID. A capture matching this is a
    /// self-reactivation (re-opening the window after a close)
    /// and must NOT clobber the prior target — that would lose
    /// the context the user originally came from.
    private static let selfBundleID = "com.parleq.app"

    private enum PasteTargetClassification {
        case usable(PasteTarget)
        case selfReactivation
        case unusable
    }

    private static func classifyPasteTarget(_ target: PasteTarget?) -> PasteTargetClassification {
        guard let target, let bundleID = target.bundleID, !bundleID.isEmpty else {
            return .unusable
        }
        if bundleID == selfBundleID {
            return .selfReactivation
        }
        if unusableSystemBundleIDs.contains(bundleID) {
            return .unusable
        }
        return .usable(target)
    }

    /// Wire the bundled LocalASRClient's reset() handler. Called
    /// from `parleq-app/main.swift` at startup (only when the
    /// bundled ASR is active — for a custom asr.endpoint the closure
    /// stays nil and the Settings → Advanced "Reset speech model"
    /// button hides itself per the gate added in 0.13.0).
    public func setOnResetASR(_ handler: @escaping () -> Void) {
        settingsModel.onResetASR = handler
    }

    /// Programmatically close the app window. Used by Recent
    /// Dictations' "Paste here" flow — once the target app has the
    /// pasted text, the user typically wants Parleq's window to get
    /// out of the way so they can see + edit the paste in context.
    /// Routes through performClose so window-close hooks fire the
    /// same way as a title-bar close button click.
    public func close() {
        window?.performClose(nil)
    }

    /// `@objc` shim so the App main-menu's "About Parleq" item and
    /// the status-item dropdown can both route the canonical macOS
    /// "About" hit through the controller. Opens the app shell to
    /// the About section regardless of the window's current state.
    /// Previously this routed through `NSApp.orderFrontStandardAboutPanel`
    /// which showed the system about panel — replaced now that the
    /// app shell ships a richer About surface with brand mark,
    /// links, and the open-source licenses entry point.
    @objc public func presentAbout() {
        show(section: .about)
    }

    /// The `visibleFrame` of the screen the given frame most overlaps.
    /// Used to pick the clamp target so a window restored onto a
    /// still-connected secondary display stays on that display instead
    /// of being yanked back to the primary. Falls back to the main
    /// screen when the frame intersects no screen at all — i.e. its
    /// display was disconnected since the frame was autosaved (#61).
    static func visibleFrame(bestOverlapping frame: NSRect) -> NSRect {
        let fallback = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var best: NSRect?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let inter = screen.visibleFrame.intersection(frame)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = screen.visibleFrame
            }
        }
        return best ?? fallback
    }

    /// Clamp `frame` so it fits entirely within `bounds` (a screen's
    /// visibleFrame): shrink the size to the bounds, then shift the
    /// origin so no edge sits outside. Self-corrects a default or
    /// restored-autosave frame that would exceed a small/single
    /// display (#61).
    static func clampFrame(_ frame: NSRect, into bounds: NSRect) -> NSRect {
        var f = frame
        f.size.width = min(f.size.width, bounds.size.width)
        f.size.height = min(f.size.height, bounds.size.height)
        f.origin.x = min(max(f.origin.x, bounds.minX), bounds.maxX - f.size.width)
        f.origin.y = min(max(f.origin.y, bounds.minY), bounds.maxY - f.size.height)
        return f
    }

    /// `@objc` shim for the App main-menu's "Show Parleq…" entry —
    /// gives AppKit a no-arg selector to dispatch when the user hits
    /// Cmd-, while Parleq's window is frontmost. Without this entry,
    /// AppKit walks `NSApp.mainMenu` for a Cmd-, key-equivalent and
    /// finds nothing — even though the status-item dropdown also
    /// declares the same shortcut (status-item menus don't
    /// participate in global key-equivalent dispatch, so that
    /// declaration alone is insufficient).
    @objc public func presentShell() {
        show()
    }
}

/// Reference-typed wrapper around the selected-section state so the
/// SwiftUI ParleqAppView can bind to it without the controller
/// having to expose @Published. Updates propagate through the
/// passed binding; the box exists outside the view's lifecycle.
@MainActor
final class SectionBox: ObservableObject {
    @Published var value: ParleqAppSelection

    init(value: ParleqAppSelection) {
        self.value = value
    }
}

/// NSWindow subclass that handles Cmd-W locally. Parleq is
/// LSUIElement (accessory app, no Dock icon) and its main menu is
/// the minimal App + Edit pair installed in parleq-app/main.swift
/// — there's no File → Close menu item to route Cmd-W through.
/// Without this override, the standard close-window keyboard
/// shortcut is a dead key on the new app window, the same gap
/// `KeyboardNavigablePanel` closes for the WindowPickerWindow.
/// performClose(nil) goes through the standard close chain
/// (windowShouldClose → windowWillClose) so any cleanup hooks
/// see the close exactly as they would for the title-bar close
/// button.
@MainActor
final class ParleqAppNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
