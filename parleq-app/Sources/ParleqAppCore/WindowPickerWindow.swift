// WindowPickerWindow — free-floating titled window that hosts the
// thumbnail grid picker. Lifted out of an NSPopover so the grid has
// room to actually breathe: ~900×650 default, resizable, centered on
// screen, floats above other apps and crosses Spaces / full-screen
// apps like Parleq's main overlay does.
//
// Lifecycle:
//   - AppState constructs one instance at startup.
//   - The overlay's + button fires onShowWindowPicker → show() opens
//     the window and triggers a fresh refresh of the picker model.
//   - Clicking a thumbnail fires onPick(entry) and the window hides.
//   - Esc closes the window without picking; ⌘W and the close button
//     do the same.
//
// The picker isn't bound to a particular dictation session — it's a
// general "browse windows" sheet. AppState routes the pick into the
// active session's capture pipeline.

import AppKit
import SwiftUI

@MainActor
final class WindowPickerWindow: NSObject {
    /// Fired when the user picks a window from the grid. Caller is
    /// responsible for hiding the window (via `hide()`) and routing
    /// the entry into the capture pipeline.
    var onPick: ((WindowPickerModel.Entry) -> Void)?
    var onAddFile: (() -> Void)?
    var onAddClipboard: (() -> Void)?
    var onPickByClicking: (() -> Void)?
    /// Fires whenever the panel closes via a native path (title-bar
    /// close button, Esc, Cmd-W) that isn't one of the explicit
    /// callback actions above. Lets the latched-compose state
    /// machine in AppState transition .pickerOpen → .latched even
    /// when the user dismisses the picker without selecting
    /// anything. Crucially does NOT fire when our own `hide()`
    /// runs — that uses `orderOut` which doesn't trigger
    /// windowWillClose, so the explicit callback paths handle
    /// their own transitions without double-firing here.
    var onDismiss: (() -> Void)?

    private let window: KeyboardNavigablePanel
    private let hostingController: NSHostingController<WindowPickerView>
    private let model = WindowPickerModel()

    /// Floor for the panel. Below this the grid loses its visual
    /// authority and the action buttons start to crowd. Same as the
    /// pre-PR-C value.
    private static let minSize = NSSize(width: 520, height: 380)
    /// Ceiling for the panel. A giant external display (32"+ at
    /// scaled resolutions) would otherwise generate an absurdly
    /// large picker that wastes screen real estate for a 30-window
    /// grid.
    private static let maxSize = NSSize(width: 1400, height: 950)
    /// Fraction of the active screen's visible frame to target on
    /// first show. 0.70 keeps the picker feeling substantial on
    /// laptop displays while leaving enough surrounding context
    /// (other windows, menu bar) visible for the user to anchor
    /// against. Clamped to [minSize, maxSize].
    private static let defaultScreenFraction: CGFloat = 0.70
    /// NSPanel frame autosave key. macOS persists the user's last
    /// chosen size + position under this key in defaults, so power
    /// users who resize/move the picker once don't have to re-fiddle
    /// every session. Independent of the default-size computation —
    /// the autosave restore takes precedence when a saved frame
    /// exists.
    private static let frameAutosaveName = "ParleqWindowPicker"

    /// Compute the initial picker size for the screen the user is
    /// currently working on. Used only on the first show before
    /// the panel acquires its autosaved frame.
    private static func defaultInitialFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetW = max(
            minSize.width,
            min(maxSize.width, visible.width * defaultScreenFraction)
        )
        let targetH = max(
            minSize.height,
            min(maxSize.height, visible.height * defaultScreenFraction)
        )
        return NSRect(
            x: visible.midX - targetW / 2,
            y: visible.midY - targetH / 2,
            width: targetW,
            height: targetH
        )
    }

    override init() {
        let initialFrame = Self.defaultInitialFrame()
        // NSPanel rather than NSWindow so we get the .nonactivating
        // option — opening the picker doesn't yank focus away from
        // the destination app, which matters because the overlay's
        // paste-target tracking observes that focus.
        //
        // Subclass to KeyboardNavigablePanel so arrow keys + Enter
        // translate into model selection moves + onPick fires
        // without requiring focus to land on any specific SwiftUI
        // view inside the hosting controller. Subclass owns the
        // model reference so the keyDown override can read live
        // entries / columnCount.
        let panel = KeyboardNavigablePanel(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.pickerModel = model
        panel.title = "Pick a window as reference"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .visible
        panel.minSize = Self.minSize
        panel.maxSize = Self.maxSize
        panel.isReleasedWhenClosed = false
        // Persist the user's size + position across launches. When a
        // saved frame exists, AppKit applies it AFTER this init's
        // contentRect, so the autosaved frame wins over the computed
        // default — which is the right behavior (user customization
        // is more authoritative than our heuristic).
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        // Float above ordinary windows (so the picker is visible when
        // launched while another app is frontmost), and join all
        // Spaces / overlay full-screen apps like Parleq's overlay does.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        // Seed the SwiftUI rootView with no-op stubs; replaced by
        // setCallbacks() after init.
        let hc = NSHostingController(
            rootView: WindowPickerView(
                model: model,
                onPick: { _ in },
                onAddFile: {},
                onAddClipboard: {},
                onPickByClicking: {}
            )
        )
        self.hostingController = hc
        self.window = panel
        super.init()
        // Use `contentView` (the bare NSView) rather than
        // `contentViewController`. The latter makes NSWindow
        // auto-track the hosting controller's preferredContentSize,
        // which for a list-of-windows SwiftUI view can collapse to
        // the row's intrinsic minimum on first show — shrinking the
        // panel to minSize and overriding our screen-relative
        // contentRect. Setting `contentView` directly keeps the
        // panel sized to whatever we passed at init / via setFrame
        // and lets the SwiftUI view fill the available space via
        // its own `.frame(maxWidth: .infinity, maxHeight: .infinity)`
        // modifier on entryGrid. Matches the pattern OverlayWindow
        // uses for the same reason (see comment block there).
        panel.contentView = hc.view
        hc.view.frame = NSRect(origin: .zero, size: panel.contentLayoutRect.size)
        hc.view.autoresizingMask = [.width, .height]
        panel.delegate = self
    }

    /// Wire all four callbacks. Called once after init by AppState.
    /// Rebuilds the SwiftUI root view so closures capture the latest
    /// handler assignments.
    func setCallbacks(
        onPick: @escaping (WindowPickerModel.Entry) -> Void,
        onAddFile: @escaping () -> Void,
        onAddClipboard: @escaping () -> Void,
        onPickByClicking: @escaping () -> Void
    ) {
        self.onPick = onPick
        self.onAddFile = onAddFile
        self.onAddClipboard = onAddClipboard
        self.onPickByClicking = onPickByClicking
        hostingController.rootView = WindowPickerView(
            model: model,
            onPick: { [weak self] entry in self?.onPick?(entry) },
            onAddFile: { [weak self] in self?.onAddFile?() },
            onAddClipboard: { [weak self] in self?.onAddClipboard?() },
            onPickByClicking: { [weak self] in self?.onPickByClicking?() }
        )
        // Route Enter-on-selected through the same onPick callback so
        // mouse-click and keyboard-pick paths are indistinguishable
        // downstream — the AppState handler doesn't need to know which
        // input device the user used.
        window.onPickSelected = { [weak self] entry in self?.onPick?(entry) }
    }

    /// Show the picker. The frame is restored from autosave on first
    /// show within a session; subsequent show()s after a hide() reuse
    /// the in-memory frame so the user doesn't see the picker jump
    /// back to default if they moved it mid-session. Refreshes the
    /// window list + thumbnails on every show so the picker never
    /// displays stale content across hide/show cycles (the hosting
    /// controller keeps the SwiftUI view alive between appearances,
    /// so .onAppear alone isn't sufficient).
    func show() {
        // Don't call window.center() unconditionally — that would
        // override both the autosaved frame and any user repositioning
        // from this session. If a saved frame exists, AppKit's
        // frameAutosaveName handling has already restored it by the
        // time we reach here. Only re-center if the panel has somehow
        // ended up offscreen (e.g. external display unplugged since
        // the last save) so it remains reachable.
        if !window.isVisible, isFrameOffscreen() {
            window.center()
        }
        // makeKeyAndOrderFront pulls Parleq into the foreground so
        // keyboard events (Esc to dismiss) work. The .nonactivating
        // style mask keeps this from stealing focus from the
        // destination app's text field for paste-target purposes.
        window.makeKeyAndOrderFront(nil)
        // Reset the keyboard selection on every show so the user
        // doesn't see a stale highlight from a previous session.
        // Refresh will populate entries before the user has a chance
        // to react; first arrow press jumps to index 0.
        model.selectedIndex = nil
        // Refresh after makeKeyAndOrderFront — by this point the
        // window is on-screen and the view is live, so @Published
        // changes will drive immediate UI updates.
        model.refresh()
    }

    func hide() {
        window.orderOut(nil)
    }

    var isVisible: Bool { window.isVisible }

    /// Returns true when the panel's frame doesn't intersect any
    /// currently-attached screen — typical after an external display
    /// has been unplugged since the autosaved frame was written.
    /// Used by show() to decide whether to re-center; a centered
    /// fallback is far better than an invisible picker.
    private func isFrameOffscreen() -> Bool {
        let frame = window.frame
        for screen in NSScreen.screens where screen.visibleFrame.intersects(frame) {
            return false
        }
        return true
    }
}

// MARK: - NSWindowDelegate
//
// Fires onDismiss for native close paths (title-bar close button,
// Esc, Cmd-W). Our own hide() uses orderOut and does NOT fire
// windowWillClose, so the explicit picker-action callbacks
// (onPick, onAddFile, etc.) keep handling their own state
// transitions through AppState.dismissPicker() without
// double-firing here.

extension WindowPickerWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onDismiss?()
    }
}

// MARK: - Keyboard navigation
//
// KeyboardNavigablePanel handles arrow keys + Enter at the NSPanel
// level so the focused SwiftUI view inside the hosting controller
// doesn't have to. The model owns the selection state (selectedIndex
// + columnCount); this subclass mutates it in response to keyDown
// and routes Enter through to onPickSelected, which the
// WindowPickerWindow wires to its onPick callback.
//
// Left/Right move the selection by 1 entry, clamping at the edges
// (last entry's Right is a no-op, first entry's Left is a no-op —
// wrapping past the ends felt jarring in a finite picker grid).
// Up/Down move by columnCount, also clamping at top / bottom rows.
// Enter activates the selected entry. All other keys (Esc, Tab,
// printable characters) fall through to AppKit's default handling,
// which preserves Esc-to-close and any system shortcuts.

@MainActor
final class KeyboardNavigablePanel: NSPanel {
    weak var pickerModel: WindowPickerModel?
    var onPickSelected: ((WindowPickerModel.Entry) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Handle Cmd-W locally. Parleq is LSUIElement (accessory app)
    /// and installs only the App + Edit submenus — there's no File →
    /// Close menu item, so the standard Cmd-W → menu command →
    /// performClose dispatch doesn't run. Catching it here at the
    /// panel level gives the picker the close-shortcut affordance
    /// users expect from any macOS window without polluting the
    /// app-wide main menu with a File submenu that would otherwise
    /// be empty. performClose(nil) goes through the standard close
    /// path (windowShouldClose → windowWillClose) so onDismiss fires
    /// the same as Esc / close-button / external orderOut.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let model = pickerModel else {
            super.keyDown(with: event)
            return
        }
        let entries = model.entries
        if entries.isEmpty {
            super.keyDown(with: event)
            return
        }
        let columns = max(1, model.columnCount)
        // Normalize selectedIndex against the live entries list before
        // applying arrow movement. If a refresh shrank the list (e.g.
        // user closed the previously-selected window) the stored
        // index could be out of range — left unhandled, arrow keys
        // would compute moves relative to a stale position and Enter
        // would silently fall back to entries[0]. Clamping here keeps
        // the post-refresh keyboard experience predictable.
        let current: Int
        if let stored = model.selectedIndex, entries.indices.contains(stored) {
            current = stored
        } else {
            current = -1
            if model.selectedIndex != nil {
                model.selectedIndex = nil
            }
        }
        // Treat .keyCode arrow values explicitly. Using key.charactersIgnoringModifiers
        // would also work for arrow keys (they have well-known unicode
        // values) but keyCode is what NSResponder typically dispatches
        // on and matches the style of the hotkey listener.
        switch Int(event.keyCode) {
        case 123: // Left arrow
            let next = current < 0 ? 0 : max(0, current - 1)
            model.selectedIndex = next
        case 124: // Right arrow
            let next = current < 0 ? 0 : min(entries.count - 1, current + 1)
            model.selectedIndex = next
        case 125: // Down arrow
            let next: Int
            if current < 0 {
                next = 0
            } else {
                let candidate = current + columns
                next = candidate < entries.count ? candidate : current
            }
            model.selectedIndex = next
        case 126: // Up arrow
            let next: Int
            if current < 0 {
                next = 0
            } else {
                let candidate = current - columns
                next = candidate >= 0 ? candidate : current
            }
            model.selectedIndex = next
        case 36, 76: // Return, Enter (numpad)
            if let idx = model.selectedIndex, entries.indices.contains(idx) {
                onPickSelected?(entries[idx])
            } else {
                // Enter with no selection picks the first entry. Lets
                // the user open the picker → Enter as a one-handed
                // "I want the first thing offered" shortcut without
                // having to press an arrow key first.
                onPickSelected?(entries[0])
            }
        default:
            super.keyDown(with: event)
        }
    }
}
