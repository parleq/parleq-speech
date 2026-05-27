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
        let resolved = section ?? .recent
        if let existing = window, existing.isVisible {
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
        let w = ParleqAppNSWindow(contentViewController: hosting)
        w.title = "Parleq"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Minimum window size sized so the embedded SettingsView
        // (which declares its own minWidth: 860 + minHeight: 600,
        // see SettingsWindow.swift L938) is not clipped behind the
        // sidebar. ~200pt sidebar + 860pt detail + chrome = 1080;
        // round to 1100 for a touch of breathing room. PR 2's
        // restructured Settings (nested sub-sidebar replacing the
        // current horizontal tab list) will likely shrink the
        // detail width requirement; minSize can be revisited then.
        w.minSize = NSSize(width: 1100, height: 640)
        // Initial frame: 1140×740 centered, clamped to 70% of the
        // active screen's visible frame so we don't blow past small
        // laptop displays. Frame autosave overrides this on second
        // and subsequent launches if the user resized.
        let defaultSize = NSSize(
            width: max(1100, min(1140, (NSScreen.main?.visibleFrame.width ?? 1440) * 0.70)),
            height: max(640, min(740, (NSScreen.main?.visibleFrame.height ?? 900) * 0.70))
        )
        w.setContentSize(defaultSize)
        w.center()
        // setFrameAutosaveName persists size + position across
        // launches once the user resizes / moves. Independent of
        // the explicit `setContentSize` above — when a saved frame
        // exists, AppKit restores it after window creation, which
        // takes precedence.
        w.setFrameAutosaveName("ParleqApp")
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
}

/// Reference-typed wrapper around the selected-section state so the
/// SwiftUI ParleqAppView can bind to it without the controller
/// having to expose @Published. Updates propagate through the
/// passed binding; the box exists outside the view's lifecycle.
@MainActor
final class SectionBox: ObservableObject {
    @Published var value: ParleqAppSection

    init(value: ParleqAppSection) {
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
