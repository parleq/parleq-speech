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

    private let window: NSPanel
    private let hostingController: NSHostingController<WindowPickerView>
    private let model = WindowPickerModel()

    private static let defaultSize = NSSize(width: 900, height: 650)
    private static let minSize = NSSize(width: 520, height: 380)

    override init() {
        let initialFrame = NSRect(
            x: 0, y: 0,
            width: Self.defaultSize.width,
            height: Self.defaultSize.height
        )
        // NSPanel rather than NSWindow so we get the .nonactivating
        // option — opening the picker doesn't yank focus away from
        // the destination app, which matters because the overlay's
        // paste-target tracking observes that focus.
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Pick a window as reference"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .visible
        panel.minSize = Self.minSize
        panel.isReleasedWhenClosed = false
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
        panel.contentViewController = hc
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
    }

    /// Show the picker, centering on the active screen if it's not
    /// already visible. Refreshes the window list + thumbnails on
    /// every show so the picker never displays stale content across
    /// hide/show cycles (the hosting controller keeps the SwiftUI
    /// view alive between appearances, so .onAppear alone isn't
    /// sufficient).
    func show() {
        if !window.isVisible {
            window.center()
        }
        // makeKeyAndOrderFront pulls Parleq into the foreground so
        // keyboard events (Esc to dismiss) work. The .nonactivating
        // style mask keeps this from stealing focus from the
        // destination app's text field for paste-target purposes.
        window.makeKeyAndOrderFront(nil)
        // Refresh after makeKeyAndOrderFront — by this point the
        // window is on-screen and the view is live, so @Published
        // changes will drive immediate UI updates.
        model.refresh()
    }

    func hide() {
        window.orderOut(nil)
    }

    var isVisible: Bool { window.isVisible }
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
