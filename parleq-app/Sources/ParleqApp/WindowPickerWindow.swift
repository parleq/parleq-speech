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
final class WindowPickerWindow {
    /// Fired when the user picks a window from the grid. Caller is
    /// responsible for hiding the window (via `hide()`) and routing
    /// the entry into the capture pipeline.
    var onPick: ((WindowPickerModel.Entry) -> Void)?

    private let window: NSPanel
    private let hostingController: NSHostingController<WindowPickerView>

    private static let defaultSize = NSSize(width: 900, height: 650)
    private static let minSize = NSSize(width: 520, height: 380)

    init() {
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

        // Seed the SwiftUI rootView with a stub onPick; replaced
        // in setOnPick() below.
        let hc = NSHostingController(
            rootView: WindowPickerView { _ in /* set later */ }
        )
        self.hostingController = hc
        self.window = panel
        panel.contentViewController = hc
    }

    /// Wire the pick callback. Called once after init by AppState.
    func setOnPick(_ callback: @escaping (WindowPickerModel.Entry) -> Void) {
        onPick = callback
        // Rebuild rootView so the SwiftUI closure forwards to onPick.
        hostingController.rootView = WindowPickerView { [weak self] entry in
            self?.onPick?(entry)
        }
    }

    /// Show the picker, centering on the active screen if it's not
    /// already visible. Always triggers an `onAppear`-driven refresh
    /// in the view so the list reflects current windows.
    func show() {
        if !window.isVisible {
            window.center()
        }
        // makeKeyAndOrderFront pulls Parleq into the foreground so
        // keyboard events (Esc to dismiss) work. The .nonactivating
        // style mask keeps this from stealing focus from the
        // destination app's text field for paste-target purposes.
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }

    var isVisible: Bool { window.isVisible }
}
