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
import UniformTypeIdentifiers

/// Visible state of the overlay. Driven by AppState transitions.
public enum OverlayState: Sendable {
    /// Sidecar process isn't ready yet (model still loading, or in
    /// the middle of a crash + restart). Hotkey presses get a
    /// "please wait" message instead of being silently ignored or
    /// hanging on a black-hole capture.
    case initializing
    /// Shift+hotkey opens this. No audio capture; the user is curating
    /// references via the window picker. The next plain hotkey press
    /// transitions to .capturing while preserving the staged refs.
    case staging
    case capturing
    case cleaning
    case awaitingAccept
    case refining
}

@MainActor
public final class OverlayWindow {
    /// Width is fixed; height grows with content, anchored to the
    /// bottom edge so it expands upward.
    private static let fixedWidth: CGFloat = 720
    /// Floor for the panel height — short utterances still get a
    /// stable shape while the partial transcript streams in.
    private static let minHeight: CGFloat = 140
    /// Vertical offset between the bottom of the visible screen and
    /// the bottom of the panel — kept consistent with the anchor
    /// enforced in OverlayPanel.setFrame.
    private static let bottomAnchorOffset: CGFloat = 96
    /// Estimated panel chrome height: chips row (may wrap when many
    /// references attached) + error/permission banner (visible when
    /// non-nil) + divider + buttons row + "[hold ⌥] refine" hint +
    /// VStack spacings + outer paddings + shadow breathing room.
    /// Used to compute the maximum content height that won't drive
    /// the panel off the top of the screen. Set conservatively
    /// because under-estimating leaks visible content past the screen
    /// edge — over-estimating just gives a slightly tighter content
    /// area, which is the safe failure mode.
    private static let chromeHeightEstimate: CGFloat = 360
    /// Breathing room below the menu bar at the top of the visible
    /// screen — keeps the panel from pressing against the system UI.
    private static let topBreathingRoom: CGFloat = 16

    private let panel: OverlayPanel
    public let model: OverlayModel
    private let hostingController: NSHostingController<OverlayContent>
    private var sizeObservation: NSKeyValueObservation?
    public var onAccept: (() -> Void)?
    public var onCancel: (() -> Void)?
    public var onCopy: (() -> Void)?
    /// AppState wires this to the "send to a different window" flow.
    /// Triggered by a bare V keypress while the overlay has key focus
    /// during review (the focus-free hold+V variant is deferred — it
    /// collides with the awaitingAccept refine timer).
    public var onSendTo: (() -> Void)?
    /// AppState wires this to the "?" help overlay. Triggered by "?" /
    /// "/" while the overlay has key focus (during capture or review).
    public var onShowHelp: (() -> Void)?
    /// AppState wires this to "attach another window as context" during
    /// review. Triggered by a bare Space keypress while the overlay has
    /// key focus during review (mirrors the hold+Space gesture, but as a
    /// resting-state key). The attached reference feeds the next refine.
    public var onAttachWindow: (() -> Void)?
    /// AppState wires this to "attach the current window as context"
    /// during review. Triggered by a bare C keypress while the overlay
    /// has key focus during review (mirrors the hold+C gesture). The
    /// attached reference feeds the next refine.
    public var onAttachCurrent: (() -> Void)?
    /// AppState wires this to "show the Parleq window" (cancelling the
    /// current dictation). Triggered by a bare P keypress while the
    /// overlay has key focus during review — the resting-state twin of
    /// the hold+P gesture.
    public var onShowParleq: (() -> Void)?
    /// AppState wires this to open the WindowPickerWindow. The picker
    /// itself owns the entry-pick callback chain; the overlay just
    /// requests the picker be shown.
    public var onShowWindowPicker: (() -> Void)?
    /// AppState wires this to run a transform preset (by id) as a refine
    /// pass on the current review text. Triggered by the preset chips in
    /// the .awaitingAccept footer.
    public var onRunPreset: ((String) -> Void)?
    /// AppState wires this to undo a per-app default style: re-runs plain
    /// cleanup (no transform addendum) from the retained raw transcript.
    public var onUndoStyle: (() -> Void)?
    /// M2 fix: wired to AppState.switchModelAndRecleanup(_:) so the
    /// Switch-to-vision-model button re-runs cleanup with the new
    /// provider rather than only flipping the badge. Distinct from the
    /// old onSwitchToVisionModel (badge-flip only) which is no longer
    /// needed.
    public var onSwitchToVisionModelAndRecleanup: ((ModelIdentifier) -> Void)?

    public init() {
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
        // hasShadow=false: on macOS 26 Liquid Glass paints its own
        // edge specular treatment, and AppKit's window shadow was
        // tuned for opaque panels in macOS 14 — the two together
        // produced a doubled-rim "fine line" effect that read as
        // odd. Letting Liquid Glass own the edge is cleaner. On the
        // legacy .regularMaterial fallback, the lack of shadow is
        // mildly less polished but not visually broken.
        panel.hasShadow = false
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
        let maxContentHeight = OverlayWindow.computeMaxContentHeight(visibleHeight: screenHeight)
        let maxPanelHeight = OverlayWindow.computeMaxPanelHeight(visibleHeight: screenHeight)
        // OverlayContent needs callbacks (onCopy, onCancel, onAccept,
        // onShowWindowPicker) that forward to this class's published
        // vars. We can't reference `self` in the closures before fully
        // initialising, so seed the rootView with pass-through stubs
        // and replace it immediately after all stored properties are
        // set (see the rewireCallbacks() call below).
        let hc = NSHostingController(
            rootView: OverlayContent(
                model: model,
                width: OverlayWindow.fixedWidth,
                maxContentHeight: maxContentHeight,
                maxPanelHeight: maxPanelHeight,
                onCopy: {},
                onCancel: {},
                onAccept: {},
                onShowWindowPicker: {},
                onSwitchToVisionModelAndRecleanup: { _ in },
                onRunPreset: { _ in },
                onUndoStyle: {},
                onBodyHeightChange: { _ in }
            )
        )
        hc.sizingOptions = [.preferredContentSize]
        self.hostingController = hc

        // Wrap the hosting controller's view in a custom NSView that
        // accepts first-mouse clicks, so a click while unfocused
        // refocuses the panel AND triggers the action in one motion.
        let wrappedView = FirstMouseAcceptingView(hc.view)
        panel.contentView = wrappedView

        // Wire the panel's key-handler hooks to the closures on this
        // class (which AppState fills in via onAccept/onCancel).
        panel.onEnter = { [weak self] in self?.onAccept?() }
        panel.onEscape = { [weak self] in self?.onCancel?() }
        panel.onSendTo = { [weak self] in self?.onSendTo?() }
        panel.onShowHelp = { [weak self] in self?.onShowHelp?() }
        panel.onAttachWindow = { [weak self] in self?.onAttachWindow?() }
        panel.onAttachCurrent = { [weak self] in self?.onAttachCurrent?() }
        panel.onShowParleq = { [weak self] in self?.onShowParleq?() }

        sizeObservation = hc.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            // Trace: prove the KVO fires. Captures the .new value so
            // we can see what size NSHostingController is reporting.
            if let newSize = change.newValue {
                OverlayWindow.logStderr(
                    "[parleq] overlay KVO: preferredContentSize → " +
                    "\(Int(newSize.width))×\(Int(newSize.height))"
                )
            }
            // KVO callbacks run on whatever thread updated the
            // property; SwiftUI on macOS updates this on main, but
            // hop explicitly to be safe.
            Task { @MainActor in self?.resizePanelToFitContent() }
        }

        // All stored properties are now set; replace the stub rootView
        // with one whose callbacks forward to self.
        rewireCallbacks()

        // Subscribe to NSPanel key-state notifications so the overlay
        // can track whether it's the focused window. The OverlayButtons
        // view uses model.isKey to show the "Parleq lost focus" message
        // when the panel isn't key.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.isKey = true
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.isKey = false
            }
        }
    }

    /// Replace the hosting controller's rootView so that the SwiftUI
    /// callbacks (onCopy, onCancel, onAccept, onShowWindowPicker)
    /// forward to this class's current closure properties. Called
    /// exactly once at the end of init (after `self` is fully
    /// initialised). Do not call again — replacing rootView at runtime
    /// resets per-instance SwiftUI @State.
    private func rewireCallbacks() {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let maxContentHeight = OverlayWindow.computeMaxContentHeight(visibleHeight: screenHeight)
        let maxPanelHeight = OverlayWindow.computeMaxPanelHeight(visibleHeight: screenHeight)
        hostingController.rootView = OverlayContent(
            model: model,
            width: OverlayWindow.fixedWidth,
            maxContentHeight: maxContentHeight,
            maxPanelHeight: maxPanelHeight,
            onCopy: { [weak self] in self?.onCopy?() },
            onCancel: { [weak self] in self?.onCancel?() },
            onAccept: { [weak self] in self?.onAccept?() },
            onShowWindowPicker: { [weak self] in self?.onShowWindowPicker?() },
            onSwitchToVisionModelAndRecleanup: { [weak self] id in
                self?.onSwitchToVisionModelAndRecleanup?(id)
            },
            onRunPreset: { [weak self] id in self?.onRunPreset?(id) },
            onUndoStyle: { [weak self] in self?.onUndoStyle?() },
            onBodyHeightChange: { [weak self] newHeight in
                self?.resizePanelToHeight(newHeight)
            }
        )
    }

    /// Resize the panel to match the SwiftUI body's measured height.
    /// Driven by OverlayBodyHeightKey via OverlayContent's outer
    /// .background(GeometryReader) — this is the replacement for the
    /// NSHostingController.preferredContentSize KVO chain (which never
    /// fires in our setup because we attach hc.view as a subview
    /// rather than installing hc as the panel's contentViewController,
    /// so the controller's viewDidLayout is never called).
    private func resizePanelToHeight(_ measuredHeight: CGFloat) {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        let maxPanelHeight = OverlayWindow.computeMaxPanelHeight(visibleHeight: visible)
        let target = max(
            OverlayWindow.minHeight,
            min(maxPanelHeight, measuredHeight)
        )
        var frame = panel.frame
        if abs(frame.size.height - target) < 0.5 { return }
        OverlayWindow.logStderr(
            "[parleq] overlay body-height resize: measured=\(Int(measuredHeight)) " +
            "maxPanel=\(Int(maxPanelHeight)) → target=\(Int(target))"
        )
        frame.size.height = target
        panel.setFrame(frame, display: true, animate: false)
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
    /// `microphoneName` is only consulted in the active-capture
    /// states (`.capturing` and `.refining`, both of which run the
    /// mic engine); other states ignore it. AppState resolves the
    /// active mic via `effectiveMicrophoneName(forExplicitUID:)` and
    /// passes the result so the overlay can render "listening on
    /// <Mic>…" / "listening for refinement on <Mic>…" inline. nil =
    /// fall back to the plain "listening…" / "listening for
    /// refinement…" text.
    ///
    /// `cleanupFailureMessage` is only consulted in the
    /// `.awaitingAccept` state; other states ignore it. When non-nil,
    /// the overlay decorates the awaitingAccept view with a warning
    /// icon + the message so the user knows cleanup failed and what
    /// to do about it (the message is provider-specific — see each
    /// LLMProvider's `cleanupFailureHint`). The raw transcript is
    /// shown alongside so the user can still accept it via Enter.
    public func show(
        state: OverlayState,
        text: String,
        downloadProgress: ASRDownloadProgress? = nil,
        microphoneName: String? = nil,
        cleanupFailureMessage: String? = nil
    ) {
        model.update(
            state: state,
            text: text,
            downloadProgress: downloadProgress,
            microphoneName: microphoneName,
            cleanupFailureMessage: cleanupFailureMessage
        )
        if !panel.isVisible {
            // Pre-size the panel to the SwiftUI intrinsic content
            // height BEFORE making it visible. Without this, the
            // panel appears at its 140pt minHeight (or whatever
            // its prior size happened to be) and:
            //   1. SwiftUI lays out the body within those bounds,
            //      clipping the top because the panel is anchored
            //      at the bottom.
            //   2. The GeometryReader inside OverlayContent measures
            //      the CONSTRAINED body size (= current panel height),
            //      not the intrinsic content size.
            //   3. The .onPreferenceChange callback fires with the
            //      constrained height, equal to the current frame.
            //   4. resizePanelToHeight sees no change and no-ops.
            //   5. The panel stays clipped until something else grows
            //      the content further.
            //
            // sizeThatFits(in:) queries SwiftUI directly with an
            // unconstrained-height proposal, so it returns the height
            // the body actually wants — independent of the current
            // view bounds. layoutSubtreeIfNeeded first ensures any
            // pending SwiftUI updates from the just-issued model.update
            // call have been flushed so sizeThatFits reflects the
            // new state, not the previous one.
            hostingController.view.layoutSubtreeIfNeeded()
            let proposal = NSSize(
                width: OverlayWindow.fixedWidth,
                height: .greatestFiniteMagnitude
            )
            let fitting = hostingController.sizeThatFits(in: proposal)
            // anchoredBottomY left over from a prior session would
            // make panel.setFrame snap the origin to a stale Y; clear
            // it so positionAtScreenBottom (called next) can re-arm
            // the anchor with the freshly computed origin.
            panel.anchoredBottomY = nil
            resizePanelToHeight(fitting.height)

            positionAtScreenBottom()

            // Instant appearance. An earlier polish pass faded the
            // panel in over ~160ms via NSAnimationContext, but the
            // dictation hotkey is a high-frequency interaction —
            // even ~100-150ms of fade reads as "the overlay is
            // slower than it used to be" because the user is
            // waiting on it before they start talking. Trade the
            // polish for responsiveness.
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            // makeKey delivers keyDown events to the panel without
            // activating our app (we're a .nonactivatingPanel).
            panel.makeKey()
        }
    }

    /// Size the panel to fit the SwiftUI intrinsic content height,
    /// clamped to minHeight at the floor.
    ///
    /// Sizing is driven purely by the KVO observer on
    /// `hostingController.preferredContentSize` (registered in init).
    /// We install the hosting view via `panel.contentView` (wrapped in
    /// FirstMouseAcceptingView) rather than `panel.contentViewController`,
    /// so NSWindow does NOT auto-track preferredContentSize — this
    /// method is the sole sizing path. Position is handled by
    /// OverlayPanel.setFrame's anchor override; the transcript-area
    /// cap is enforced inside SwiftUI (see OverlayContent.maxContentHeight).
    private func resizePanelToFitContent() {
        let preferred = hostingController.preferredContentSize
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        let maxPanelHeight = max(
            OverlayWindow.minHeight + 1,
            visible - OverlayWindow.bottomAnchorOffset - OverlayWindow.topBreathingRoom
        )
        let target = max(
            OverlayWindow.minHeight,
            min(maxPanelHeight, preferred.height)
        )
        var frame = panel.frame
        let noop = abs(frame.size.height - target) < 0.5
        OverlayWindow.logStderr(
            "[parleq] overlay resize\(noop ? " (no-op)" : ""): " +
            "pref=\(Int(preferred.height)) " +
            "visible=\(Int(visible)) " +
            "maxPanel=\(Int(maxPanelHeight)) " +
            "currentFrame=\(Int(frame.size.height)) " +
            "→ target=\(Int(target))"
        )
        if noop { return }
        frame.size.height = target
        panel.setFrame(frame, display: true, animate: false)
    }

    private static func logStderr(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8) ?? Data())
    }

    /// Maximum height the transcript / content area is allowed to
    /// take. Subtracts the realistic chrome height from the available
    /// vertical space so the panel never grows tall enough to push
    /// the chip row past the top of the screen.
    private static func computeMaxContentHeight(visibleHeight: CGFloat) -> CGFloat {
        let usable = visibleHeight - bottomAnchorOffset - topBreathingRoom - chromeHeightEstimate
        // Floor at 200pt so the cap is never absurdly small even on
        // tiny external monitors.
        return max(200, usable)
    }

    /// Maximum height for the whole panel — visible screen minus the
    /// bottom anchor offset minus a small top breathing room. Used
    /// both as the SwiftUI body's .frame(maxHeight:) and as the
    /// hard cap in resizePanelToFitContent so the panel can never
    /// extend above the menu bar.
    public static func computeMaxPanelHeight(visibleHeight: CGFloat) -> CGFloat {
        return max(minHeight + 1, visibleHeight - bottomAnchorOffset - topBreathingRoom)
    }

    /// Append a chunk of text to the overlay. Used by the streaming
    /// LLM client (M4) so the visible text grows incrementally.
    public func appendText(_ chunk: String) {
        model.append(chunk)
    }

    /// Push a normalized 0…1 mic level into the overlay so the
    /// .capturing state's sound-wave bars can animate. Cheap no-op
    /// in any other state — the bars view only renders during
    /// capture, but the published value still updates harmlessly.
    public func setLevel(_ value: Float) {
        model.setLevel(value)
    }

    /// Run `activation` with the overlay's `.canJoinAllSpaces`
    /// collection-behavior temporarily stripped. Used by AppState's
    /// post-reference-capture focus restore (issue #229) so macOS
    /// will actually animate the Space switch back to the user's
    /// origin Space — when the overlay carries `.canJoinAllSpaces`,
    /// WindowServer treats the overlay as "still relevant here" and
    /// suppresses the Space-switch even though the target app's
    /// activation succeeds. Stripping the flag for the duration of
    /// the activate call removes that suppression. After the Space
    /// animation has had time to land we restore the flag and
    /// `orderFront` so the overlay reattaches to the new (now-current)
    /// Space — without the orderFront the overlay would be stuck on
    /// the source app's Space (where it was when we stripped the
    /// flag) and the user would see no overlay on their new Space.
    ///
    /// 600ms wait is empirical — macOS Space-switch animations are
    /// ~500ms; adding a small settle margin avoids the orderFront
    /// landing on the wrong Space if it fires mid-animation.
    public func performActivationWithSpaceSwitch(_ activation: () -> Void) async {
        // Restore to a CANONICAL known-good value rather than
        // snapshotting `panel.collectionBehavior` before stripping.
        // If a second call to this method starts while the first is
        // sleeping, the second would snapshot the already-stripped
        // [.fullScreenAuxiliary] value and write THAT back at the
        // end — losing `.canJoinAllSpaces` permanently. Using a
        // constant target makes the operation idempotent across
        // overlapping calls. The constant must match the overlay's
        // init-time collection behavior (line ~103) so the post-
        // restore state is identical to the unmolested overlay.
        let canonicalBehavior: NSWindow.CollectionBehavior =
            [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.collectionBehavior = [.fullScreenAuxiliary]
        activation()
        try? await Task.sleep(nanoseconds: 600_000_000)
        panel.collectionBehavior = canonicalBehavior
        if panel.isVisible {
            panel.orderFront(nil)
            // Reclaim key-window status. Activating the dictation-
            // origin app (e.g. iTerm) above moves the OS-level key
            // window to that app, which means the overlay's
            // per-window keyboard shortcuts — Enter (accept) and
            // Escape (cancel) — stop working until the user clicks
            // back on the overlay. Calling makeKey here brings key
            // status back to the panel without changing the active
            // app (panel is a .nonactivatingPanel, so makeKey does
            // not steal foreground activation from the just-
            // activated dictation-origin app — the user still sees
            // their origin as active while the overlay accepts
            // Enter / Escape again).
            panel.makeKey()
        }
    }

    public func hide() {
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
    var onSendTo: (() -> Void)?
    var onShowHelp: (() -> Void)?
    var onAttachWindow: (() -> Void)?
    var onAttachCurrent: (() -> Void)?
    var onShowParleq: (() -> Void)?
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
        var r = rect
        // Defensive height cap at the AppKit layer. No matter what
        // SwiftUI or the resize KVO computes, the panel physically
        // cannot exceed the screen's available height minus the
        // bottom anchor and a small breathing-room buffer. This is
        // the final say.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let absoluteMax = max(140, visible.height - 96 - 16)
            if r.size.height > absoluteMax {
                Self.logStderr(
                    "[parleq] overlay panel height \(Int(r.size.height)) " +
                    "exceeded screen cap \(Int(absoluteMax)) — clamping"
                )
                r.size.height = absoluteMax
            }
        }
        if let bottomY = anchoredBottomY {
            r.origin.y = bottomY
        }
        return r
    }

    private static func logStderr(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8) ?? Data())
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:    // Return, Enter (numpad)
            onEnter?()
        case 53:        // Escape
            onEscape?()
        default:
            // Match produced glyphs, not raw key codes — key positions
            // differ across AZERTY/QWERTZ/Dvorak, so keyCode matching
            // would break these gestures for non-US layouts. Check both
            // `characters` and `charactersIgnoringModifiers` for "?"/"/"
            // so it works even while the hotkey (often Option) is held —
            // Option-Shift-/ yields a modified glyph in `characters` but
            // "?" in `charactersIgnoringModifiers`.
            let glyph = event.characters
            let baseGlyph = event.charactersIgnoringModifiers
            // Bare (no Cmd/Ctrl/Option/Shift) gestures share this guard
            // so a modified keypress (e.g. ⌘V paste in some future field)
            // never trips them.
            let noMods = event.modifierFlags
                .intersection([.command, .control, .option, .shift]).isEmpty
            if glyph == "?" || glyph == "/" || baseGlyph == "?" || baseGlyph == "/" {
                onShowHelp?()
            } else if noMods, baseGlyph?.lowercased() == "v" {
                // Bare "V" — send-to.
                onSendTo?()
            } else if noMods, event.keyCode == 49 {
                // Bare Space — attach another window as context (review).
                // keyCode 49 is Space on every layout; AppState gates the
                // action to .awaitingAccept so it no-ops elsewhere.
                onAttachWindow?()
            } else if noMods, baseGlyph?.lowercased() == "c" {
                // Bare "C" — attach the current window as context (review).
                onAttachCurrent?()
            } else if noMods, baseGlyph?.lowercased() == "p" {
                // Bare "P" — show the Parleq window (cancels review).
                // AppState gates to .awaitingAccept so it no-ops elsewhere.
                onShowParleq?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

// MARK: - First-mouse accepting view wrapper

/// Wraps the hosting controller's view as the panel's contentView.
///
/// AppKit consults `acceptsFirstMouse(for:)` on the *hit-test view*
/// at the click location — not on its ancestors — so this wrapper's
/// override only takes effect when a click lands on bare wrapper
/// area outside the hosted SwiftUI content. For clicks that land
/// inside the hosted view's button hit-region, AppKit consults the
/// SwiftUI-internal `NSHostingView`'s `acceptsFirstMouse` instead.
/// In current macOS, `NSHostingView` returns true for interactive
/// SwiftUI controls, so the chained behavior (wrapper for ambient
/// area, hosting view for controls) gives us single-click-while-
/// unfocused for the Accept/Cancel/Copy buttons.
///
/// If a future macOS revision changes that default, we'll need to
/// subclass `NSHostingView` directly (replacing
/// `NSHostingController`'s default view) and put the override there.
/// Documented as a known seam.
private final class FirstMouseAcceptingView: NSView {
    private let hostedView: NSView

    init(_ hostedView: NSView) {
        self.hostedView = hostedView
        super.init(frame: hostedView.frame)
        addSubview(hostedView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        hostedView.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// MARK: - SwiftUI content + view-model

@MainActor
public final class OverlayModel: ObservableObject {
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
    /// callback, or right after a Reset speech model invocation
    /// before the new load starts); the view falls back to the
    /// indeterminate spinner in that case. Cleared whenever the
    /// overlay leaves `.initializing`.
    @Published var downloadProgress: ASRDownloadProgress?

    /// Active microphone name to surface in the active-capture
    /// states' "listening on <name>…" / "listening for refinement on
    /// <name>…" line. `nil` falls back to the plain "listening…" /
    /// "listening for refinement…" copy — the only path that produces
    /// nil today is "user picked System Default but Core Audio
    /// currently has no default input," which is rare enough not to
    /// design for. Cleared whenever the overlay leaves an
    /// active-capture state (anything other than `.capturing` or
    /// `.refining`).
    @Published var microphoneName: String?

    /// Optional cleanup-failure message rendered alongside the raw
    /// transcript in the `.awaitingAccept` state. Carries the
    /// provider-specific recovery hint (see
    /// `LLMProvider.cleanupFailureHint(for:)`). Cleared on any other
    /// state so a successful subsequent dictation doesn't carry over
    /// the prior turn's failure annotation.
    @Published var cleanupFailureMessage: String?

    /// Name of the per-app default preset folded into the current
    /// dictation's cleanup, nil when none. Drives the review state's
    /// "Styled with <name> · Undo" chip.
    @Published var appliedPresetName: String?

    /// Array of Reference objects to display in the overlay. Used by
    /// the reference window feature to show context-aware references
    /// and citations.
    @Published var references: [Reference] = []

    /// Optional paste destination target for the current overlay state.
    /// When set, indicates where the user's paste action will be routed
    /// or which envelope is being suggested.
    @Published var pasteTarget: PasteDestination?

    /// Whether the overlay is in "key" mode (used by the reference
    /// window feature to control overlay behavior and styling).
    @Published var isKey: Bool = true

    /// Optional screen recording permission prompt message. Surfaced in
    /// the overlay when capture lacks the necessary permissions.
    @Published var permissionPrompt: String?

    /// Optional error message to display in the overlay's error banner.
    /// Cleared by tapping the banner. Distinct from `permissionPrompt`
    /// so callers can set either independently without overwriting the
    /// other.
    @Published var errorMessage: String?

    /// Mirror of AppState's compose-state machine (Reference Windows
    /// v2 latched-compose flow). Drives the OverlayHintStrip's per-state
    /// copy. When .idle, the overlay behaves exactly like v1; when
    /// .recording / .pickerOpen / .latched / .latchedRecording, the
    /// latched UX renders.
    ///
    /// Note: composeState does NOT explicitly gate the auto-accept
    /// timer today — the latched flow happens to never reach
    /// .awaitingAccept because the .hotkeyUp(spaceWasPressedDuringHold:
    /// false) transition resets composeState to .idle BEFORE
    /// finalizeCapture runs. So the timer's existing
    /// "fire-only-in-awaitingAccept" gate is sufficient. If a future
    /// path ever reaches .awaitingAccept without resetting
    /// composeState (e.g. a different submit route), an explicit
    /// `guard composeState == .idle` in startAutoAcceptTimer would
    /// be the right place to add the safety net.
    @Published var composeState: ComposeState = .idle

    /// True from the moment Space is pressed during a dictation hold
    /// until that hold ends (either by release-into-picker, or by
    /// the subsequent state reset). Drives the OverlayHintStrip's
    /// "armed" hint so the user gets visual confirmation that Space
    /// landed BEFORE they release the hotkey — without this they
    /// have no signal until the picker actually opens on release.
    /// Independent of the ComposeState machine (purely UI feedback —
    /// behavior continues to be driven by `composeState`) so that
    /// adding it doesn't double the state count.
    @Published var spaceArmedDuringHold: Bool = false

    /// AppState wires this to its trackCaptureTask helper so that
    /// async reference-capture work started from the overlay (e.g.
    /// the Add file menu's NSOpenPanel completion) participates in
    /// the same pending-task bookkeeping the submit path waits on.
    /// Without this, an overlay-initiated file pick that resolves
    /// after the user hits Send / Enter would land its append on a
    /// reset state — leaking the reference into the next dictation
    /// session and omitting it from the just-finalized entry.
    /// Not @Published because it's wiring, not view state.
    public var onTrackCaptureTask: ((Task<Void, Never>) -> Void)?

    /// Display name of the user's dictation hotkey (e.g. "⌥-Right").
    /// Read by OverlayHintStrip so its teaching copy uses the user's
    /// actual binding rather than a hardcoded label. Set by AppState
    /// from HotkeyBinding.displayName at construction. Empty string
    /// falls back to the literal text "the hotkey" in the strip copy.
    @Published public var hotkeyDisplayName: String = ""

    /// Mirror of Config.referenceWindowsEnabled. When false (Privacy
    /// & Features toggle off, or MDM-pinned-off), the OverlayHintStrip
    /// suppresses the "Press Space to attach a window" teaching copy
    /// in .recording state — Space wouldn't open the picker in that
    /// case (gated upstream in AppState.hotkeyUp). Updated whenever
    /// AppState reads the config so the strip reactively respects
    /// the latest setting.
    @Published var referenceWindowsEnabled: Bool = true

    /// Per-invocation model override set by the in-overlay ModelPicker
    /// (Task 9). nil → fall through to Config.modelForInvocation's
    /// override > context > cleanup chain. Reset to nil after each
    /// Accept (and Cancel) by AppState.
    @Published public var pickedModelOverride: ModelIdentifier?

    /// One-shot user acknowledgment that the current ModelConflict
    /// (vision refs + non-vision model) is OK: send refs as text,
    /// drop image content. Cleared on Accept/Cancel by AppState so
    /// the next dictation re-evaluates from scratch. Set by the
    /// "Downgrade & send" button in the conflict warning row.
    @Published public var userDowngradedConflict: Bool = false

    /// True while the user is in hold-hotkey-and-click picking mode
    /// (hotkey held during .staging or .awaitingAccept). Drives the
    /// WindowHighlightOverlay's activate/deactivate lifecycle.
    @Published public var isPickingWindow: Bool = false

    public func update(
        state: OverlayState,
        text: String,
        downloadProgress: ASRDownloadProgress? = nil,
        microphoneName: String? = nil,
        cleanupFailureMessage: String? = nil
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
        // Cleanup-failure message is only relevant in
        // `.awaitingAccept` — that's where the user reviews the
        // text + decides whether to paste raw. Cleared elsewhere
        // so stale messages don't follow a successful cleanup turn.
        self.cleanupFailureMessage = (state == .awaitingAccept) ? cleanupFailureMessage : nil
    }

    public func append(_ chunk: String) {
        text.append(chunk)
    }

    public func setLevel(_ value: Float) {
        level = value
    }
}

/// PreferenceKey for plumbing the measured intrinsic height of the
/// transcript content up to the OverlayContent view. Lets the
/// ScrollView wrapper size its frame to the actual content height
/// (so the panel grows naturally with the dictation) while still
/// capping at maxContentHeight (so the panel can't walk off the top
/// of the screen on very long output, and scrolling engages).
private struct OverlayContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// PreferenceKey for the OverlayContent's outermost measured height —
/// the value we want the panel itself to take. Used to drive panel
/// resize directly from SwiftUI, bypassing NSHostingController's
/// preferredContentSize auto-track (which only works when the
/// controller is installed as panel.contentViewController; we install
/// its view as a subview via FirstMouseAcceptingView instead, so the
/// auto-track is dead in this app).
private struct OverlayBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
    /// Hard cap on the whole panel's visible height. Applied as the
    /// body's .frame(maxHeight:) so SwiftUI never asks NSHostingController
    /// for a preferredContentSize larger than the available screen
    /// area (visible.height - bottomAnchorOffset - topBreathingRoom).
    /// Belt-and-suspenders with the panel-side cap in
    /// resizePanelToFitContent.
    let maxPanelHeight: CGFloat

    // Callbacks forwarded from OverlayWindow.
    let onCopy: () -> Void
    let onCancel: () -> Void
    let onAccept: () -> Void
    /// Tapping the `+` chip-row button fires this. AppState owns the
    /// WindowPickerWindow and routes the pick through its own chain.
    let onShowWindowPicker: () -> Void
    /// M2 fix: fires when the user taps "Switch to <model>" in the
    /// conflict warning row, triggering AppState to re-run cleanup
    /// with the new provider rather than only flipping the badge.
    let onSwitchToVisionModelAndRecleanup: (ModelIdentifier) -> Void
    /// Fires when the user taps a preset chip in the review footer.
    /// AppState's `runPreset(id:)` receives the preset's stable id.
    let onRunPreset: (String) -> Void
    /// Fires when the user taps "Undo" on the "Styled with X" chip.
    /// AppState's `undoStyle()` re-runs plain cleanup from the raw transcript.
    let onUndoStyle: () -> Void

    /// Fires whenever the body's outermost measured height changes.
    /// OverlayWindow uses this to drive panel resize directly, since
    /// NSHostingController.preferredContentSize is dead in our setup
    /// (the controller's view is added as a subview rather than as
    /// the panel's contentViewController, so the controller's
    /// viewDidLayout never fires).
    let onBodyHeightChange: (CGFloat) -> Void

    /// Measured intrinsic height of the transcript content, updated
    /// every time the content's layout changes. Drives the ScrollView
    /// frame's height: <= cap, the frame matches content and the
    /// panel grows naturally; >= cap, the frame caps and the ScrollView
    /// scrolls internally.
    @State private var measuredContentHeight: CGFloat = 0

    /// Controls visibility of the ModelPicker popover attached to
    /// the ModelBadge in the header strip.
    @State private var modelPickerShown = false

    /// Tracks whether a drag is currently hovering over the overlay.
    /// Drives the brand-orange border tint affordance.
    @State private var isDragOver = false

    // "Learn from corrections" new-feature line (review state only).
    // Shared dismissed flag + first-shown timestamp with the in-app
    // banner (keys match LearnBanner). `learnJustEnabled` hides the line
    // immediately after the user flips its toggle on.
    @AppStorage("parleq.learnBanner.dismissed") private var learnBannerDismissed = false
    @AppStorage("parleq.learnBanner.overlayFirstShownAt") private var learnOverlayFirstShown: Double = 0
    @State private var learnJustEnabled = false
    // Config-derived gating for the learn nudge, cached so the per-render
    // `learnLine` builder doesn't hit disk (Config.load) on the latency-
    // sensitive overlay. Refreshed on appear and on state transitions.
    @State private var learnFeatureEnabled = false
    @State private var learnFeatureManaged = false

    // Preset chips for the review footer, cached so the per-render body
    // doesn't hit disk (Config.load) — same pattern as the learn flags.
    @State private var presetChips: [TransformPreset] = []

    /// The "Learn from corrections" nudge line shown on the review state
    /// while the feature is off and not dismissed (24h window). Its toggle
    /// turns the feature on in place; the ✕ dismisses (shared with the
    /// in-app banner). Empty once enabled/dismissed/expired.
    @ViewBuilder
    private var learnLine: some View {
        let firstShown: Double? = learnOverlayFirstShown == 0 ? nil : learnOverlayFirstShown
        if !learnJustEnabled,
           LearnBanner.shouldShowInOverlay(
               dismissed: learnBannerDismissed,
               featureEnabled: learnFeatureEnabled,
               firstShownAt: firstShown,
               now: Date().timeIntervalSinceReferenceDate,
               managed: learnFeatureManaged
           ) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Learn from your corrections")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Toggle("", isOn: Binding(
                    get: { false },
                    set: { isOn in
                        // Only hide the line if the feature actually turned
                        // on (enableFeature returns false if MDM-pinned off
                        // or the save failed — don't pretend it's enabled).
                        if isOn, LearnBanner.enableFeature() {
                            learnJustEnabled = true
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                Spacer(minLength: 4)
                Button(action: { learnBannerDismissed = true }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .onAppear { LearnBanner.recordOverlayShownIfNeeded() }
        }
    }

    /// Preset chips + the per-app-default styled chip, review state only.
    /// Lives in the FIXED footer (never the scrolling text) so reference-
    /// heavy overlays can't be pushed around — see the 0.18.0 layout
    /// lessons. Count-based overflow: first 4 chips inline, rest in a ⋯
    /// menu (deterministic; no width measurement).
    @ViewBuilder
    private var presetRow: some View {
        if !presetChips.isEmpty || model.appliedPresetName != nil {
            HStack(spacing: 6) {
                if let name = model.appliedPresetName {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("Styled with \(name)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button("Undo") { onUndoStyle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(SettingsView.brandAccent)
                            .accessibilityLabel("Undo style: \(name)")
                    }
                }
                ForEach(presetChips.prefix(4)) { preset in
                    Button(preset.name) { onRunPreset(preset.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .accessibilityHint("Apply this transform to the dictation")
                }
                if presetChips.count > 4 {
                    Menu {
                        ForEach(presetChips.dropFirst(4)) { preset in
                            Button(preset.name) { onRunPreset(preset.id) }
                                .accessibilityHint("Apply this transform to the dictation")
                        }
                    } label: {
                        Text("⋯").font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Single header strip combining paste-target chip + reference
            // chips + window-picker button. One row keeps the chrome
            // compact (the panel anchors at the bottom and grows upward,
            // so every chrome row we add risks pushing the top of the
            // panel past the visible screen on long transcripts).
            headerStrip

            // Error / permission banner (only when a message is set).
            errorBanner

            // Main content area — two-mode layout per Jon's suggestion:
            //
            //   1. Below the scroll threshold: render content directly
            //      with no ScrollView wrapper. The body's height grows
            //      naturally with the content. This gives the "panel
            //      grows organically with what I'm dictating" feel for
            //      short and medium output.
            //
            //   2. At or above the threshold: switch to a fixed-height
            //      ScrollView. The body stops growing; the content
            //      scrolls inside. Chips at top + buttons at bottom
            //      stay anchored, since the body height (chrome +
            //      threshold) is the same in this mode regardless of
            //      how long the content actually is.
            //
            // The threshold is computed so that chrome + threshold ≈
            // maxPanelHeight, i.e. the switch happens at the moment
            // the panel would otherwise grow past the screen.
            //
            // GeometryReader measures the content's intrinsic height
            // even inside the ScrollView (the content is sized to its
            // intrinsic and the ScrollView scrolls it), so the
            // measurement stays consistent across mode switches.
            contentArea

            Divider().opacity(0.3)

            // Bottom area: full button row in awaitingAccept; text
            // hint in every other state. The buttons surface Copy /
            // Cancel / Accept; the trailing [hold ⌥] refine hint
            // preserves the third affordance (which is a hotkey
            // gesture, not a clickable control) so users know it's
            // still available alongside the buttons.
            if model.state == .awaitingAccept {
                // Single-line footer: Copy on left, then Cancel, the
                // paste-target inline (so Accept is visually paired
                // with its destination), then Accept on the right.
                // The "hold ⌥ to refine" affordance is documented on
                // the staging-state hint + naturally discoverable;
                // we drop the explicit footer hint here to keep the
                // row to one line.
                OverlayButtons(
                    isKey: model.isKey,
                    // Mirror sendToPressed()'s gate so the V hint is
                    // hidden when reference windows (hence the window
                    // picker) are disabled.
                    sendToEnabled: model.referenceWindowsEnabled,
                    pasteTarget: model.pasteTarget,
                    conflict: headerBadgeState.conflict,
                    visionFallbackOption: firstConfiguredVisionModel(in: headerBadgeState.pickerEntries),
                    onCopy: onCopy,
                    onCancel: onCancel,
                    onAccept: onAccept,
                    // M2 fix: Switch button triggers re-cleanup with the
                    // new provider, not just a badge flip. AppState retains
                    // lastRawTranscript so re-cleanup works on the original
                    // spoken words.
                    onSwitchToVisionModel: onSwitchToVisionModelAndRecleanup,
                    onDowngrade: { model.userDowngradedConflict = true }
                )
            } else {
                // Active-state footer row: paste-target on the left
                // (same "PASTING TO" treatment as the .awaitingAccept
                // footer next to Accept — see PastingToLabel) +
                // contextual hint on the right. The chip surfaces
                // earlier than streamed text, so latched-compose
                // flows that inadvertently shift focus (e.g. clicking
                // an Add-from-clipboard button that activates a
                // different app) make the change visible immediately
                // instead of waiting for the LLM output to appear.
                //
                // Suppress the legacy "Release ⌥ when done" hint
                // whenever we're in a latched-compose state — the
                // OverlayHintStrip below renders the correct
                // contextual hint instead. Without this guard the
                // hint ("Release ⌥ when done") would show ALONGSIDE
                // the latched hint ("Hold ⌥-Right or release to send
                // …"), which contradicts itself (the user has
                // already released, "release" isn't the next
                // action).
                HStack(spacing: 8) {
                    if showsActiveFooterPasteTarget,
                       let target = model.pasteTarget {
                        PastingToLabel(target: target)
                    }
                    Spacer(minLength: 8)
                    if model.composeState == .idle || model.composeState == .recording {
                        footer
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Reference Windows v2 latched-compose hint strip. Renders
            // empty (EmptyView) when composeState is .idle so users
            // who never enter the latched flow see no UI change.
            OverlayHintStrip(
                state: model.composeState,
                hotkeyDisplayName: model.hotkeyDisplayName,
                referenceWindowsEnabled: model.referenceWindowsEnabled,
                spaceArmedDuringHold: model.spaceArmedDuringHold
            )

            // One-time "Learn from corrections" nudge with an inline
            // toggle — review state only, below the hint strip.
            if model.state == .awaitingAccept {
                learnLine
            }

            // Transform-preset chips + per-app-default styled chip —
            // review state only, fixed footer.
            if model.state == .awaitingAccept {
                presetRow
            }
        }
        .padding(16)
        // Background surface: Liquid Glass on macOS 26+, translucent
        // material fallback below. Toggle via PARLEQ_LIQUID_GLASS env.
        .parleqPanelBackground(cornerRadius: 12)
        .padding(8)  // shadow breathing room
        // Width is fixed; height is naturally driven by the children
        // (which switch from direct content → fixed-height ScrollView
        // once the content crosses scrollThreshold).
        .frame(width: width)
        // Measure the actually-laid-out body height and publish it up
        // to OverlayWindow so the panel can resize to match. This
        // replaces NSHostingController's preferredContentSize auto-
        // track (dead in our setup — see onBodyHeightChange doc).
        .background(
            GeometryReader { geom in
                Color.clear
                    .preference(
                        key: OverlayBodyHeightKey.self,
                        value: geom.size.height
                    )
            }
        )
        .onPreferenceChange(OverlayBodyHeightKey.self) { newHeight in
            onBodyHeightChange(newHeight)
        }
        // Drag-and-drop: accept file URLs, images, and text onto the
        // overlay surface. Drops are forwarded through the same factory
        // helpers as the + menu items (Task 11). Gated to .staging /
        // .awaitingAccept — other states reject silently. Also gated
        // by fileReferenceEnabled (and referenceWindowsEnabled as the
        // parent): when file drop is disabled, the drop handler is
        // not installed and the system shows the "not allowed" cursor.
        .onDrop(
            of: featureState.referenceWindowsEnabled && featureState.fileReferenceEnabled
                ? [UTType.fileURL, UTType.image, UTType.text]
                : [],
            isTargeted: $isDragOver
        ) { providers in
            return handleDrop(providers: providers)
        }
        // Brand-orange border tint while a drag is hovering. The
        // allowsHitTesting(false) is critical so the highlight doesn't
        // intercept pointer events while the user is dragging.
        .overlay {
            if isDragOver {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(SettingsView.brandAccent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        // Refresh the cached learn-feature flags off the per-render path:
        // once on appear, and again whenever the dictation state changes
        // (the nudge only shows in .awaitingAccept, so this is current by
        // the time it could render).
        .onAppear { refreshLearnFeatureFlags() }
        .onChange(of: model.state) { _, _ in refreshLearnFeatureFlags() }
    }

    /// Read the learn-feature gating from Config once and cache it, so the
    /// `learnLine` builder doesn't call Config.load() (a disk read) on every
    /// body evaluation during the accept countdown. Also refreshes the cached
    /// preset chips for the review footer (same single Config.load call).
    private func refreshLearnFeatureFlags() {
        let cfg = Config.load().config
        learnFeatureEnabled = cfg.learnFromCorrectionsEnabled
        learnFeatureManaged = cfg.managedKeys.contains("learnFromCorrectionsEnabled")
        presetChips = cfg.transformPresetsEnabled ? cfg.transformPresets : []
    }

    /// The content's intrinsic height threshold above which the
    /// content area switches from "direct render, panel grows" mode to
    /// "fixed-height ScrollView, panel pinned" mode. Chosen so that
    /// chromeApprox + threshold ≈ maxPanelHeight — i.e. the switch
    /// happens at the moment the body would otherwise grow past the
    /// screen.
    ///
    /// Over-estimating the chrome leads to a slightly smaller content
    /// area in scroll mode (harmless). Under-estimating it would let
    /// the panel briefly exceed maxPanelHeight before the switch
    /// catches; with the chrome estimate at 200pt that's an acceptable
    /// margin for the layout we have today.
    private var scrollThreshold: CGFloat {
        let chromeApprox: CGFloat = 200
        return max(120, maxPanelHeight - chromeApprox)
    }

    /// Content area — direct render below the scroll threshold, fixed
    /// ScrollView above it. Both branches measure the content's
    /// intrinsic height via the same GeometryReader-on-background
    /// pattern, so the mode-switch decision is stable across paints.
    @ViewBuilder
    private var contentArea: some View {
        let measuredContent = content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geom in
                    Color.clear
                        .preference(
                            key: OverlayContentHeightKey.self,
                            value: geom.size.height
                        )
                }
            )

        Group {
            if measuredContentHeight <= scrollThreshold {
                measuredContent
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        measuredContent
                            .id("content-bottom")
                    }
                    .frame(height: scrollThreshold)
                    .onChange(of: model.text) { _, _ in
                        proxy.scrollTo("content-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .onPreferenceChange(OverlayContentHeightKey.self) { newHeight in
            if abs(measuredContentHeight - newHeight) > 0.5 {
                measuredContentHeight = newHeight
            }
        }
    }

    // MARK: - Structural sub-views

    /// Single combined chrome row: paste-target chip (left, fixed) +
    /// reference chips (middle, horizontally scrolling) + window-picker
    /// button (right, pinned). One row instead of two keeps the panel
    /// compact — the panel anchors at the bottom edge of the visible
    /// screen and grows upward as content fills, so every chrome row
    /// we save reduces the risk of the panel's top extending past the
    /// menu bar on long transcripts.
    @ViewBuilder
    private var headerStrip: some View {
        let features = featureState
        HStack(spacing: 8) {
            // Reference chips — only shown when referenceWindowsEnabled.
            // When disabled, the whole chip strip and + menu are hidden
            // so the header just shows the model badge.
            if features.referenceWindowsEnabled {
                // Reference chips — scrollable horizontally when many
                // attached. The paste-target indicator used to live here
                // too, but moved to the footer (next to Accept) so it's
                // only displayed when there's something to actually paste.
                //
                // When no references are attached, the chip area would
                // otherwise be empty — leaving a blank header bar with
                // just a "+" floating at the right edge, which reads as
                // unfinished UI. Show a tertiary-color affordance hint
                // instead so the area has visible purpose.
                if model.references.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text("Add a reference window for context")
                            // SF Rounded for consistency with the
                            // listening-state hint — same family of
                            // secondary descriptive text.
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .accessibilityHidden(true)
                    Spacer()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.references) { ref in
                                ReferenceChip(
                                    reference: ref,
                                    onRemove: {
                                        model.references.removeAll { $0.id == ref.id }
                                    },
                                    // imageReferenceEnabled gates the T/👁 toggle:
                                    // when false, pass nil so the chip renders the
                                    // indicator dimmed with no click affordance.
                                    onToggleMode: (features.imageReferenceEnabled && isToggleEnabled(for: ref)) ? {
                                        if let i = model.references.firstIndex(where: { $0.id == ref.id }) {
                                            var updated = model.references[i]
                                            updated.captureMode = (updated.captureMode == .text) ? .image : .text
                                            model.references[i] = updated
                                        }
                                    } : nil
                                )
                            }
                        }
                    }
                }
            }

            // Model badge — shows the currently-resolved model and
            // opens the ModelPicker popover on tap. Placed before the
            // window-picker "+" so it reads left-to-right: chips →
            // model badge → add-window button. Routed through a
            // helper so the badge state is computed ONCE per body
            // evaluation (Config.load reads disk; per-property
            // computed-getters would re-read it 3× per render).
            modelBadgeRegion(headerBadgeState)

            // + Menu — shown only when referenceWindowsEnabled. Items
            // within the menu are further gated by sub-toggles:
            //   • "Add file…" hidden when fileReferenceEnabled is false
            //   • "Add from clipboard" hidden when clipboardReferenceEnabled is false
            // "Pick a window…" is always shown when the parent is on.
            if features.referenceWindowsEnabled {
                Menu {
                    Button("Pick a window…", action: onShowWindowPicker)
                    if features.fileReferenceEnabled {
                        Button("Add file…", action: pickFileAction)
                    }
                    if features.clipboardReferenceEnabled {
                        Button("Add from clipboard", action: addFromClipboardAction)
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Add reference")
            }
        }
    }

    /// Feature-toggle snapshot read once per body evaluation.
    /// Gates which overlay affordances are visible. Kept in a struct
    /// so we pay the Config.load() disk-read cost exactly once per body
    /// evaluation instead of once per sub-property access.
    private struct FeatureState {
        let referenceWindowsEnabled: Bool
        let clipboardReferenceEnabled: Bool
        let imageReferenceEnabled: Bool
        let fileReferenceEnabled: Bool
    }

    /// True for overlay states where the user is mid-composition and
    /// would benefit from seeing the live paste target ABOVE the
    /// streamed text. Excludes .awaitingAccept because that state
    /// already renders the chip inline next to Accept in
    /// OverlayButtons (visually paired with the action that uses it).
    /// Excludes .initializing / .staging because there's nothing to
    /// paste yet and the staging hint already covers the "get ready"
    /// semantics.
    private var showsActiveFooterPasteTarget: Bool {
        switch model.state {
        case .capturing, .cleaning, .refining:
            return true
        case .initializing, .staging, .awaitingAccept:
            return false
        }
    }

    private var featureState: FeatureState {
        let cfg = Config.load().config
        return FeatureState(
            referenceWindowsEnabled: cfg.referenceWindowsEnabled,
            clipboardReferenceEnabled: cfg.clipboardReferenceEnabled,
            imageReferenceEnabled: cfg.imageReferenceEnabled,
            fileReferenceEnabled: cfg.fileReferenceEnabled
        )
    }

    /// Bundle of badge-related state computed once per body
    /// evaluation. Consolidating into one struct + one computed
    /// property avoids the prior pattern of three separate
    /// computeds each calling Config.load() — that's a disk read
    /// per access, and SwiftUI may evaluate body many times per
    /// second.
    private struct HeaderBadgeState {
        let resolvedModel: ModelIdentifier
        let pickerEntries: [ModelPicker.ModelEntry]
        let conflict: ModelConflict?
    }

    private var headerBadgeState: HeaderBadgeState {
        let cfg = Config.load().config
        let resolvedModel = cfg.modelForInvocation(
            hasReferences: !model.references.isEmpty,
            override: model.pickedModelOverride
        )
        let cleanupId = ModelIdentifier(provider: cfg.llmProvider, model: cfg.llmModel)
        var ids: [ModelIdentifier] = [cleanupId]
        if let ctx = cfg.contextModel, ctx != cleanupId {
            ids.append(ctx)
        }
        let entries = ids.map { id in
            ModelPicker.ModelEntry(
                id: id,
                displayName: id.displayShort,
                supportsVision: ModelCapability.supportsVision(id)
            )
        }
        let conflict: ModelConflict?
        if model.userDowngradedConflict {
            conflict = nil
        } else {
            conflict = ModelConflict.from(
                modelSupportsVision: ModelCapability.supportsVision(resolvedModel),
                references: model.references
            )
        }
        return HeaderBadgeState(
            resolvedModel: resolvedModel,
            pickerEntries: entries,
            conflict: conflict
        )
    }

    @ViewBuilder
    private func modelBadgeRegion(_ state: HeaderBadgeState) -> some View {
        ModelBadge(
            currentModel: state.resolvedModel,
            conflict: state.conflict,
            onTap: { modelPickerShown.toggle() }
        )
        .popover(isPresented: $modelPickerShown, arrowEdge: .top) {
            ModelPicker(
                models: state.pickerEntries,
                selectedModel: state.resolvedModel,
                onPick: { picked in
                    model.pickedModelOverride = picked
                    modelPickerShown = false
                }
            )
        }
    }

    /// Returns the first vision-capable model among the configured
    /// picker entries, if any. Used to populate the conflict warning
    /// row's "Switch to <Model>" button.
    private func firstConfiguredVisionModel(in entries: [ModelPicker.ModelEntry]) -> ModelIdentifier? {
        return entries.first(where: { $0.supportsVision })?.id
    }

    /// Open an NSOpenPanel and add each selected file as a Reference.
    /// File UTI auto-selects .image or .text captureMode via the factory
    /// helper; errors surface through the existing errorMessage banner.
    private func pickFileAction() {
        // Parleq is .accessory + uses .nonactivating overlay panels, so
        // NSOpenPanel opens without proper key-window status by default
        // — single clicks register but subsequent clicks are dead until
        // the user Cmd-Tabs away and back. Activating the app first
        // gives the panel the focus it needs on first appearance.
        NSApplication.shared.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // OverlayContent is a SwiftUI View (struct) — capture model by
        // value rather than self by weak (weak is class-only). The
        // model is a class reference, so it's the natural strong-but-
        // reference-counted capture for the async closures.
        let model = self.model
        let tracker = model.onTrackCaptureTask
        // Register the tracking task BEFORE the panel opens, so a
        // cancel/submit during the panel-open interval can cancel
        // it. Bridging panel.begin into a continuation lets the
        // Task body await the user's selection while remaining
        // cancellable. Without this the entire panel-open interval
        // is invisible to cancelPendingCaptures and a late
        // selection can append into a reset session.
        let task = Task { @MainActor in
            let urls: [URL] = await withCheckedContinuation { cont in
                panel.begin { response in
                    cont.resume(returning: response == .OK ? panel.urls : [])
                }
            }
            guard !Task.isCancelled, !urls.isEmpty else { return }
            for url in urls {
                guard !Task.isCancelled else { return }
                do {
                    let ref = try ScreenCaptureKitReferenceCapture.reference(forFileAt: url)
                    guard !Task.isCancelled else { return }
                    model.references.append(ref)
                } catch {
                    guard !Task.isCancelled else { return }
                    model.errorMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
        tracker?(task)
    }

    /// Read NSPasteboard and add the contents as a Reference.
    /// Image data → .image; text → .text. Shows the error banner if the
    /// pasteboard is empty or contains nothing we can use.
    private func addFromClipboardAction() {
        if let ref = ScreenCaptureKitReferenceCapture.referenceFromClipboard() {
            model.references.append(ref)
        } else {
            model.errorMessage = "Nothing to attach from clipboard."
        }
    }

    /// Handles a drag-and-drop event onto the overlay surface.
    ///
    /// Three payload types are accepted:
    ///   - fileURL — routed through ScreenCaptureKitReferenceCapture.reference(forFileAt:),
    ///     the same path as + → Add file…
    ///   - image — wrapped inline with a .clipboard source ("Dropped image"),
    ///     matching the in-memory lifecycle of the payload
    ///   - text — wrapped inline with a .clipboard source ("Dropped text")
    ///
    /// Drops are gated to .staging and .awaitingAccept (the two states
    /// where the chip strip is editable). All other states return false
    /// immediately so the system shows the "not allowed" cursor.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        switch model.state {
        case .staging, .awaitingAccept:
            break  // allowed
        default:
            return false
        }
        var accepted = false
        let model = self.model
        let tracker = model.onTrackCaptureTask
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                // Register the tracking task BEFORE the NSItemProvider
                // callback fires. Otherwise the window between drop-
                // acceptance and the callback is invisible to
                // cancelPendingCaptures — a cancel that lands in that
                // window would have no task to cancel, and the late
                // callback would append to a reset session.
                //
                // Main-actor Task (not Task.detached) so the closure
                // can freely capture `provider` (NSItemProvider isn't
                // Sendable from Swift 6's POV when it's accessible to
                // main-actor code). The synchronous file decode is
                // pushed onto an inner Task.detached so we don't
                // block the main actor on PDF/image reads.
                let task = Task { @MainActor in
                    let url: URL? = await withCheckedContinuation { cont in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            cont.resume(returning: url)
                        }
                    }
                    // Guard against non-file URLs (smb://, ftp://, http://
                    // etc.) that a malicious or misbehaving drag source
                    // could inject. Without this check, the URL would
                    // flow into Data(contentsOf:) / String(contentsOf:)
                    // inside reference(forFileAt:), triggering an
                    // outbound network request — leaking the fact
                    // that this user attempted to "open" the remote
                    // URL to whoever controls it. File-type validation
                    // lives inside reference(forFileAt:).
                    guard !Task.isCancelled, let url, url.isFileURL else { return }
                    do {
                        // Synchronous decode on the main actor. The
                        // Add-file picker path does this on a
                        // detached task to keep the UI snappy for
                        // multi-file selections, but drag-drop is
                        // a single-shot user-initiated action and a
                        // brief hitch is acceptable. Doing the work
                        // on the main actor also avoids a Sendable
                        // boundary on Reference (it holds NSImage).
                        let ref = try ScreenCaptureKitReferenceCapture.reference(forFileAt: url)
                        guard !Task.isCancelled else { return }
                        model.references.append(ref)
                    } catch {
                        guard !Task.isCancelled else { return }
                        model.errorMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
                tracker?(task)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                let task = Task { @MainActor in
                    let data: Data? = await withCheckedContinuation { cont in
                        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                            cont.resume(returning: data)
                        }
                    }
                    guard !Task.isCancelled, let data else { return }
                    let ref = Reference(
                        id: UUID(),
                        source: .clipboard(label: "Dropped image"),
                        label: "Dropped image",
                        appIcon: nil,
                        thumbnail: nil,
                        captureDate: Date(),
                        captureMode: .image,
                        textContent: nil,
                        imageData: data
                    )
                    model.references.append(ref)
                }
                tracker?(task)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                accepted = true
                let task = Task { @MainActor in
                    let str: String? = await withCheckedContinuation { cont in
                        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                            cont.resume(returning: obj as? String)
                        }
                    }
                    guard !Task.isCancelled, let str else { return }
                    let ref = Reference(
                        id: UUID(),
                        source: .clipboard(label: "Dropped text"),
                        label: "Dropped text",
                        appIcon: nil,
                        thumbnail: nil,
                        captureDate: Date(),
                        captureMode: .text,
                        textContent: str,
                        imageData: nil
                    )
                    model.references.append(ref)
                }
                tracker?(task)
            }
        }
        return accepted
    }

    /// A reference's mode can be flipped iff both representations are
    /// available. Window captures (Phase 2) retain both textContent and
    /// imageData. File + clipboard sources (Task 11) never produce both
    /// simultaneously, so the toggle is effectively locked for them.
    /// The explicit switch ensures future Source variants are a compile
    /// error rather than silently falling through.
    private func isToggleEnabled(for ref: Reference) -> Bool {
        switch ref.source {
        case .window:
            return ref.imageData != nil && ref.textContent != nil
        case .file:
            // Image files: locked to .image (no textContent).
            // Text files / PDFs: locked to .text (no imageData).
            // Only togglable iff BOTH happen to be present, which
            // none of the factory paths produce — so disabled.
            return ref.imageData != nil && ref.textContent != nil
        case .clipboard:
            // Same logic as .file — clipboard never produces both
            // representations simultaneously.
            return ref.imageData != nil && ref.textContent != nil
        }
    }

    /// Error / permission-prompt banner. Tapping it clears the message.
    @ViewBuilder
    private var errorBanner: some View {
        let message = model.errorMessage ?? model.permissionPrompt
        if let message = message {
            Button {
                if model.errorMessage != nil {
                    model.errorMessage = nil
                } else {
                    model.permissionPrompt = nil
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.10))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss: \(message)")
        }
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
        case .staging:
            // Staging: no audio, the user is curating references.
            // The header strip already shows the chip strip + + button
            // — render a clear hint here explaining what's about to
            // happen and how to leave.
            VStack(alignment: .leading, spacing: 6) {
                Text("Ready to dictate with references")
                    .font(.system(size: 17, weight: .medium))
                if model.references.isEmpty {
                    Text("Pick one or more windows from the picker, then press the hotkey to dictate.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("\(model.references.count) reference\(model.references.count == 1 ? "" : "s") attached. Press the hotkey to dictate, or Esc to cancel.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .capturing:
            // Centered, system-stock listening indicator. Replaces
            // the prior left-aligned SoundWaveBars (which were
            // mic-level driven and stopped animating during refine).
            // SF Symbol "waveform" with the .variableColor.iterative
            // .symbolEffect is the Tahoe-native animated treatment —
            // continuous animation, no dependency on per-buffer mic
            // levels, identical behavior in capture and refine.
            listeningIndicator(label: capturingHintText)
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
            VStack(alignment: .leading, spacing: 8) {
                Text(model.text)
                    .font(.system(size: 17))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Cleanup-failure decoration. AppState passes a
                // non-nil message when LLM cleanup threw — the user
                // is being shown the raw ASR transcript (the
                // fallback) and needs to know that's why it looks
                // less polished than usual, plus what to do to fix
                // it. Provider-specific hint comes from each
                // LLMProvider's `cleanupFailureHint`.
                if let failure = model.cleanupFailureMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                            .padding(.top, 2)
                        Text(failure)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .refining:
            VStack(alignment: .leading, spacing: 12) {
                Text(model.text)
                    .font(.system(size: 17))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0.55)
                let refineHint = model.microphoneName.map { "listening for refinement on \($0)…" } ?? "listening for refinement…"
                listeningIndicator(label: refineHint)
            }
        }
    }

    /// Centered listening indicator used by both .capturing and
    /// .refining. The visual is Parleq's own brand-orange bar pattern
    /// (the same shape as the menu-bar favicon), with per-bar heights
    /// driven by `model.level` — so it's the static Parleq logo at
    /// rest and an audio-reactive waveform when audio is coming in.
    @ViewBuilder
    private func listeningIndicator(label: String) -> some View {
        VStack(spacing: 10) {
            ParleqListeningIndicator(level: model.level)
            Text(label)
                // SF Rounded gives the label a touch of warmth that
                // pairs well with the rounded-rect listening bars,
                // without going whimsical. Body text + transcript
                // stay on SF Pro so the casual treatment is
                // localized to the listening hint.
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The user's actual hotkey name for footer hints, so they adapt to
    /// a rebind. Falls back to the neutral "the hotkey" (matching
    /// OverlayHintStrip — NOT an Option-specific glyph) only if the name
    /// hasn't been wired yet (pre-launch); in practice main.swift sets
    /// model.hotkeyDisplayName at startup.
    private var hotkeyLabel: String {
        model.hotkeyDisplayName.isEmpty ? "the hotkey" : model.hotkeyDisplayName
    }

    @ViewBuilder
    private var footer: some View {
        switch model.state {
        case .initializing:
            Text("[Esc] dismiss")
        case .staging:
            Text("[hold \(hotkeyLabel)] start dictating   [Esc] cancel")
        case .capturing:
            Text("Release \(hotkeyLabel) when done")
        case .cleaning:
            Text("[Esc] cancel")
        case .awaitingAccept:
            Text("[tap \(hotkeyLabel)] accept   [Esc] cancel   [hold \(hotkeyLabel)] refine")
        case .refining:
            Text("Release \(hotkeyLabel) when done")
        }
    }

    /// Inline hint shown next to the sound-wave bars during capture.
    /// When references are attached, the copy shifts from a generic
    /// "listening…" to a directive that teaches the reference-aware
    /// mental model — the user's utterance becomes an instruction to
    /// apply against the attached materials, not just dictation to
    /// be cleaned. The shift happens the moment a reference is added,
    /// so the user encounters it at the exact moment it becomes
    /// relevant.
    private var capturingHintText: String {
        if !model.references.isEmpty {
            return "say what to do with these references…"
        }
        if let mic = model.microphoneName {
            return "listening on \(mic)…"
        }
        return "listening…"
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

/// Parleq's listening visualization: five vertical rounded-rect
/// bars rendered in Parleq's brand orange. Each bar tracks a
/// different point in the recent mic-level history, so bumps in
/// loudness travel from right (newest) to left (oldest) and the
/// bars animate INDEPENDENTLY rather than the whole silhouette
/// scaling uniformly. At rest (history all zero) the bars sit at
/// the Parleq favicon's asymmetric pattern, so the icon literally
/// IS the Parleq logo when silent and morphs into an audio
/// waveform when speech comes in.
/// Internal (not private) so the quick-mode recording-pulse window can
/// reuse the exact same brand mark, keeping quick-dictation feedback
/// visually consistent with the in-overlay listening indicator.
struct ParleqListeningIndicator: View {
    /// Normalized 0…1 mic level driven by OverlayModel.level. Both
    /// .capturing and .refining states feed live values via
    /// AppState.openRecorder() → recorder.levelHandler →
    /// overlay.setLevel(_:), so the bars react identically in both.
    let level: Float

    /// Multiplier on the menu-bar favicon's 18pt-canvas dimensions.
    /// 2.5 puts the indicator at roughly 35×52pt — large enough to
    /// anchor the listening view, small enough to leave room for
    /// the hint label below.
    var scale: CGFloat = 2.5

    /// Brand favicon idle silhouette (heights in points pre-scale).
    /// When `history` is all zero (silence) every bar resolves to
    /// these values and the indicator reads as the Parleq logo.
    private let idlePattern: [CGFloat] = [5, 9, 14, 7, 11]

    /// Maximum additional height (pre-scale) a peak history sample
    /// (1.0) adds on top of a bar's idle height. Same boost for
    /// every bar so loudness reads as a uniform "swelling" rather
    /// than the middle bar dominating audio response.
    private let levelBoost: CGFloat = 14

    /// Rolling buffer of the last 5 mic-level samples — one per
    /// bar. Newest sample lands on the right (index 4); each new
    /// sample shifts older values left so a loud syllable visibly
    /// travels across the bars over time.
    @State private var history: [Float] = Array(repeating: 0, count: 5)

    var body: some View {
        HStack(alignment: .center, spacing: 1 * scale) {
            ForEach(0..<5, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(SettingsView.brandAccent)
                    .frame(width: 2 * scale, height: barHeight(at: i))
            }
        }
        .frame(height: peakHeight)
        .onChange(of: level) { _, newValue in
            withAnimation(.spring(response: 0.14, dampingFraction: 0.6)) {
                history.removeFirst()
                history.append(newValue)
            }
        }
    }

    private func barHeight(at index: Int) -> CGFloat {
        let raw = max(0, min(1, CGFloat(history[index])))
        // sqrt curve compresses the level→height response: quiet
        // speech (the bulk of real dictation) gets visibly larger
        // bars instead of barely lifting off the idle silhouette,
        // while loud peaks approach but don't blow past the cap.
        // Mirrors how analog VU meters weight perceived loudness
        // over raw amplitude — visually "more aggressive at low
        // levels, capped at high."
        let curved = sqrt(raw)
        return (idlePattern[index] + curved * levelBoost) * scale
    }

    /// Tallest possible bar height (middle bar at peak level). The
    /// HStack reserves this much vertical space so bars stay
    /// vertically centered in a stable region regardless of level.
    private var peakHeight: CGFloat {
        ((idlePattern.max() ?? 14) + levelBoost) * scale
    }
}
