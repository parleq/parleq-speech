// RecordingPulseWindow — a tiny, near-transparent floating pulse shown
// while a *quick* (double-tap-hold) dictation is recording.
//
// Quick mode is fire-and-forget: the full preview/refine overlay never
// appears, so the only in-the-moment "you're being recorded" cue is the
// start sound — useless to anyone who runs with acoustic feedback off.
// This panel fills that gap with a purely-visual signal: Parleq's brand
// bar mark (the same `ParleqListeningIndicator` the overlay uses) on an
// otherwise invisible window — the static Parleq logo at rest, a
// level-reactive waveform as you speak. It's informational only — no
// chrome, no titlebar, never takes focus, never intercepts clicks.
//
// Lifecycle is driven entirely by AppState (show on quick-mode
// `.capturing`, hide on every other phase); this type just owns the
// panel + view and exposes idempotent show()/hide()/setLevel().

import AppKit
import SwiftUI

@MainActor
public final class RecordingPulseWindow {
    private let panel: NSPanel
    private let model = RecordingPulseModel()
    private static let side: CGFloat = 96

    public init() {
        let size = NSSize(width: Self.side, height: Self.side)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            // Same recipe as OverlayWindow's panel: borderless +
            // non-activating so summoning it never pulls focus from the
            // app you're dictating into.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // statusBar level keeps the pulse above ordinary app windows;
        // canJoinAllSpaces so it shows even when you're dictating into a
        // full-screen-Space app. ignoresCycle keeps it out of ⌘`.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Purely informational — must never swallow a click meant for
        // whatever is underneath it.
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: RecordingPulseView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
    }

    /// Show the pulse (idempotent). Re-positions to the active screen
    /// each time so it follows the user across displays/Spaces.
    public func show() {
        guard !panel.isVisible else { return }
        positionBottomCenter()
        // orderFrontRegardless shows without activating Parleq — the
        // panel is .nonactivatingPanel so focus stays put.
        panel.orderFrontRegardless()
    }

    /// Hide the pulse (idempotent).
    public func hide() {
        guard panel.isVisible else { return }
        model.level = 0
        panel.orderOut(nil)
    }

    /// Feed the normalized mic level (0…1) so the bars react to the
    /// user's voice. No-op while hidden.
    public func setLevel(_ value: Float) {
        guard panel.isVisible else { return }
        model.level = min(1, max(0, value))
    }

    private func positionBottomCenter() {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let s = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - s.width / 2,
            y: visible.minY + 80   // a little above the bottom edge
        ))
    }
}

@MainActor
final class RecordingPulseModel: ObservableObject {
    /// Latest normalized mic level (0…1). Drives the bar heights.
    @Published var level: Float = 0
}

/// The visual: Parleq's own brand mark — five amber bars that sit as
/// the static Parleq logo at rest and morph into a level-reactive
/// waveform as you speak. This is the *same* `ParleqListeningIndicator`
/// the in-overlay listening view uses, so quick-mode dictation feedback
/// is visually identical to normal-mode capture. A soft shadow keeps
/// the amber bars legible over arbitrary on-screen content without a
/// solid backdrop (staying "almost entirely transparent").
struct RecordingPulseView: View {
    @ObservedObject var model: RecordingPulseModel

    var body: some View {
        ParleqListeningIndicator(level: model.level, scale: 2.6)
            .shadow(color: .black.opacity(0.35), radius: 5)
            .frame(width: 96, height: 96)
            .accessibilityLabel("Recording")
    }
}
