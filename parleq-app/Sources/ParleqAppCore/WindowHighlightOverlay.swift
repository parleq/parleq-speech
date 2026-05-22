// WindowHighlightOverlay — one transparent NSPanel per NSScreen,
// drawing an orange rounded-rect border around the on-screen
// window under the cursor. Active only while OverlayModel's
// isPickingWindow flag is true.
//
// Hit-test: CGWindowListCopyWindowInfo gives the on-screen window
// stack in front-to-back order. We pick the topmost layer-0
// (kCGNormalWindowLevel) window whose owning PID isn't Parleq AND
// whose bounds contain the cursor.
//
// Coordinate systems: CGWindow rects use macOS's older top-left-
// origin space (y=0 is the TOP of the primary display). NSEvent.
// mouseLocation uses Cocoa's bottom-left-origin space (y=0 is the
// BOTTOM of the primary display). cocoaRect(fromCGWindow:) handles
// the single flip; everything else in this file stays in Cocoa
// coords to match AppKit's panel/screen APIs.

import AppKit

@MainActor
public final class WindowHighlightOverlay {
    private var panels: [NSPanel] = []
    private var mouseMonitor: Any?
    private var activeTarget: HitResult?
    private let ownPID: Int32 = ProcessInfo.processInfo.processIdentifier

    public struct HitResult: Equatable {
        public let windowID: CGWindowID
        /// Window bounds in CGWindow space (top-left origin, global).
        public let bounds: CGRect
        /// Application name (from kCGWindowOwnerName), used as the
        /// display title passed to captureWindow so the chip label
        /// matches what the user hovered over.
        public let appName: String
    }

    public init() {}

    // MARK: - Lifecycle

    public func activate() {
        deactivate()
        for screen in NSScreen.screens {
            let panel = makePanel(for: screen)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        // Global mouse-move monitor — fires regardless of which app is active.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.updateHover() }
        }
        // Paint immediately at current cursor position before the first
        // mouseMoved event arrives.
        updateHover()
    }

    public func deactivate() {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        activeTarget = nil
    }

    /// Snapshot of the current hover target — AppState reads this at
    /// click-time to know which window the user clicked.
    public var currentTarget: HitResult? { activeTarget }

    // MARK: - Panel construction

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = HighlightView()
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.screenFrame = screen.frame
        panel.contentView = view
        return panel
    }

    // MARK: - Hover tracking

    private func updateHover() {
        // NSEvent.mouseLocation is in Cocoa (bottom-left-origin) coords.
        let cursor = NSEvent.mouseLocation
        let hit = topWindow(at: cursor)
        setActive(hit)
    }

    private func setActive(_ hit: HitResult?) {
        guard hit != activeTarget else { return }
        activeTarget = hit
        for panel in panels {
            guard let view = panel.contentView as? HighlightView,
                  let screenFrame = view.screenFrame else { continue }
            if let hit {
                let cocoaBounds = cocoaRect(fromCGWindow: hit.bounds)
                // Only light up the panel whose screen contains the window.
                if screenFrame.intersects(cocoaBounds) {
                    view.setHighlight(boundsInCocoa: cocoaBounds)
                } else {
                    view.setHighlight(boundsInCocoa: nil)
                }
            } else {
                view.setHighlight(boundsInCocoa: nil)
            }
        }
    }

    /// Returns the topmost on-screen window at `cursor` (Cocoa coords)
    /// whose layer == 0 (kCGNormalWindowLevel) and whose owning PID
    /// isn't our own process.
    private func topWindow(at cursor: CGPoint) -> HitResult? {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in raw {
            guard
                let pid = info[kCGWindowOwnerPID as String] as? Int32,
                pid != ownPID,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                let id = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }

            let cocoaBounds = cocoaRect(fromCGWindow: cgRect)
            if cocoaBounds.contains(cursor) {
                let appName = (info[kCGWindowOwnerName as String] as? String) ?? "Unknown"
                return HitResult(windowID: id, bounds: cgRect, appName: appName)
            }
        }
        return nil
    }

    // MARK: - Coordinate conversion

    /// Convert CGWindow-space rect (top-left origin) to Cocoa-space
    /// (bottom-left origin) by flipping Y around the primary screen's
    /// full height. CGWindowListCopyWindowInfo always uses the primary
    /// screen height as the reference for its Y axis.
    private func cocoaRect(fromCGWindow cgRect: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: cgRect.minX,
            y: mainHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}

// MARK: - HighlightView

private final class HighlightView: NSView {
    /// The screen frame this view covers, in global Cocoa (bottom-left)
    /// coordinates. Set once at panel creation time.
    fileprivate var screenFrame: NSRect?
    /// The window rect to highlight, in global Cocoa coordinates.
    private var highlight: NSRect?

    /// Update the highlighted window bounds (global Cocoa coords) and
    /// trigger a redraw.
    fileprivate func setHighlight(boundsInCocoa rect: NSRect?) {
        guard let screenFrame = screenFrame else {
            highlight = nil
            needsDisplay = true
            return
        }
        if let r = rect {
            // Translate from global Cocoa coords to view-local coords.
            // The view's origin is at screenFrame.origin in global space.
            highlight = NSRect(
                x: r.minX - screenFrame.minX,
                y: r.minY - screenFrame.minY,
                width: r.width,
                height: r.height
            )
        } else {
            highlight = nil
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let h = highlight else { return }
        let inset = h.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        // Parleq brand orange (#D97706).
        NSColor(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x06 / 255.0, alpha: 1.0).setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}
