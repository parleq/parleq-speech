// OverlayWindow — floating overlay panel that displays per-utterance
// state and captures Enter/Esc keys.
//
// Visual layer: SwiftUI hosted via NSHostingView. State-dependent
// content (capturing dots, streaming text, accept/cancel hint) is
// driven by an ObservableObject the panel owns.
//
// Window behavior:
//   - styleMask: [.borderless, .nonactivatingPanel] — no titlebar,
//     no focus-stealing on show.
//   - level: NSWindow.Level.popUpMenu — above ordinary windows but
//     below the menu bar; visible across all spaces.
//   - canBecomeKey overridden to true so keyDown delivers Enter/Esc
//     to us without first activating the app.
//
// Position: screen-bottom-center for v0.1. Cursor-following requires
// AX API queries on the focused app and is deferred to M5+.
//
// Visual styling is intentionally minimal for M3 — sensible defaults
// (system font, secondary background, rounded corners, default
// text color). Polish will land in M5 once we've used it for a few
// days and know what's worth tweaking.

import AppKit
import Combine
import SwiftUI

/// Visible state of the overlay. Driven by AppState transitions.
enum OverlayState: Sendable {
    /// Sidecar process isn't ready yet (model still loading, or in
    /// the middle of a crash + restart). Hotkey presses get a
    /// "please wait" message instead of being silently ignored or
    /// hanging on a black-hole capture.
    case initializing
    case capturing
    case cleaning
    case awaitingAccept
    case refining
}

@MainActor
final class OverlayWindow {
    /// Width is fixed; height grows with content, anchored to the
    /// bottom edge so it expands upward.
    private static let fixedWidth: CGFloat = 720
    /// Floor for the panel height — short utterances still get a
    /// stable shape while the partial transcript streams in.
    private static let minHeight: CGFloat = 140
    /// Cap on the transcript area as a fraction of screen height.
    /// Above this, SwiftUI clips the TOP of older text and keeps
    /// the latest text visible at the bottom of the content area
    /// (just above the indicator dots / footer).
    private static let maxContentHeightScreenFraction: CGFloat = 0.5

    private let panel: OverlayPanel
    private let model: OverlayModel
    private let hostingController: NSHostingController<OverlayContent>
    private var sizeObservation: NSKeyValueObservation?
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        let initialFrame = NSRect(
            x: 0, y: 0,
            width: OverlayWindow.fixedWidth,
            height: OverlayWindow.minHeight
        )
        let panel = OverlayPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let model = OverlayModel()
        self.panel = panel
        self.model = model

        // NSHostingController with sizingOptions = .preferredContentSize
        // means SwiftUI's intrinsic content height is reported as the
        // controller's preferredContentSize. We KVO that and resize
        // the panel to match. This is what lets the overlay grow when
        // the transcript wraps to many lines.
        //
        // Pass maxContentHeight to the SwiftUI side so it can cap the
        // transcript area (and bottom-align/clip when it overflows),
        // ensuring the latest text always stays visible just above
        // the footer.
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let maxContentHeight = screenHeight * OverlayWindow.maxContentHeightScreenFraction
        let hc = NSHostingController(
            rootView: OverlayContent(
                model: model,
                width: OverlayWindow.fixedWidth,
                maxContentHeight: maxContentHeight
            )
        )
        hc.sizingOptions = [.preferredContentSize]
        self.hostingController = hc
        panel.contentViewController = hc

        // Wire the panel's key-handler hooks to the closures on this
        // class (which AppState fills in via onAccept/onCancel).
        panel.onEnter = { [weak self] in self?.onAccept?() }
        panel.onEscape = { [weak self] in self?.onCancel?() }

        sizeObservation = hc.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            // KVO callbacks run on whatever thread updated the
            // property; SwiftUI on macOS updates this on main, but
            // hop explicitly to be safe.
            Task { @MainActor in self?.resizePanelToFitContent() }
        }
    }

    /// Show / update the overlay. Called on every state transition;
    /// the panel may already be visible, in which case we just update
    /// the model.
    ///
    /// `downloadProgress` is only consulted in the `.initializing`
    /// state; other states ignore it. AppState passes the latest
    /// `LocalASR.downloadProgress` snapshot so the init overlay can
    /// render a real progress bar — and `notifyDownloadProgress`
    /// calls `show(.initializing, …)` again with the same state but
    /// a new snapshot to live-update while bytes are streaming in.
    ///
    /// `microphoneName` is only consulted in the `.capturing` state;
    /// other states ignore it. AppState resolves the active mic via
    /// `effectiveMicrophoneName(forExplicitUID:)` and passes the
    /// result so the overlay can render "listening on <Mic>…"
    /// inline. nil = fall back to the plain "listening…" text.
    func show(
        state: OverlayState,
        text: String,
        downloadProgress: ASRDownloadProgress? = nil,
        microphoneName: String? = nil
    ) {
        model.update(
            state: state,
            text: text,
            downloadProgress: downloadProgress,
            microphoneName: microphoneName
        )
        if !panel.isVisible {
            positionAtScreenBottom()
            panel.orderFrontRegardless()
            // makeKey delivers keyDown events to the panel without
            // activating our app (we're a .nonactivatingPanel).
            panel.makeKey()
        }
    }

    /// Enforce the minHeight floor on the panel.
    ///
    /// NSWindow auto-tracks contentViewController.preferredContentSize,
    /// so the panel's height already matches SwiftUI's intrinsic
    /// height after the auto-track runs. We just need to bump it up
    /// to minHeight when the content would be smaller. Position is
    /// handled by OverlayPanel.setFrame's anchor override; the
    /// transcript-area cap is enforced inside SwiftUI (see
    /// OverlayContent.maxContentHeight).
    private func resizePanelToFitContent() {
        let preferred = hostingController.preferredContentSize
        let target = max(OverlayWindow.minHeight, preferred.height)
        var frame = panel.frame
        if abs(frame.size.height - target) < 0.5 { return }
        frame.size.height = target
        panel.setFrame(frame, display: true, animate: false)
    }

    /// Append a chunk of text to the overlay. Used by the streaming
    /// LLM client (M4) so the visible text grows incrementally.
    func appendText(_ chunk: String) {
        model.append(chunk)
    }

    /// Push a normalized 0…1 mic level into the overlay so the
    /// .capturing state's sound-wave bars can animate. Cheap no-op
    /// in any other state — the bars view only renders during
    /// capture, but the published value still updates harmlessly.
    func setLevel(_ value: Float) {
        model.setLevel(value)
    }

    func hide() {
        panel.orderOut(nil)
    }

    // MARK: - Position

    private func positionAtScreenBottom() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let originX = visible.midX - size.width / 2
        let originY = visible.minY + 96  // 96 px above the screen bottom
        // Clear the anchor so the position call below isn't itself
        // snapped to a stale value, then re-arm the anchor with the
        // freshly computed bottom-Y.
        panel.anchoredBottomY = nil
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.anchoredBottomY = originY
    }
}

// MARK: - Panel subclass that captures keys without activating the app

private final class OverlayPanel: NSPanel {
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    /// When non-nil, every setFrame call forces origin.y to this
    /// value so the bottom edge stays on screen and the panel grows
    /// upward. Without this, NSWindow's auto-tracking of
    /// contentViewController.preferredContentSize re-anchors at the
    /// top-left as the SwiftUI content grows, which slides the
    /// bottom edge off the screen and hides the latest text.
    /// Intercepting setFrame here (rather than fighting the
    /// auto-track from a KVO observer that runs too late) is the
    /// reliable way to enforce the anchor.
    var anchoredBottomY: CGFloat?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(applyAnchor(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        super.setFrame(applyAnchor(frameRect), display: flag, animate: animateFlag)
    }

    private func applyAnchor(_ rect: NSRect) -> NSRect {
        guard let bottomY = anchoredBottomY else { return rect }
        var r = rect
        r.origin.y = bottomY
        return r
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:    // Return, Enter (numpad)
            onEnter?()
        case 53:        // Escape
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - SwiftUI content + view-model

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .capturing
    @Published var text: String = ""
    /// Normalized 0…1 mic level pushed by AudioRecorder during
    /// capture. Drives the SoundWaveBars view in the .capturing
    /// state. Resets to 0 when the overlay is shown for a new
    /// utterance so the bars start flat instead of carrying over
    /// the loudness from the previous capture.
    @Published var level: Float = 0
    /// Latest model-load snapshot to render in the `.initializing`
    /// state. `nil` means "no progress info yet" (the brief window
    /// between hotkey press and FluidAudio's first progress
    /// callback, or after a Reset ASR before the new load starts);
    /// the view falls back to the indeterminate spinner in that
    /// case. Cleared whenever the overlay leaves `.initializing`.
    @Published var downloadProgress: ASRDownloadProgress?

    /// Active microphone name to surface in the `.capturing` state's
    /// "listening on <name>…" line. `nil` falls back to the plain
    /// "listening…" copy — the only path that produces nil today is
    /// "user picked System Default but Core Audio currently has no
    /// default input," which is rare enough not to design for. Cleared
    /// whenever the overlay leaves `.capturing`.
    @Published var microphoneName: String?

    func update(
        state: OverlayState,
        text: String,
        downloadProgress: ASRDownloadProgress? = nil,
        microphoneName: String? = nil
    ) {
        self.state = state
        self.text = text
        if state != .capturing {
            level = 0
        }
        // Only the `.initializing` state surfaces progress; clearing
        // on other states keeps the published value from carrying
        // stale data into the next show() that might omit it.
        self.downloadProgress = (state == .initializing) ? downloadProgress : nil
        // Same scoping for the mic name — only the active-capture
        // states (`.capturing` and `.refining`, both of which run the
        // mic engine and surface a "listening…" line) render it. We
        // clear on other-state transitions so a later show() that
        // forgets to pass a name falls back to the generic copy
        // rather than reusing stale data.
        let isActiveCapture = (state == .capturing) || (state == .refining)
        self.microphoneName = isActiveCapture ? microphoneName : nil
    }

    func append(_ chunk: String) {
        text.append(chunk)
    }

    func setLevel(_ value: Float) {
        level = value
    }
}

private struct OverlayContent: View {
    @ObservedObject var model: OverlayModel
    /// Fixed outer width passed in from OverlayWindow. We constrain
    /// the SwiftUI hierarchy to this so NSHostingController's
    /// preferredContentSize reports (fixedWidth, naturalHeight)
    /// instead of an unbounded width — without this, .frame(maxWidth:
    /// .infinity) propagates infinity into the intrinsic-size query
    /// and the panel stretches off-screen instead of wrapping text.
    let width: CGFloat
    /// Cap on the transcript area's height. Above this, the content
    /// is bottom-aligned and clipped so the LATEST text stays visible
    /// just above the indicator dots / footer. Without this cap, the
    /// preferred-size query keeps growing and the panel walks past
    /// the screen edge.
    let maxContentHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: maxContentHeight, alignment: .bottom)
                .clipped()
            Divider().opacity(0.3)
            footer
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .padding(8)  // shadow breathing room
        .frame(width: width)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .initializing:
            // Two sub-states:
            //   - No `downloadProgress` snapshot yet: indeterminate
            //     spinner + the same generic caption we've shown
            //     since v0.7. Used in the brief window between the
            //     hotkey press and FluidAudio's first progress event.
            //   - Snapshot present: linear ProgressView showing the
            //     fraction filled, plus the phase label
            //     ("Downloading speech model (3 of 7)…",
            //     "Compiling joint-decoder.mlmodelc…", etc.) so the
            //     user sees real movement instead of staring at a
            //     spinner for 30–60 s on first launch.
            //
            // We still prefer SwiftUI's `ProgressView` over the
            // custom `BlinkingDots` for the indeterminate case
            // because the custom dot animation has been observed to
            // render statically in this state — likely a
            // SwiftUI-in-NSPanel quirk with repeatForever-on-appear.
            VStack(alignment: .leading, spacing: 6) {
                if let progress = model.downloadProgress {
                    Text(progress.phaseLabel)
                        .font(.system(size: 17))
                    ProgressView(value: max(0, min(1, progress.fraction)))
                        .progressViewStyle(.linear)
                    Text("This is a first-time download; subsequent launches are <5 s. The overlay disappears automatically when ready.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text("Initializing speech model…")
                            .font(.system(size: 17))
                    }
                    Text("First-time loading takes around 10–20 seconds. The overlay disappears automatically when ready.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        case .capturing:
            // While the user is speaking, AudioRecorder pushes the
            // per-buffer mic level into model.level so SoundWaveBars
            // can animate in time with the audio. The batch-mode
            // pipeline doesn't show partial transcripts (Parakeet TDT
            // v3 only returns text at end-of-utterance), so the
            // visualization is the only feedback during capture —
            // worth doing well.
            VStack(alignment: .leading, spacing: 6) {
                if !model.text.isEmpty {
                    Text(model.text)
                        .font(.system(size: 17))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    SoundWaveBars(level: model.level)
                    // Inline the active mic name when AppState
                    // resolved one. Tail truncation keeps the rare
                    // 40+ char USB-hub device name ("USB Audio
                    // Device (Focusrite Scarlett Solo)") from
                    // blowing out the overlay's fixed width; the
                    // menu-bar tooltip backstops by carrying the
                    // full name. Falls back to the plain
                    // "listening…" copy when the resolver returned
                    // nil (e.g. System Default selected but Core
                    // Audio has no default input — rare).
                    Text(model.microphoneName.map { "listening on \($0)…" } ?? "listening…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        case .cleaning:
            VStack(alignment: .leading, spacing: 6) {
                if !model.text.isEmpty {
                    Text(model.text)
                        .font(.system(size: 17))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    BlinkingDots()
                    Text(model.text.isEmpty ? "cleaning…" : "refining…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        case .awaitingAccept:
            Text(model.text)
                .font(.system(size: 17))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .refining:
            VStack(alignment: .leading, spacing: 6) {
                Text(model.text)
                    .font(.system(size: 17))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0.6)
                HStack(spacing: 8) {
                    BlinkingDots()
                    // Mirrors the .capturing branch's treatment: the
                    // mic name is the same data here, just labeled
                    // for the refinement pass. See the .capturing
                    // case for the truncation rationale.
                    Text(model.microphoneName.map { "listening for refinement on \($0)…" } ?? "listening for refinement…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch model.state {
        case .initializing:
            Text("[Esc] dismiss")
        case .capturing:
            Text("Release ⌥ when done")
        case .cleaning:
            Text("[Esc] cancel")
        case .awaitingAccept:
            Text("[tap ⌥] accept   [Esc] cancel   [hold ⌥] refine")
        case .refining:
            Text("Release ⌥ when done")
        }
    }
}

// Three slowly-blinking dots, used as a "listening / processing"
// indicator. Pure SwiftUI — no animation library dep.
private struct BlinkingDots: View {
    @State private var phase: Double = 0
    private let dotCount = 3

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<dotCount, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(opacity(for: i))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                phase = Double(dotCount)
            }
        }
    }

    private func opacity(for index: Int) -> Double {
        let position = phase.truncatingRemainder(dividingBy: Double(dotCount))
        let distance = abs(Double(index) - position)
        return 0.3 + 0.7 * max(0, 1 - distance)
    }
}

/// Five vertical bars whose heights track recent mic-level samples,
/// giving a real-time wave visualization during capture. Each bar is
/// one tick behind the next, so as new levels arrive the bumps
/// travel from right (newest) to left (oldest), reading like a
/// scrolling waveform. Pure SwiftUI, no Canvas — the small fixed bar
/// count keeps redraws cheap.
private struct SoundWaveBars: View {
    /// Normalized 0…1 mic level. The view's @State history tracks
    /// the last `barCount` values so the bars carry visual memory
    /// between buffer updates. Driven externally by OverlayModel.
    let level: Float

    private static let barCount = 5
    private static let barWidth: CGFloat = 4
    private static let barSpacing: CGFloat = 4
    private static let minHeight: CGFloat = 4
    private static let maxHeight: CGFloat = 24

    @State private var history: [Float] = Array(
        repeating: 0,
        count: SoundWaveBars.barCount
    )

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(history.indices, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(
                        width: Self.barWidth,
                        height: barHeight(for: history[i])
                    )
            }
        }
        .frame(height: Self.maxHeight)
        .onChange(of: level) { _, newValue in
            withAnimation(.easeOut(duration: 0.08)) {
                // Shift left, append the latest sample on the right —
                // newest goes to the trailing edge so the wave reads
                // as moving in the same direction speech progresses.
                history.removeFirst()
                history.append(newValue)
            }
        }
    }

    private func barHeight(for value: Float) -> CGFloat {
        let clamped = max(0, min(1, CGFloat(value)))
        return Self.minHeight + clamped * (Self.maxHeight - Self.minHeight)
    }
}
