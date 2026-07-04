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
    /// Deferred-shrink bookkeeping (see resizePanelToHeight): the most
    /// recent finite body measurement, and whether a shrink was held
    /// back during a streaming state awaiting the result-state settle.
    private var lastFiniteMeasuredHeight: CGFloat = 0
    private var shrinkDeferredDuringStreaming = false
    /// Animated-resize coalescing: at most ONE animated setFrame in
    /// flight. Overlapping animated setFrames (live evidence: a 787→231
    /// settle with a 231→210 correction fired into it) start from
    /// mid-flight frames — the animation machinery's private frame
    /// updates drift the origin off the bottom anchor (panel floats
    /// mid-screen) and land on stale targets. While one is in flight,
    /// later measurements queue; the trailing one applies at animation
    /// end, and the anchor is re-asserted either way.
    private var animatedResizeUntil: Date = .distantPast
    private var pendingResizeMeasurement: CGFloat?
    /// Bumped in hide(): the animation-completion callback captures the
    /// value at dispatch and early-returns on mismatch, so a stale
    /// callback from a prior session can't touch the next session's
    /// panel (180ms back-to-back race; review finding).
    private var resizeGeneration: UInt = 0
    /// Loop-breaker bookkeeping (see resizePanelToHeight +
    /// oscillationSettleHeight): the last few heights actually pushed to
    /// the panel via this method. A bistable SwiftUI layout can make the
    /// measured body height flip-flop between two values forever (live:
    /// 184 ↔ 201 after an in-place-edit teardown, 92k resize log lines +
    /// ~900 MB RSS until force-killed); the exact-equality no-op never
    /// catches a two-value cycle, so we detect the A→B→A reversal here and
    /// settle at the larger height. Reset on every show()/hide().
    private var recentAppliedTargets: [CGFloat] = []
    /// True only for the duration of the show() pre-size pass, during which
    /// the panel is intentionally NOT yet on screen. Lets resizePanelToHeight
    /// distinguish that legitimate hidden resize from the stray trailing
    /// preference callbacks that arrive AFTER hide() ordered the panel out
    /// (those must be dropped — resizing a dismissed panel forces a relayout
    /// that re-fires the measurement, sustaining the oscillation off-screen).
    private var isPresizing = false
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
    /// AppState wires this to run the preset at a 1-based position (digit
    /// key 1–9 in review). Returns true iff a preset was applied.
    public var onRunPresetNumber: ((Int) -> Bool)?
    /// AppState wires this to undo a per-app default style: re-runs plain
    /// cleanup (no transform addendum) from the retained raw transcript.
    public var onUndoStyle: (() -> Void)?
    // #85 in-place edit callbacks live on OverlayModel (set by AppState, like
    // onReauthSignIn); the panel forwards E → model.onEnterEdit. See OverlayModel.
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
        panel.onRunPresetNumber = { [weak self] n in self?.onRunPresetNumber?(n) ?? false }
        // ⌥digit → undo the on-device corrector's edit at that number. Routed
        // through the model callback AppState sets (like onEnterEdit).
        panel.onUndoCorrectionNumber = { [weak self] n in self?.model.onUndoCorrection?(n) ?? false }
        // #85: E enters edit mode (forwarded to the model callback AppState sets);
        // isEditing lets the panel suspend the single-key review gestures so the
        // focused editor owns the keyboard.
        panel.onEnterEdit = { [weak self] in self?.model.onEnterEdit?() }
        panel.isEditing = { [weak self] in self?.model.editing ?? false }

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
        //
        // These observers (and didChangeScreen below) hop via Task —
        // next-turn delivery is fine for state mirroring. Only the
        // didResize backstop uses MainActor.assumeIsolated, because it
        // needs its corrective setFrame to land in the SAME turn.
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

        // Reactive height backstop. AppKit can resize the panel through
        // private paths that bypass both our preference-key sizing chain
        // and the public setFrame overrides (observed: a focus cycle on a
        // content-full overlay ballooned the panel to the transcript's
        // unscrolled height with no setFrame log). Whatever the initiator,
        // didResize fires afterward — if the height exceeds the live
        // screen cap, snap back to the clamped frame.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees the main thread, so assume the
            // actor synchronously rather than enqueueing a Task — the
            // corrective setFrame then happens in the same turn, and
            // the didResize it fires re-enters through the (no-op)
            // guard instead of allocating a follow-up task.
            MainActor.assumeIsolated {
                self?.enforceHeightCapAfterExternalResize()
            }
        }
        // Trace screen migration (count-only). NSScreen.main follows
        // keyboard focus, so moving focus to another screen changes
        // which visibleFrame the height caps compute from — logging
        // both values pins that down if the external-resize balloon
        // ever recurs in the field.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let h = self.panel.screen?.visibleFrame.height ?? -1
                let mainH = NSScreen.main?.visibleFrame.height ?? -1
                OverlayWindow.logStderr(
                    "[parleq] overlay panel changed screen: panelScreenH=\(Int(h)) mainScreenH=\(Int(mainH)) frameH=\(Int(self.panel.frame.height))"
                )
            }
        }
    }

    /// Backstop invoked from NSWindow.didResizeNotification: if some
    /// path outside resizePanelToHeight grew the panel past the live
    /// screen cap, clamp it back. No-op for in-cap resizes.
    ///
    /// The cap derives from the PANEL's screen, not NSScreen.main:
    /// the backstop's trigger scenario is focus moving to another
    /// display, which is precisely when NSScreen.main (it follows
    /// keyboard focus) stops describing the screen the panel is on.
    private func enforceHeightCapAfterExternalResize() {
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let maxPanelHeight = OverlayWindow.computeMaxPanelHeight(visibleHeight: visible)
        var frame = panel.frame
        if frame.size.height > maxPanelHeight + 0.5 {
            OverlayWindow.logStderr(
                "[parleq] overlay panel ballooned externally to \(Int(frame.size.height)) " +
                "(cap \(Int(maxPanelHeight))) — snapping back"
            )
            frame.size.height = maxPanelHeight
            // Origin needs no correction here even if the external resize
            // displaced it: this setFrame goes through OverlayPanel's
            // applyAnchor override, which re-pins origin.y to the armed
            // anchoredBottomY on every call.
            panel.setFrame(frame, display: true, animate: false)
            return
        }
        // Origin-drift heal (spike): AppKit's private resize paths can
        // also MOVE the panel off its bottom anchor without exceeding
        // the cap — observed live as the panel floating mid-screen
        // after a large animated settle coincided with the
        // scroll→direct content flip. Whenever a resize lands with
        // origin.y off the armed anchor, snap it back through
        // applyAnchor (which re-pins origin on every setFrame).
        if let anchor = panel.anchoredBottomY,
           abs(frame.origin.y - anchor) > 1 {
            OverlayWindow.logStderr(
                "[parleq] overlay panel drifted off bottom anchor " +
                "(y=\(Int(frame.origin.y)) anchor=\(Int(anchor))) — snapping back"
            )
            panel.setFrame(frame, display: true, animate: false)
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

    /// Loop-breaker for a panel-resize feedback oscillation.
    ///
    /// The overlay sizes its NSPanel to the SwiftUI-measured body height,
    /// but a bistable layout (observed live after an in-place-edit
    /// `TextEditor` collapses back to a plain `Text`) can make that
    /// measurement flip-flop between two values forever: set the panel to
    /// A and it measures B; set it to B and it measures A. Each `setFrame`
    /// forces a relayout that re-fires the preference, so the cycle is
    /// self-sustaining and pegs the CPU. The exact-equality no-op in
    /// `resizePanelToHeight` (`abs(current - target) < 0.5`) only catches a
    /// *fixed point*, never a two-value cycle.
    ///
    /// Given the recently-applied heights and an incoming measurement,
    /// returns the height to settle at — the LARGER of the two flapping
    /// values, so the panel never clips its content — when the panel is in
    /// a SUSTAINED two-value cycle and `target` would continue it. Returns
    /// nil otherwise (apply `target` as-is). Settling at the larger value
    /// is what converges the loop (within a cycle or two of detection): the
    /// settle always redirects to the ceiling, so once the panel sits there
    /// the next reversal resolves to that same ceiling == current, the
    /// exact-equality no-op fires, and no `setFrame` (hence no relayout,
    /// hence no new measurement) follows — and because that no-op iteration
    /// records nothing, the ceiling can't stack up in the history and
    /// de-sync the detector.
    ///
    /// This is a SECONDARY, on-screen backstop. The primary fix for the
    /// reported crash — an off-screen loop after the panel was dismissed —
    /// is the `panel.isVisible || isPresizing` guard in resizePanelToHeight;
    /// a dismissed panel never reaches this heuristic at all.
    ///
    /// We require a *sustained* cycle — the last four applied heights must
    /// already alternate A,B,A,B and `target` must continue it (→A) — not a
    /// single A→B→A reversal. A lone grow-then-shrink-to-the-same-height is
    /// legitimate (e.g. typing a wrapping line in the in-place editor and
    /// deleting it), and must not leave the panel stuck one line too tall.
    /// The runaway flaps thousands of times, so it trips this within a few
    /// sub-second cycles regardless.
    ///
    /// `nonisolated` + pure so it's unit-testable off the main actor.
    nonisolated static func oscillationSettleHeight(
        incoming target: CGFloat,
        recentApplied: [CGFloat]
    ) -> CGFloat? {
        guard recentApplied.count >= 4 else { return nil }
        let d = recentApplied[recentApplied.count - 1]   // newest applied
        let c = recentApplied[recentApplied.count - 2]
        let b = recentApplied[recentApplied.count - 3]
        let a = recentApplied[recentApplied.count - 4]
        // Sustained A,B,A,B flap (a==c, b==d, a≠b) that `target` continues
        // back to A (== c). Sub-0.5pt jitter is the caller's exact-equality
        // no-op job, so compare with that tolerance throughout.
        let eq: (CGFloat, CGFloat) -> Bool = { abs($0 - $1) < 0.5 }
        if eq(a, c), eq(b, d), !eq(a, b), eq(target, c) {
            return max(c, d)
        }
        return nil
    }

    /// Resize the panel to match the SwiftUI body's measured height.
    /// Driven by OverlayBodyHeightKey via OverlayContent's outer
    /// .background(GeometryReader) — this is the replacement for the
    /// NSHostingController.preferredContentSize KVO chain (which never
    /// fires in our setup because we attach hc.view as a subview
    /// rather than installing hc as the panel's contentViewController,
    /// so the controller's viewDidLayout is never called).
    private func resizePanelToHeight(_ measuredHeight: CGFloat) {
        // Defense-in-depth (live crash, 2026-06-05): a greedy view in the
        // measured content (Color.clear under an unbounded proposal) can
        // push an INFINITE height through the preference chain, and
        // Int(infinity) in the log line below traps. Non-finite or
        // negative measurements are garbage by definition — drop them
        // with a count-only log instead of crashing.
        // Sanity bounds, not just finiteness: greatestFiniteMagnitude IS
        // finite and reached this path once (a maxHeight:.infinity root
        // answering the pre-show unbounded proposal) — any measurement
        // beyond plausible-screen scale is garbage, and Int() on it
        // traps. 50k pt comfortably exceeds any real display stack.
        guard measuredHeight.isFinite, measuredHeight >= 0,
              measuredHeight < 50_000 else {
            OverlayWindow.logStderr(
                "[parleq] overlay body-height resize: implausible measurement dropped"
            )
            return
        }
        lastFiniteMeasuredHeight = measuredHeight
        // Never resize a panel that isn't on screen. After accept()/cancel()
        // call hide() (panel.orderOut), the SwiftUI view tree stays alive and
        // can deliver a few trailing OverlayBodyHeightKey callbacks. Following
        // them would setFrame the dismissed panel, which forces a relayout that
        // re-fires the measurement — and if that measurement is bistable, the
        // overlay grinds in an off-screen resize loop the user can't even see
        // or dismiss (the live 92k-line / ~900 MB hang). The show() pre-size
        // pass legitimately sizes the panel while it's still hidden, so allow
        // that one carve-out via isPresizing.
        guard panel.isVisible || isPresizing else { return }
        // Cap against the PANEL's screen (NSScreen.main follows keyboard
        // focus and can be a different display) — same derivation as the
        // external-resize backstop and applyAnchor, so all three clamps
        // agree on multi-display setups. The SwiftUI-side max-height
        // inputs (maxContentHeight/maxPanelHeight passed at init) remain
        // launch-screen constants — a known cosmetic limitation that only
        // affects the inner scroll-switch threshold, never the panel
        // frame, which these clamps bound.
        let visible = ((panel.screen ?? NSScreen.main)?.visibleFrame.height) ?? 800
        let maxPanelHeight = OverlayWindow.computeMaxPanelHeight(visibleHeight: visible)
        var target = max(
            OverlayWindow.minHeight,
            min(maxPanelHeight, measuredHeight)
        )
        // Loop-breaker: if this measurement would reverse the just-applied
        // resize back to the value before it (A→B→A), settle at the larger
        // of the pair so the panel never clips its content. See
        // oscillationSettleHeight — this is what kills the live 184↔201 flap
        // even while the overlay is on screen (the isVisible guard above
        // only covers the dismissed-panel case).
        if let settle = OverlayWindow.oscillationSettleHeight(
            incoming: target, recentApplied: recentAppliedTargets
        ) {
            target = min(maxPanelHeight, settle)
        }
        var frame = panel.frame
        if abs(frame.size.height - target) < 0.5 {
            // Target equals the current frame — panel == card, so a pin
            // left over from a deferred shrink whose content regrew to
            // the held height has nothing to pin against. Release it
            // (review finding: it otherwise sticks until the next
            // resize or hide; benign but the invariant should be exact).
            if model.bottomPinned { model.bottomPinned = false }
            return
        }
        // Deferred shrink (maintainer-specified): while a cycle is
        // STREAMING (cleaning/refining), the panel only ratchets UP.
        // Between refinements the text resets and re-streams, so the
        // honest measurement legitimately collapses to the floor and
        // regrows — letting the panel follow it bounced multi-line
        // overlays every refine cycle. This is panel-side POLICY, not a
        // measurement cap (the distinction that broke the reverted
        // motion arc): lastFiniteMeasuredHeight keeps flowing, and the
        // held shrink settles exactly once at the result state (the
        // show(state: .awaitingAccept) hook), animated.
        if target < frame.size.height,
           panel.isVisible,
           model.state == .cleaning || model.state == .refining {
            shrinkDeferredDuringStreaming = true
            // Pin the card to the panel bottom for the hold's duration
            // (the panel is now intentionally taller than the card).
            model.bottomPinned = true
            OverlayWindow.logStderr(
                "[parleq] overlay shrink deferred: target=\(Int(target)) held=\(Int(frame.size.height))"
            )
            return
        }
        // Spike (state-transition smoothness): animate ONLY outside the
        // streaming states — state swaps and the end-of-cycle settle.
        // Streaming growth snaps instantly (the proven engine's
        // behavior): animating every chunk-sized growth step produced a
        // storm of overlapping 0.13s window animations (six in ~1s in
        // live evidence) that fought the bottom-anchor enforcement
        // through AppKit's private resize paths and left the panel
        // floating mid-screen. Only animate while visible — the
        // pre-show sizing pass must land instantly. Duration is the
        // fixed 0.13s in OverlayPanel.animationResizeTime.
        let streaming = model.state == .cleaning || model.state == .refining
        let animate = panel.isVisible && !streaming
            && abs(frame.size.height - target) >= 24
        // Coalesce: while an animated resize is in flight, queue this
        // measurement instead of stacking a second animation on top
        // (see animatedResizeUntil). The trailing measurement re-enters
        // this method at animation end with fresh state.
        if Date() < animatedResizeUntil {
            pendingResizeMeasurement = measuredHeight
            return
        }
        OverlayWindow.logStderr(
            "[parleq] overlay body-height resize: measured=\(Int(measuredHeight)) " +
            "maxPanel=\(Int(maxPanelHeight)) → target=\(Int(target))" +
            (animate ? " (animated)" : "")
        )
        frame.size.height = target
        // Record what we're about to push so oscillationSettleHeight can spot
        // an A→B→A reversal next time. Bounded to the last few; reset on
        // show()/hide() so a new session starts clean.
        recentAppliedTargets.append(target)
        if recentAppliedTargets.count > 4 {
            recentAppliedTargets.removeFirst(recentAppliedTargets.count - 4)
        }
        if animate {
            animatedResizeUntil = Date().addingTimeInterval(0.18)
            panel.setFrame(frame, display: true, animate: true)
            let generation = resizeGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.resizeGeneration == generation else { return }
                // Release the bottom pin only AFTER the shrink animation
                // completes (panel ≈ card again). Releasing before the
                // window shrank let SwiftUI re-center the card inside
                // the still-tall panel for a few frames — an upward
                // "pop" right at the settle (live finding).
                if self.model.bottomPinned { self.model.bottomPinned = false }
                if let pending = self.pendingResizeMeasurement {
                    // A newer measurement arrived mid-animation — apply
                    // it now (recomputes target/animate from scratch).
                    self.pendingResizeMeasurement = nil
                    self.resizePanelToHeight(pending)
                } else {
                    // Heal any origin drift the animation machinery left
                    // behind: re-assert the current frame through
                    // OverlayPanel.setFrame, whose applyAnchor forces
                    // origin.y back onto the bottom anchor.
                    self.panel.setFrame(self.panel.frame, display: true, animate: false)
                }
            }
        } else {
            // Snap path: panel == card immediately — safe to release the
            // pin in the same turn (no visual gap to pop in).
            if model.bottomPinned { model.bottomPinned = false }
            panel.setFrame(frame, display: true, animate: false)
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
        cleanupFailureMessage: String? = nil,
        cleanupFailureReauthable: Bool = false,
        appendMode: Bool = false
    ) {
        model.update(
            state: state,
            text: text,
            downloadProgress: downloadProgress,
            microphoneName: microphoneName,
            cleanupFailureMessage: cleanupFailureMessage,
            cleanupFailureReauthable: cleanupFailureReauthable,
            appendMode: appendMode
        )
        // Deferred-shrink settle point: a shrink that was held back
        // during the streaming states (see resizePanelToHeight) is
        // applied exactly once when the cycle lands in its result
        // state. If the result's own measurement already arrived via
        // the preference chain this re-apply no-ops (same target).
        if state == .awaitingAccept, shrinkDeferredDuringStreaming {
            shrinkDeferredDuringStreaming = false
            if lastFiniteMeasuredHeight > 0 {
                resizePanelToHeight(lastFiniteMeasuredHeight)
            }
        }
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
            // Fresh session: drop any prior session's applied-height history so
            // the oscillation breaker doesn't compare against stale values.
            recentAppliedTargets.removeAll()
            // This pre-size legitimately runs while the panel is still hidden;
            // isPresizing waives the isVisible guard in resizePanelToHeight for
            // its duration only. The pre-show path is synchronous (animate
            // requires panel.isVisible, which is false here), so no async work
            // escapes the flag.
            isPresizing = true
            resizePanelToHeight(fitting.height)
            isPresizing = false

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
        // Panel-screen derivation, matching resizePanelToHeight /
        // applyAnchor / the external-resize backstop.
        let visible = ((panel.screen ?? NSScreen.main)?.visibleFrame.height) ?? 800
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

    /// Raw-first display (task #53): enter .cleaning showing the raw
    /// transcript (or prior text on refine) immediately, marked
    /// provisional — readable and Enter-acceptable without waiting for
    /// the LLM. The first streamed chunk replaces it via a plain
    /// show(), which clears the flag in update().
    public func showProvisionalCleaning(text: String, isRefine: Bool = false) {
        show(state: .cleaning, text: text)
        model.provisionalText = true
        model.isRefine = isRefine
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
        // A shrink held back mid-cycle must not leak into the next
        // session — the fresh show() pre-sizes from scratch anyway.
        shrinkDeferredDuringStreaming = false
        model.bottomPinned = false
        // A refine accepted during the provisional phase would otherwise
        // leave isRefine set; the next session's footer would briefly
        // read "refining…" during its ASR phase (review finding).
        model.isRefine = false
        // Also reset the animated-resize coalescing state: a leftover
        // in-flight window from the prior session's settle would queue
        // (and thus skip) the next show()'s pre-size call, making the
        // panel appear at a stale frame and visibly jump (review
        // finding).
        animatedResizeUntil = .distantPast
        pendingResizeMeasurement = nil
        // Don't let this session's applied-height history bleed into the next
        // — the oscillation breaker must start each session with a clean slate.
        recentAppliedTargets.removeAll()
        resizeGeneration &+= 1
        // Contract hygiene: the field is documented as "the most recent
        // finite body measurement" — don't let a prior session's value
        // satisfy that description (review finding; no current reader
        // is affected, but a future one would be).
        lastFiniteMeasuredHeight = 0
        model.transientNotice = nil   // B1: clear any capture-failure notice
        panel.orderOut(nil)
    }

    /// B1: show a brief, self-dismissing notice (e.g. a dead-mic capture
    /// failure) instead of letting the overlay vanish silently. Reuses the
    /// normal show() machinery (the `.initializing` state is just a vehicle —
    /// `content`/`footer` render the notice while `transientNotice` is set), and
    /// auto-hides after `duration` unless superseded. Esc closes it early (via
    /// the panel's cancel path, which AppState routes to hide()).
    public func showTransientNotice(_ message: String, duration: TimeInterval = 2.5) {
        model.transientNotice = message
        show(state: .initializing, text: "")
        noticeGeneration &+= 1
        let gen = noticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.noticeGeneration == gen,
                  self.model.transientNotice == message else { return }
            self.hide()
        }
    }
    private var noticeGeneration = 0

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
    /// #85: bare E during review → enter in-place edit mode.
    var onEnterEdit: (() -> Void)?
    /// #85: true while the editor is focused. When editing, keyDown must NOT
    /// intercept the single-key review gestures — the editor (and its onKeyPress
    /// handlers for ⌘Return/⌘S/Esc) owns the keys.
    var isEditing: () -> Bool = { false }
    /// Bare digit 1–9 during review → apply the preset at that 1-based
    /// position. Returns true iff a preset was actually applied, so
    /// keyDown can consume the event only on a hit and let an unmapped
    /// digit fall through inert.
    var onRunPresetNumber: ((Int) -> Bool)?
    /// Option+digit 1–9 during review → undo the on-device corrector's edit at
    /// that 1-based number (Concord tier only). Option deconflicts from the
    /// bare-digit preset gesture. Returns true iff a correction was reverted, so
    /// keyDown consumes the event only on a hit and lets an unmapped ⌥digit fall
    /// through inert.
    var onUndoCorrectionNumber: ((Int) -> Bool)?
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

    /// Spike (state-transition smoothness): fixed, short resize animation
    /// regardless of delta size. AppKit's default scales duration with the
    /// frame delta, which makes big state-transition jumps feel slow and
    /// floaty. Used only when resizePanelToHeight passes animate: true —
    /// the external-resize backstop and the initial show stay instant.
    /// NOTE: native setFrame(_:display:animate:) is the proven-safe path
    /// here; NSAnimationContext + animator() leaves this borderless
    /// non-activating panel invisible (see overlay sizing lessons).
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        0.13
    }

    private func applyAnchor(_ rect: NSRect) -> NSRect {
        var r = rect
        // Defensive height cap at the AppKit layer. No matter what
        // SwiftUI or the resize KVO computes, the panel physically
        // cannot exceed the screen's available height minus the
        // bottom anchor and a small breathing-room buffer. This is
        // the final say.
        //
        // Cap against the PANEL's screen (falling back to NSScreen.main
        // only when the panel has none): NSScreen.main follows keyboard
        // focus, and the external-resize backstop — whose snap-back
        // routes through this method — fires precisely in multi-display
        // focus-change scenarios where the two screens differ. The two
        // clamps must agree.
        if let screen = self.screen ?? NSScreen.main {
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

    /// #85: map an NSEvent to the pure OverlayKeymap.Key. Kept here (not on the
    /// SwiftUI/AppKit-free OverlayKeymap) so the enum stays unit-testable.
    private static func keymapKey(for event: NSEvent) -> OverlayKeymap.Key {
        switch event.keyCode {
        case 36, 76: return .returnKey
        case 53: return .escape
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": return .letterS
            case "e": return .letterE
            default: return .other
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        // #85: while the in-place editor is focused it owns the keyboard — never
        // run the single-key review gestures here. The editor's own onKeyPress
        // handles ⌘Return (commit+accept), ⌘S (save), and Esc (discard); any key
        // that reaches the panel during edit mode just falls through to type.
        if isEditing() {
            super.keyDown(with: event)
            return
        }
        // #85: route the edit-entry decision through the shared OverlayKeymap
        // table (the same table the editor's onKeyPress and the unit tests use)
        // so the panel and editor can't silently diverge. In review state only
        // bare E maps to .enterEditMode; everything else is a normal review key.
        if OverlayKeymap.action(
            key: OverlayPanel.keymapKey(for: event),
            hasCommand: event.modifierFlags.contains(.command),
            hasOtherModifiers: !event.modifierFlags
                .intersection([.shift, .control, .option]).isEmpty,
            isEditing: false) == .enterEditMode {
            onEnterEdit?()
            return
        }
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
            // (Bare "E" → edit mode is handled above via OverlayKeymap, before
            // this switch, so there's no "e" branch here.)
            } else if event.modifierFlags.contains(.option),
                      event.modifierFlags
                        .intersection([.command, .control]).isEmpty,
                      let g = baseGlyph, g.count == 1,
                      let digit = Int(g), (1...9).contains(digit) {
                // ⌥1–⌥9 → undo the on-device corrector's edit at that number.
                // Option deconflicts from the bare-digit preset gesture below.
                // `charactersIgnoringModifiers` is the base digit even with
                // Option held, so this resolves on every layout. Consume only
                // on a hit; otherwise fall through inert (no Concord highlights).
                if onUndoCorrectionNumber?(digit) != true {
                    super.keyDown(with: event)
                }
            } else if event.modifierFlags
                        .intersection([.command, .control, .option]).isEmpty,
                      let g = baseGlyph, g.count == 1,
                      let digit = Int(g), (1...9).contains(digit) {
                // 1–9 → apply the numbered transform preset. Shift is
                // ALLOWED here (unlike the bare V/C/P gestures) because on
                // AZERTY-style layouts the number row yields symbols
                // unshifted and digits only WITH Shift. `baseGlyph`
                // (charactersIgnoringModifiers) reflects Shift, so it is "1"
                // for both a US bare press AND an AZERTY Shift press, but "!"
                // for a US Shift+1 — which correctly is not a digit and so
                // doesn't fire. Cmd/Ctrl/Option are still excluded so real
                // shortcuts pass through. Consume the event only when a
                // preset was actually applied; otherwise fall through so an
                // unmapped digit stays inert.
                if onRunPresetNumber?(digit) != true {
                    super.keyDown(with: event)
                }
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

    /// #85: in-place edit mode. `editing` flips the awaitingAccept content from a
    /// read-only Text to a focused editor bound to `editableText`. Entered by E,
    /// left via ⌘S (save), ⌘Return (commit+accept), or Esc (discard).
    @Published var editing: Bool = false
    @Published var editableText: String = ""
    /// Task 7 (Feature A interaction): word-index range (Concord token
    /// indices) to focus once the editor gains focus, set only when edit mode
    /// was entered by routing a ⌥+N undo on a "considered" over-fire flag
    /// (`AppState.undoCorrection` via `enterEditMode(focusWordRange:)`)
    /// rather than by the plain E key. `nil` for an ordinary E-edit. Not yet
    /// wired to the editor's cursor placement — SwiftUI's `TextEditor` has no
    /// selection-range binding in use today — this is the seam for that
    /// follow-up; for now it signals "this edit was opened at a specific
    /// word."
    @Published var editFocusWordRange: Range<Int>? = nil

    /// Correction highlights for the on-device "Lightweight" (Concord) tier:
    /// the spans Concord changed vs. the raw ASR, numbered 1..N in reading
    /// order. Drives the amber-tinted highlight + numbered badge in the
    /// awaitingAccept text, and the Option+digit per-correction undo. Empty for
    /// cloud providers (they emit no EditRecords) and after a manual edit (the
    /// ranges no longer map cleanly). Set by AppState from
    /// ConcordCleanupProvider.appliedEditsForOverlay(); cleared on every state
    /// change in update() so a prior turn's highlights never leak.
    #if Concord
    @Published var correctionSpans: [CorrectionSpan] = []
    #endif

    /// Invoked when the user presses Option+digit on a numbered correction —
    /// reverts THAT correction (replacement → original) and feeds the revert to
    /// the CorrectionJournal. AppState sets this (model-level, like onEnterEdit).
    /// Returns true iff a correction at that number existed and was reverted.
    var onUndoCorrection: ((Int) -> Bool)?

    /// B1: when set, the overlay shows this transient notice (e.g. "Didn't catch
    /// any audio — check your microphone") instead of the state-based content —
    /// so a dead-input capture is visible + re-dictatable rather than vanishing.
    /// Cleared on hide()/next show().
    @Published var transientNotice: String? = nil
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

    /// Drives the signed-out notice's tappable behavior when the
    /// cleanup failure is org-sign-in-recoverable (enterprise OIDC
    /// federation fail-closed). False for every other failure — those
    /// render the static hint exactly as before. Gated to
    /// `.awaitingAccept` like `cleanupFailureMessage`.
    @Published var cleanupFailureReauthable: Bool = false

    /// True for an append-only refine result (a refine turn with no Polished
    /// provider): the spoken words were appended, not interpreted. Drives a
    /// subtle, non-error "append mode" note in `.awaitingAccept`. Gated to
    /// `.awaitingAccept` like `cleanupFailureMessage`; never an error.
    @Published var appendModeActive: Bool = false

    /// Re-auth interaction state for the signed-out notice. Only
    /// meaningful while `cleanupFailureReauthable` is true. Reset to
    /// `.signedOut` whenever a fresh failure message is applied.
    @Published var reauthState: ReauthState = .signedOut

    public enum ReauthState { case signedOut, signingIn, signedIn }

    /// Invoked when the user taps the signed-out notice. AppState runs
    /// interactive sign-in. Set in AppState init (model-level callback,
    /// matching `onTrackCaptureTask`).
    var onReauthSignIn: (() -> Void)?

    /// Invoked when the user taps the post-sign-in "clean up this
    /// dictation" affordance (↻). AppState re-runs cleanup from the
    /// retained raw transcript.
    var onReauthReclean: (() -> Void)?

    /// #85: in-place edit, invoked from the panel (E) and the editor's onKeyPress.
    /// onEnterEdit = E in review → focus the editor. onCommitEdit(true) = ⌘Return
    /// (apply edits + accept/paste); onCommitEdit(false) = ⌘S (apply edits, stay in
    /// review). onDiscardEdit = Esc (drop edits → review). AppState sets these
    /// (model-level, like onReauthSignIn).
    var onEnterEdit: (() -> Void)?
    var onCommitEdit: ((Bool) -> Void)?
    var onDiscardEdit: (() -> Void)?

    /// Name of the per-app default preset folded into the current
    /// dictation's cleanup, nil when none. Drives the review state's
    /// "Styled with <name> · Undo" chip.
    @Published var appliedPresetName: String?

    /// Per-target cleanup engine for the current dictation (Task 4). Set by
    /// AppState from the resolved mode. Drives the header engine badge, which
    /// renders ONLY for `.instant` / `.raw` (the notable, forced engines);
    /// `.polished` and nil fall through to the normal interactive model badge.
    /// A status label reflecting an automatic choice — never a selector.
    @Published var cleanupMode: TargetMode?

    /// Name of the transform preset currently being applied by a
    /// manual chip tap; drives the cleaning-state status line
    /// ("Applying <name>…"). Set in AppState.runPreset(id:) right
    /// before the in-flight Task is spawned; cleared immediately
    /// after applyResult() returns (success OR failure) AND in every
    /// early-exit / cancel path so the label can never leak into a
    /// subsequent dictation. Not set by undoStyle() (which is a
    /// plain cleanup re-run, not a named transform).
    @Published var activeTransformName: String?

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
    /// True while a panel shrink is deferred (streaming after a refine
    /// of long text): the panel is intentionally taller than the card,
    /// and the card pins to the hosting view's BOTTOM for the duration
    /// (SwiftUI's default centering floated it mid-screen). Must be
    /// false whenever panel == card — the expand-to-fill frame this
    /// drives corrupts the pre-show sizeThatFits query (it answered an
    /// unbounded proposal with greatestFiniteMagnitude → Int() trap).
    @Published var bottomPinned: Bool = false
    /// True while .cleaning displays the RAW transcript (or prior text
    /// on refine) before any cleaned token arrives — the raw-first
    /// display (task #53). Rendered dimmed; Enter accepts it as-is and
    /// kills the in-flight LLM stream. Cleared by the first streamed
    /// chunk's text replacement (via update()).
    @Published var provisionalText: Bool = false
    /// C1 (eager-accept deferral): true while an Enter pressed during
    /// .cleaning is being held until the cleanup stream completes. The
    /// footer shows a subtle "Finishing…" cue so the user knows the
    /// keypress registered and the full cleaned result will auto-accept.
    /// Set by AppState.accept(); cleared on the terminal transition / cancel.
    @Published var pendingAcceptArmed: Bool = false
    /// B2: true when the live mic watchdog has seen flat-zero input for ~1.5 s
    /// during capture — the overlay's listening view shows a "⚠ not hearing
    /// your mic" warning so a dead input is caught DURING the dictation
    /// instead of vanishing. Set by AppState's mic-signal handler; cleared at
    /// capture start and on any reset.
    @Published var notHearingMic: Bool = false
    /// True when the current .cleaning pass is a REFINE (the raw-first
    /// change made `text.isEmpty` useless as the refine heuristic — the
    /// provisional transcript populates text immediately, which made
    /// fresh cleanups read "refining…"; review finding). Set alongside
    /// the provisional show; cleared when leaving .cleaning.
    @Published var isRefine: Bool = false

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

    /// #83: true while a hands-free continuous recording is in progress, so the
    /// hint strip can show "tap or Esc to stop" instead of the hold-to-dictate copy.
    @Published var continuousRecording: Bool = false

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
        cleanupFailureMessage: String? = nil,
        cleanupFailureReauthable: Bool = false,
        appendMode: Bool = false
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
        // Moving to a real dictation phase supersedes any dead-input notice
        // (B1). Clearing it here stops the notice from rendering over a fresh
        // capture AND defuses its pending 2.5s auto-hide timer — whose guard
        // checks `transientNotice == message` — so the timer can't fire
        // mid-capture and hide() the live overlay (which would also collapse a
        // B3 recovery overlay).
        //
        // Gated on `state != .initializing` because `.initializing` is the
        // notice's OWN display vehicle: showTransientNotice() sets the notice
        // and then calls show(.initializing), which routes through THIS method
        // (show → update). An unconditional clear would null the notice the
        // instant it's shown, silently breaking B1. Every other state is a real
        // phase that should supersede a stale notice. (RoboRev B1/B3/B2 follow-up.)
        if state != .initializing { self.transientNotice = nil }
        // Cleanup-failure message is only relevant in
        // `.awaitingAccept` — that's where the user reviews the
        // text + decides whether to paste raw. Cleared elsewhere
        // so stale messages don't follow a successful cleanup turn.
        self.cleanupFailureMessage = (state == .awaitingAccept) ? cleanupFailureMessage : nil
        // Reauth affordance follows the same .awaitingAccept gating. A
        // fresh failure resets the interaction to .signedOut; reauthState
        // is only read while the flag is true, so clearing the flag off
        // .awaitingAccept is sufficient teardown.
        let reauthableNow = (state == .awaitingAccept) ? cleanupFailureReauthable : false
        self.cleanupFailureReauthable = reauthableNow
        if reauthableNow { self.reauthState = .signedOut }
        // Append-mode note follows the same .awaitingAccept gating; cleared
        // elsewhere so it doesn't follow a later interpreted result.
        self.appendModeActive = (state == .awaitingAccept) ? appendMode : false
        // Every full update ends a provisional display: raw-first shows
        // set the flag explicitly AFTER calling update (see
        // OverlayWindow.showProvisionalCleaning); the first streamed
        // chunk replaces the text via a plain show()/update, landing
        // here and clearing it.
        self.provisionalText = false
        // isRefine survives WITHIN .cleaning (the first streamed chunk
        // re-shows and must not flip the label mid-stream) and clears
        // on any other state.
        if state != .cleaning { self.isRefine = false }
        // Correction highlights are only valid for the review of the SPECIFIC
        // cleaned text they were mapped against. Clear them on every transition
        // OFF .awaitingAccept (capturing/cleaning/refining) so a prior turn's
        // amber spans never leak onto a fresh utterance. AppState (re)sets them
        // immediately AFTER show(.awaitingAccept) for the Concord tier — that
        // assignment lands after this clear, so the review keeps its highlights.
        #if Concord
        if state != .awaitingAccept { self.correctionSpans = [] }
        #endif
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

// MARK: - PresetChipMetrics

/// Geometry constants shared by PresetChip's view code and the
/// width-fitting math — keep these in lockstep so the AppKit
/// estimate matches what SwiftUI renders.
///
/// All values are in points (pre-scale, density-independent).
///
/// NSFont is not Sendable under Swift 6, so fonts are created
/// on-the-fly inside the measurement helpers rather than stored
/// as static properties — the allocation cost is negligible
/// compared to the text-measurement call itself.
enum PresetChipMetrics {
    /// Horizontal padding applied on each side of the chip label
    /// (matches `.padding(.horizontal, 9)` in PresetChip).
    static let horizontalPadding: CGFloat = 9
    /// HStack inter-chip spacing (matches the `spacing: 6` on the
    /// HStack in `presetRow`).
    static let interChipSpacing: CGFloat = 6
    /// Maximum label width applied when the rendered text exceeds this
    /// value (matches `.frame(maxWidth: 120)` in PresetChip — see
    /// chipWidth(for:) which caps at this value before adding padding).
    static let labelMaxWidth: CGFloat = 120
    /// Footprint reserved for the "⋯" overflow menu when at least
    /// one chip overflows. Must cover the real rendered width of the
    /// ⋯ button: `.menuStyle(.borderlessButton)` renders a dropdown
    /// chevron alongside the glyph, making the actual footprint ~40pt
    /// not ~20pt. A few extra points above the true size are fine —
    /// they're absorbed by the trailing Spacer(minLength:0).
    static let overflowMenuReserve: CGFloat = 44
    /// Horizontal safety margin subtracted from the computed available
    /// width before fitting. Absorbs sub-pixel rounding, HStack
    /// justification slack, and any un-modelled padding so we don't
    /// accidentally spill one chip past the edge.
    static let safetyMargin: CGFloat = 14

    /// Rendered width of one chip for `title`: AppKit-measures the
    /// string with the chip font (size 11, weight .medium), caps at
    /// `labelMaxWidth` (matching the view's `.frame(maxWidth:)` guard),
    /// then adds the capsule horizontal padding on both sides plus
    /// a 2pt per-chip slack so rounding never clips the last inline chip.
    static func chipWidth(for title: String) -> CGFloat {
        let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let measured = (title as NSString)
            .size(withAttributes: [.font: chipFont]).width
        return min(measured, labelMaxWidth) + horizontalPadding * 2 + 2
    }

    /// AppKit-measures `string` with `nsFont` and returns the raw
    /// pixel width (uncapped). Use chipWidth(for:) for chip titles;
    /// use this for arbitrary strings such as "Undo".
    static func textWidth(for string: String, nsFont: NSFont) -> CGFloat {
        (string as NSString)
            .size(withAttributes: [.font: nsFont]).width
    }
}

// MARK: - Width-aware chip fitting

/// Returns how many leading chips from `widths` fit in `available`
/// points.
///
/// - If ALL chips fit (no overflow), returns `widths.count` — no
///   overflow-reserve is held back because no ⋯ menu will appear.
/// - Otherwise returns the largest *k* such that the first *k* chips
///   (widths + inter-chip spacing) PLUS the overflow-menu reserve fit
///   within `available`.  k == 0 means even a single chip won't fit
///   after accounting for the reserve; all chips go into the ⋯ menu.
///
/// Pure function — no AppKit / SwiftUI calls; unit-testable from the
/// test target without a host application.
nonisolated func fittingChipCount(
    widths: [CGFloat],
    available: CGFloat,
    spacing: CGFloat,
    overflowReserve: CGFloat
) -> Int {
    guard !widths.isEmpty else { return 0 }

    // Try the all-fit case first (no overflow reserve needed).
    var total: CGFloat = 0
    for (i, w) in widths.enumerated() {
        total += (i > 0 ? spacing : 0) + w
    }
    if total <= available { return widths.count }

    // Overflow: greedy fit with the ⋯ reserve held back.
    var used: CGFloat = 0
    var count = 0
    for w in widths {
        let next = used + (count > 0 ? spacing : 0) + w
        if next + spacing + overflowReserve > available { break }
        used = next
        count += 1
    }
    return count
}

// MARK: - Preset number-key mapping

/// Bare digit keys 1–9 apply the transform preset at that 1-based
/// position in `config.transformPresets`. Presets past the 9th are
/// click-only (no digit, no key) — double-digit keystrokes aren't worth
/// it and `0` is an awkward "10th". This cap governs both the digit
/// drawn on a chip and which keypresses resolve to a preset.
let maxNumberedPresets = 9

/// Maps a pressed digit (1-based) to a zero-based index into the preset
/// array, or nil when the digit is outside 1…`maxNumberedPresets` or
/// beyond the available preset count. Pure — unit-testable without a host
/// app, mirroring `fittingChipCount`.
nonisolated func presetIndex(forNumber number: Int, presetCount: Int) -> Int? {
    guard (1...maxNumberedPresets).contains(number) else { return nil }
    let index = number - 1
    return index < presetCount ? index : nil
}

/// The 1-based number drawn on the chip at zero-based array `index`, or
/// nil for positions past `maxNumberedPresets` (no digit, no key). This is
/// the display-side inverse of `presetIndex(forNumber:presetCount:)`: both
/// derive from the same cap, so the digit shown on a chip and the digit
/// that resolves to it are guaranteed to agree. Pure — unit-testable.
nonisolated func presetNumber(forIndex index: Int) -> Int? {
    index < maxNumberedPresets ? index + 1 : nil
}

// MARK: - PresetChip view

// MARK: - ChromeSlotMetrics (spike: state-transition smoothness)

/// Equal-height chrome slots across overlay states, so a state swap
/// (capture → cleaning → accept) is height-NEUTRAL by construction and
/// the only thing that ever changes the panel height is the text area
/// growing — the "one chips-aware minimum height, growth only from the
/// text area" model. Each constant is a floor (minHeight) on the live
/// row and an exact height on its Color.clear reservation, so the two
/// sides agree.
private enum ChromeSlotMetrics {
    /// Content slot (listening indicator / transcript text) floor —
    /// ~2 lines of 17pt transcript.
    static let contentMin: CGFloat = 52
    // (A postReleaseContentMin compensation constant lived here briefly;
    // superseded by rendering the hold-time hint strip as a zero-height
    // overlay, which removed the asymmetry it compensated for.)
    /// Preset-chip strip (capsule ≈ 20pt + breathing room).
    static let chipsRow: CGFloat = 22
    /// Footer row (Copy/Cancel/Accept buttons or the hint line).
    static let footerRow: CGFloat = 28
}

/// One transform-preset capsule for the review strip. Dim at rest; the
/// gradient border + text brighten on hover (no ambient animation).
private struct PresetChip: View {
    let title: String
    let help: String
    /// 1-based preset number drawn in the left padding gutter, or nil for
    /// presets past `maxNumberedPresets` (no digit, no key).
    let number: Int?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            // Short titles (no cap applied) use .fixedSize so the HStack
            // can NEVER compress them — they take their measured width or
            // overflow into the ⋯ menu, never truncate mid-strip.
            // Long titles (cap applied) truncate at labelMaxWidth as before.
            let isLongTitle = (title as NSString)
                .size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
                .width > PresetChipMetrics.labelMaxWidth
            Group {
                if isLongTitle {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: PresetChipMetrics.labelMaxWidth)
                } else {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundColor(hovered ? .primary : .secondary)
            .padding(.horizontal, PresetChipMetrics.horizontalPadding)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(hovered ? 0.08 : 0.04)))
            .overlay(
                Capsule()
                    .strokeBorder(OverlayContent.aiGradient, lineWidth: 1)
                    .opacity(hovered ? 0.9 : 0.45)
            )
            .overlay(alignment: .leading) {
                if let number {
                    // Drawn INSIDE the capsule's existing 9pt left padding
                    // gutter. An overlay takes no part in layout, so the
                    // chip frame and the 22pt chips-row floor are unchanged
                    // and PresetChipMetrics.chipWidth (title-only) stays
                    // correct. The title is left-aligned after the 9pt
                    // padding, so this never overlaps the name.
                    Text("\(number)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(hovered ? .primary : .secondary)
                        .opacity(hovered ? 0.85 : 0.5)
                        .padding(.leading, 2)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .accessibilityHint("Apply this transform to the dictation")
    }
}

private struct OverlayContent: View {
    @ObservedObject var model: OverlayModel
    /// #85: focus for the in-place edit editor. Bound to model.editing so the
    /// editor grabs the keyboard the instant edit mode turns on.
    @FocusState private var editorFocused: Bool

    /// #85: map a SwiftUI KeyPress to the pure OverlayKeymap.Key. Kept out of
    /// OverlayKeymap so that enum stays SwiftUI/AppKit-free and unit-testable.
    private static func keymapKey(forKeyPress press: KeyPress) -> OverlayKeymap.Key {
        switch press.key {
        case .escape: return .escape
        case .return: return .returnKey
        default:
            switch press.characters.lowercased() {
            case "s": return .letterS
            case "e": return .letterE
            default: return .other
            }
        }
    }
    #if Concord
    /// Build the review text with the on-device corrector's changed spans
    /// highlighted: each `CorrectionSpan.range` gets a soft amber background
    /// tint + a brand-amber foreground, and a small superscript number badge is
    /// inserted right after it (so the user can see which Option+digit reverts
    /// it). Built as a single `AttributedString` so it wraps as one paragraph.
    ///
    /// Ranges are applied back-to-front so inserting the badge for an earlier
    /// span never invalidates the indices of a later one.
    static func highlightedReviewText(_ text: String, spans: [CorrectionSpan]) -> Text {
        var attributed = AttributedString(text)
        let amber = SettingsView.brandAccent
        // Sort by position descending so badge insertions don't shift the
        // String.Index ranges of spans we haven't processed yet.
        let ordered = spans.sorted { $0.range.lowerBound > $1.range.lowerBound }
        for span in ordered {
            // Convert the String.Index range to the AttributedString's index
            // space (the AttributedString was built from the same `text`).
            guard let lower = AttributedString.Index(span.range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(span.range.upperBound, within: attributed) else {
                continue
            }
            // Tint the replacement span.
            attributed[lower..<upper].backgroundColor = amber.opacity(0.18)
            attributed[lower..<upper].foregroundColor = amber

            // Insert a small superscript number badge right after the span.
            var badge = AttributedString("\(span.number)")
            badge.foregroundColor = amber
            badge.font = .system(size: 9, weight: .bold)
            badge.baselineOffset = 6
            attributed.insert(badge, at: upper)
        }
        return Text(attributed)
    }

    /// A compact legend under the review text: "⌥1 undo  ⌥2 undo …" so the user
    /// knows the Option+digit gesture and what each numbered span maps to.
    @ViewBuilder
    func correctionLegend(_ spans: [CorrectionSpan]) -> some View {
        let amber = SettingsView.brandAccent
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 10))
                .foregroundStyle(amber)
            Text(spans.count == 1
                 ? "1 on-device correction · ⌥1 to undo"
                 : "\(spans.count) on-device corrections · ⌥1–⌥\(min(spans.count, 9)) to undo")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("On-device corrector changed \(spans.count) word\(spans.count == 1 ? "" : "s"); press Option and a number to undo a correction")
    }
    #endif

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

    /// Warm "AI" gradient for the transform strip — anchored on the brand
    /// amber so the sizzle stays on-brand instead of introducing a foreign
    /// accent. Used by the sparkle glyph and chip borders.
    static let aiGradient = LinearGradient(
        colors: [SettingsView.brandAccent, Color(red: 0.95, green: 0.45, blue: 0.50)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Quiet transform-preset strip between the dictation text and the
    /// commit row — review state only. Lives in the FIXED footer (never
    /// the scrolling text) so reference-heavy overlays can't push it
    /// around. Mini capsule chips with a warm amber-anchored gradient
    /// border + sparkle glyph; hover transitions only, no ambient animation.
    ///
    /// Width-aware overflow: chip labels are measured deterministically
    /// with AppKit (PresetChipMetrics.chipWidth) against the FIXED
    /// overlay width (`width`). The greedy fittingChipCount() function
    /// decides how many chips render inline; the remainder, if any,
    /// overflow into a ⋯ menu. No GeometryReader — the overlay's
    /// height-plumbing uses that path and adding another one here
    /// risks fighting for the same preference keys.
    ///
    /// Available width formula (verified against the view hierarchy):
    ///   width
    ///   - (16 + 8) * 2  (.padding(16) content + .padding(8) shadow room, each side)
    ///   - sparkleReserve  (~12pt glyph + 6pt HStack spacing)
    ///   - styledBlockWidth (when appliedPresetName != nil:
    ///       min(ceil(measuredStyledText) + 1, 160) + 4 spacing
    ///       + measuredUndoText + interChipSpacing after the block
    ///       (the spacing only when chips follow); the label renders
    ///       at exactly that capped width)
    ///   - safetyMargin
    @ViewBuilder
    private var presetRow: some View {
        if !presetChips.isEmpty || model.appliedPresetName != nil {
            // ── width-aware fitting ─────────────────────────────────
            // The overlay width is fixed (OverlayWindow.fixedWidth),
            // so we measure the chip titles with AppKit and greedily
            // fit as many as possible into the remaining horizontal
            // space.  No GeometryReader — deterministic at body-eval time.
            // 16pt content padding + 8pt shadow breathing room, each side
            // (the view chain is VStack.padding(16)…padding(8).frame(width:)).
            let contentPadding: CGFloat = (16 + 8) * 2
            // Sparkle SF Symbol (~12pt at size-11 semibold) + HStack
            // spacing to the next element.
            let sparkleReserve: CGFloat = 12 + PresetChipMetrics.interChipSpacing

            // If a per-app style was applied, its "Styled with X · Undo"
            // block consumes some horizontal space before the chips start.
            // The label renders at EXACTLY this measured-and-capped width
            // (.frame(width:) below) so the fit math and the rendered
            // footprint can never disagree — a character-count heuristic
            // here once let a short-but-wide name render past its
            // reservation and crowd the chips off the edge.
            let styledLabelWidth: CGFloat? = model.appliedPresetName.map { name in
                let labelFont = NSFont.systemFont(ofSize: 11)
                // ceil + 1pt slack: an exact fractional width can trigger
                // tail-truncation on the text it was measured from.
                let measured = ceil(PresetChipMetrics.textWidth(
                    for: "Styled with \(name)", nsFont: labelFont)) + 1
                return min(measured, 160)
            }
            let styledBlockWidth: CGFloat = {
                guard let styledLabelWidth else { return 0 }
                let undoFont = NSFont.systemFont(ofSize: 11, weight: .medium)
                let undoWidth = PresetChipMetrics.textWidth(for: "Undo", nsFont: undoFont)
                // Inner HStack spacing (4) + outer HStack spacing to the
                // first chip (interChipSpacing = 6) — the latter only
                // when there IS a chip after the block.
                return styledLabelWidth + 4 + undoWidth
                    + (presetChips.isEmpty ? 0 : PresetChipMetrics.interChipSpacing)
            }()

            let availableWidth = width
                - contentPadding
                - sparkleReserve
                - styledBlockWidth
                - PresetChipMetrics.safetyMargin

            let widths = presetChips.map { PresetChipMetrics.chipWidth(for: $0.name) }
            let visibleCount = fittingChipCount(
                widths: widths,
                available: availableWidth,
                spacing: PresetChipMetrics.interChipSpacing,
                overflowReserve: PresetChipMetrics.overflowMenuReserve
            )
            // Pair each preset with its 1-based number (nil past the 9th).
            // Built from the original array index so a preset keeps its
            // number even when it falls into the ⋯ overflow.
            let numbered: [(id: String, number: Int?, name: String, prompt: String)] =
                presetChips.enumerated().map { idx, p in
                    (id: p.id,
                     number: presetNumber(forIndex: idx),
                     name: p.name,
                     prompt: p.prompt)
                }
            // ── render ──────────────────────────────────────────────
            HStack(spacing: PresetChipMetrics.interChipSpacing) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OverlayContent.aiGradient)
                    .help("Transform presets — applied before you insert")
                if let name = model.appliedPresetName, let styledLabelWidth {
                    HStack(spacing: 4) {
                        Text("Styled with \(name)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // Exact measured width (capped at 160) — keeps
                            // the rendered footprint identical to what the
                            // chip-fit math reserved above.
                            .frame(width: styledLabelWidth, alignment: .leading)
                        Button("Undo") { onUndoStyle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(SettingsView.brandAccent)
                            .help("Undo the applied style and re-run plain cleanup")
                            .accessibilityLabel("Undo style: \(name)")
                    }
                }
                ForEach(Array(numbered.prefix(visibleCount)), id: \.id) { np in
                    PresetChip(title: np.name, help: np.prompt, number: np.number) {
                        onRunPreset(np.id)
                    }
                }
                if visibleCount < presetChips.count {
                    Menu {
                        ForEach(Array(numbered.dropFirst(visibleCount)), id: \.id) { np in
                            Button(np.number.map { "\($0)  \(np.name)" } ?? np.name) {
                                onRunPreset(np.id)
                            }
                            .help(np.prompt)
                            .accessibilityHint("Apply this transform to the dictation")
                        }
                    } label: {
                        Text("⋯")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More transforms")
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
                // Spike: the animated listening icon is a CENTERED
                // OVERLAY on the content slot in both hold states — same
                // position whether the slot is empty (capture) or holds
                // the dimmed prior text (refine). Zero layout height, so
                // entering/leaving a hold never moves the panel; the
                // refine text dims further (0.35) so the icon reads
                // clearly on top of it.
                .overlay {
                    if model.state == .capturing {
                        listeningIndicator(label: model.references.isEmpty ? nil : "say what to do with these references…")
                    } else if model.state == .refining {
                        // The refine cue: the header carries "Refining on
                        // <mic>" only when the reference-windows header
                        // section renders (feature on + no refs attached).
                        // Everywhere else the label must live under the
                        // icon or default-config users see a bare icon
                        // with no explanation (review finding).
                        let headerCarriesCue = model.referenceWindowsEnabled
                            && model.references.isEmpty
                        listeningIndicator(label: headerCarriesCue ? nil
                            : (model.references.isEmpty
                                ? (model.microphoneName.map { "listening for refinement on \($0)…" }
                                    ?? "listening for refinement…")
                                : "say what to change…"))
                    }
                }

            Divider().opacity(0.3)

            // Bottom area: full button row in awaitingAccept; text
            // hint in every other state. The buttons surface Copy /
            // Cancel / Accept; the trailing [hold ⌥] refine hint
            // preserves the third affordance (which is a hotkey
            // gesture, not a clickable control) so users know it's
            // still available alongside the buttons.
            if model.state == .awaitingAccept {
                // Transform-preset strip — quiet capsule chips with a warm
                // amber-anchored gradient, between the dictation text and
                // the commit row (text → transform → accept). Fixed chrome
                // (never inside the scrolling text area). Hover transitions
                // only; no ambient animation.
                // Spike: floored to the chips-row slot height so the live
                // strip and the Color.clear reservation rendered by the
                // non-accept states agree. (.frame on the EmptyView case
                // stays zero — no reservation when no chips exist.)
                presetRow
                    .frame(minHeight: ChromeSlotMetrics.chipsRow)

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
                    // Only the configured, instance-backed models — the "Switch
                    // to <model>" button re-cleans immediately, so a catalog
                    // entry would fall back to a different model than claimed
                    // (same rule as the engine-badge picker).
                    visionFallbackOption: firstConfiguredVisionModel(
                        in: Array(headerBadgeState.pickerEntries.prefix(headerBadgeState.configuredCount))),
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
                // Spike: common footer-row floor (matches the hint row in
                // non-accept states) — see ChromeSlotMetrics.
                .frame(minHeight: ChromeSlotMetrics.footerRow)
            } else {
                // Spike: reserve the preset-chip strip's slot in
                // non-accept states (same condition presetRow uses) so
                // the chips arriving at accept don't change the panel
                // height. Color.clear, not EmptyView — .frame on
                // EmptyView is zero (see overlay sizing lessons).
                if !presetChips.isEmpty || model.appliedPresetName != nil {
                    Color.clear.frame(height: ChromeSlotMetrics.chipsRow)
                }
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
                // Spike: the latched-compose hint strip lives IN the
                // footer row during hold/latched states (it was its own
                // row, which made the panel grow ~34pt for the duration
                // of every hold; as a floating overlay it covered the
                // listening icon). At .idle the regular footer renders
                // as before (paste-target chip left, hint right); in
                // hold/latched states the strip's copy renders CENTERED
                // on the full row — the chip yields its width for the
                // duration of the hold and returns at release.
                HStack(spacing: 8) {
                    if model.composeState == .idle {
                        if showsActiveFooterPasteTarget,
                           let target = model.pasteTarget {
                            PastingToLabel(target: target)
                        }
                        Spacer(minLength: 8)
                        // Spike: while the LLM streams, the status label
                        // ("cleaning…/refining…", or the named transform)
                        // lives HERE in the persistent footer slot — as a
                        // content-area row it bounced the panel height
                        // for the stream's duration on 2+-line overlays.
                        if model.state == .cleaning {
                            HStack(spacing: 6) {
                                // LLM-processing ripple: the brand bars
                                // in the AI gradient's colors playing a
                                // fixed travelling wave — "thinking",
                                // visually distinct from the orange
                                // voice-reactive bars ("listening").
                                // Replaces the BlinkingDots as the
                                // liveness cue (maintainer-requested).
                                ParleqListeningIndicator(level: 0, scale: 0.55, processing: true)
                                if let transform = model.activeTransformName {
                                    Text("Applying \(transform)…")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text(model.isRefine ? "refining…" : "cleaning…")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                // Raw-first (task #53): the visible text
                                // is acceptable at any moment — say so.
                                if !model.text.isEmpty {
                                    Text("· ⏎ uses what's shown")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.secondary.opacity(0.8))
                                }
                            }
                        } else {
                            footer
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Spacer(minLength: 0)
                        OverlayHintStrip(
                            state: model.composeState,
                            hotkeyDisplayName: model.hotkeyDisplayName,
                            referenceWindowsEnabled: model.referenceWindowsEnabled,
                            spaceArmedDuringHold: model.spaceArmedDuringHold
                        )
                        Spacer(minLength: 0)
                    }
                }
                // Spike: same footer-row floor as the buttons row in
                // awaitingAccept — hint→buttons swap is height-neutral.
                .frame(minHeight: ChromeSlotMetrics.footerRow)
            }

            // Reference Windows v2 latched-compose hint strip: renders
            // inside the footer row (see the bottom-area else branch) so
            // it never contributes its own layout height.

            // Named transform status moved into the footer slot with the
            // anonymous cleaning…/refining… label (spike): status rows in
            // the layout flow bounced the panel for the stream's duration.

            // One-time "Learn from corrections" nudge with an inline
            // toggle — review state only, below the hint strip.
            if model.state == .awaitingAccept {
                learnLine
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
        // Spike: pin the card to the BOTTOM of the hosting view while a
        // shrink is deferred (streaming after a refine of long text) —
        // the panel is intentionally taller than the card then, and
        // SwiftUI's default centering floated the card mid-screen
        // inside the invisible panel, "jumping down" at the settle.
        // CONDITIONAL on bottomPinned: an unconditional
        // .frame(maxHeight: .infinity) answers the pre-show
        // sizeThatFits unbounded proposal with greatestFiniteMagnitude
        // (finite! → slipped the isFinite guard → Int() trap, live
        // crash 2026-06-06). When not pinned this is maxHeight: nil —
        // an identity for sizing. Applied OUTSIDE the height
        // measurement so the preference always reports the card.
        .frame(maxHeight: model.bottomPinned ? .infinity : nil, alignment: .bottom)
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
        // If MDM (or a config edit) disabled presets mid-session, also
        // retire an in-flight "Styled with X · Undo" chip — its Undo
        // action belongs to the now-disabled feature. New dictations
        // already honor the gate per-utterance via presetForApp; this
        // covers a review that was on screen when the flag flipped.
        if !cfg.transformPresetsEnabled {
            model.appliedPresetName = nil
        }
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
                // Log scroll-mode branch flips (count-only — no
                // transcript content). Flips are rare (a couple per
                // long dictation), and a flip back to direct-render on
                // a content-full overlay would mean measuredContentHeight
                // was reset (SwiftUI @State loss) — the suspected trigger
                // for the external-resize balloon the didResize backstop
                // defends against.
                let wasScroll = measuredContentHeight > scrollThreshold
                let isScroll = newHeight > scrollThreshold
                if wasScroll != isScroll {
                    FileHandle.standardError.write(
                        "[parleq] overlay content mode: \(wasScroll ? "scroll" : "direct") → \(isScroll ? "scroll" : "direct") (cntH=\(Int(measuredContentHeight))→\(Int(newHeight)) thresh=\(Int(scrollThreshold)))\n"
                            .data(using: .utf8) ?? Data())
                }
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
                    if model.state == .capturing || model.state == .refining {
                        // During active capture, replace the "Add a
                        // reference window" affordance with the live
                        // microphone label — more useful feedback when
                        // the user is actually speaking. Same font /
                        // styling / position as the hint it replaces.
                        // Spike: .refining shows its cue here too (the
                        // in-body indicator label moved out so refine
                        // doesn't change the content slot's height).
                        let listenLabel = model.state == .refining
                            ? (model.microphoneName.map { "Refining on \($0)" } ?? "Listening for refinement…")
                            : (model.microphoneName.map { "Listening on \($0)" } ?? "Listening…")
                        HStack(spacing: 5) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(listenLabel)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .accessibilityLabel(listenLabel)
                        Spacer()
                    } else {
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
                    }
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
            //
            // Per-target Instant/Raw (Task 4): show an EngineBadge that tells
            // the truth about what cleaned this dictation (⚡ Instant / Raw).
            // It stays clickable — opening the SAME model picker — so the
            // click-to-switch affordance is preserved; on a forced engine,
            // picking re-cleans this dictation with the chosen model. Polished
            // (and nil) keep the plain interactive model badge.
            switch model.cleanupMode {
            case .instant:
                engineBadgeRegion(.instant, headerBadgeState)
            case .raw:
                engineBadgeRegion(.raw, headerBadgeState)
            case .polished, .none:
                modelBadgeRegion(headerBadgeState)
            }

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
        /// Count of leading `pickerEntries` that are configured, instance-backed
        /// identifiers (cleanup + context) — the rest are catalog entries that
        /// fall back at invoke time. The engine badge's re-clean picker offers
        /// only this prefix.
        let configuredCount: Int
        let conflict: ModelConflict?
    }

    private var headerBadgeState: HeaderBadgeState {
        let cfg = Config.load().config
        // A styled dictation (a per-app or manual preset was applied — signalled
        // by appliedPresetName) runs through the REFINE tier, not the base
        // cleanup tier. Resolve the badge with that in mind so it names the model
        // that actually produced the text (e.g. the configured cloud model),
        // instead of the base cleanup model (which, for a Concord/Lightweight
        // global, would mislabel a cloud-styled result as "Lightweight").
        let styled = model.appliedPresetName != nil
        let resolvedModel = cfg.modelForInvocation(
            hasReferences: !model.references.isEmpty,
            isRefine: styled,
            override: model.pickedModelOverride
        )
        let cleanupId = ModelIdentifier(provider: cfg.llmProvider, model: cfg.llmModel)
        var ids: [ModelIdentifier] = [cleanupId]
        if let ctx = cfg.contextModel, ctx != cleanupId {
            ids.append(ctx)
        }
        // The refine tier is instance-backed too, so offer it in the picker —
        // otherwise a styled dictation's resolved (refine) model wouldn't be a
        // selectable entry.
        if let rfn = cfg.refineModel, rfn != cleanupId, !ids.contains(rfn) {
            ids.append(rfn)
        }
        // The configured (non-catalog) identifiers are the only ones backed by
        // a pre-built provider INSTANCE — catalog entries fall back at invoke
        // time (llmForInvocation logs + degrades). The Instant/Raw engine badge
        // RE-CLEANS on pick, so it must offer only these backed models, or the
        // badge would claim a model the fallback didn't actually run.
        let configuredCount = ids.count
        // Task #54: extend the picker with the configured providers'
        // CURATED CATALOG, so switching models is a picker tap instead
        // of a config edit. Rules:
        //   - configured entries stay first (they're what the user set
        //     up); catalog entries follow in catalog order;
        //   - only providers already configured for cleanup/context are
        //     offered (their credentials are known to work);
        //   - Azure is excluded — its "model" is a user-chosen
        //     DEPLOYMENT name, so canonical catalog names would 404 on
        //     most tenants;
        //   - the MDM cleanupAllowedModels allowlist (when pinned)
        //     filters catalog entries exactly as it curates Settings;
        //     configured entries are exempt (they already passed
        //     config-load policy enforcement).
        // Selection uses the existing pickedModelOverride semantics: a
        // one-off override for THIS dictation, never a config write.
        let managedAllowedModels = ManagedConfig.managedStringArray(forKey: "cleanupAllowedModels")
        var seenProviders = Set<String>()
        for provider in ids.map(\.provider) where !seenProviders.contains(provider) {
            seenProviders.insert(provider)
            guard provider != "azure" else { continue }
            for m in ModelCatalog.models(forProvider: provider) {
                let id = ModelIdentifier(provider: provider, model: m)
                guard !ids.contains(id) else { continue }
                if let allowed = managedAllowedModels, !allowed.contains(m) { continue }
                ids.append(id)
            }
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
            configuredCount: configuredCount,
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

    /// Header region for a forced-engine (Instant/Raw) dictation: the truthful
    /// EngineBadge, still clickable → the same model picker. Because Instant/Raw
    /// ignore `pickedModelOverride` on the current dictation, picking here
    /// RE-CLEANS this dictation with the chosen model (→ Polished) via the
    /// switch-and-recleanup path, rather than just setting an inert override.
    @ViewBuilder
    private func engineBadgeRegion(_ kind: EngineBadge.Kind, _ state: HeaderBadgeState) -> some View {
        // Offer ONLY the configured, instance-backed models — picking re-cleans
        // immediately, so a catalog entry (which falls back at invoke time)
        // would produce output from a different model than the badge claims.
        let backedEntries = Array(state.pickerEntries.prefix(state.configuredCount))
        EngineBadge(kind: kind, onTap: { modelPickerShown.toggle() })
        .popover(isPresented: $modelPickerShown, arrowEdge: .top) {
            ModelPicker(
                models: backedEntries,
                selectedModel: state.resolvedModel,
                onPick: { picked in
                    modelPickerShown = false
                    onSwitchToVisionModelAndRecleanup(picked)
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
    /// The org-sign-in notice. Reuses the failure-row visual (orange
    /// triangle + 12pt secondary text) but is a single tappable control
    /// whose icon, copy, and action follow `model.reauthState`. The
    /// whole row is the hit target; a pointing-hand cursor on hover
    /// signals clickability (minimal-change affordance, no chevron).
    @ViewBuilder
    private func reauthNoticeRow() -> some View {
        let signingIn = (model.reauthState == .signingIn)
        Button {
            switch model.reauthState {
            case .signedOut: model.onReauthSignIn?()
            case .signingIn: break // no-op while in flight
            case .signedIn:  model.onReauthReclean?()
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                switch model.reauthState {
                case .signedOut:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                        .padding(.top, 2)
                case .signingIn:
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 1)
                case .signedIn:
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                        .padding(.top, 2)
                }
                Text(reauthNoticeCopy)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(signingIn)
        .pointingHandCursor()
    }

    private var reauthNoticeCopy: String {
        switch model.reauthState {
        case .signedOut: return "Sign in to your organization"
        case .signingIn: return "Signing in…"
        case .signedIn:  return "Signed in — clean up this dictation"
        }
    }

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
        if let notice = model.transientNotice {
            // B1: transient capture-failure notice (dead mic), shown instead of
            // any state content.
            HStack(spacing: 10) {
                Image(systemName: "mic.slash.fill")
                    .foregroundStyle(.orange)
                Text(notice)
                    .font(.system(size: 15))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: ChromeSlotMetrics.contentMin, alignment: .leading)
        } else {
            stateContent
        }
    }

    @ViewBuilder
    private var stateContent: some View {
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
            // the ParleqListeningIndicator processing ripple
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
            // Centered listening indicator, icon only — the header
            // strip already shows "Listening on <mic>" so the label
            // below the icon is redundant here. Removing it keeps the
            // capture state compact and avoids the double label.
            // When references are attached the header shows the reference
            // chips; pass the teaching hint in that case so there's still
            // a listening cue.
            // Spike: the icon itself renders as a centered overlay on the
            // content slot (see contentArea's .overlay) — the in-flow
            // body is just the empty slot at the shared floor. Color.clear
            // (not EmptyView) so the reservation actually has size, and
            // an EXACT height (not minHeight): Color.clear is greedy, and
            // under an unbounded proposal a min-only frame reports an
            // INFINITE ideal height through the measurement preference —
            // which ballooned the panel and trapped Int(measuredHeight)
            // in resizePanelToHeight (live crash, 2026-06-05).
            Color.clear
                .frame(height: ChromeSlotMetrics.contentMin)
        case .cleaning:
            // Rigid floor: ZStack(max(floor, content)) — NOT
            // .frame(minHeight:), which is a FLEXIBLE frame that sizes
            // to the PROPOSAL (clamped), not the child. Under the
            // panel's bounded proposal that resolved to exactly the
            // floor and let the fixedSize text overflow invisibly out
            // the bottom (live evidence: chars=652 measured=52). The
            // exact-height Color.clear is rigid, so the ZStack reports
            // max(floor, real text height) and growth flows again.
            ZStack(alignment: .topLeading) {
                Color.clear.frame(height: ChromeSlotMetrics.contentMin)
                VStack(alignment: .leading, spacing: 6) {
                    if !model.text.isEmpty {
                        Text(model.text)
                            .font(.system(size: 17))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Raw-first: provisional (uncleaned) text
                            // reads dimmed so the upgrade to cleaned
                            // text is visually legible.
                            .opacity(model.provisionalText ? 0.55 : 1.0)
                    }
                    // Spike: the "cleaning…/refining…" status row moved to
                    // the footer slot (persistent chrome) — in here it added
                    // ~16pt below the text for the stream's duration and
                    // bounced any 2+-line overlay on every refine cycle.
                }
            }
        case .awaitingAccept:
            // Rigid floor — same ZStack pattern as .cleaning (see there).
            ZStack(alignment: .topLeading) {
                Color.clear.frame(height: ChromeSlotMetrics.contentMin)
                VStack(alignment: .leading, spacing: 8) {
                    if model.editing {
                        // #85: in-place edit. ⌘Return commits + accepts, ⌘S saves
                        // back to review, Esc discards; plain Return is a newline
                        // (default TextEditor behavior). Handled via onKeyPress so
                        // the editor keeps focus and the panel's review gestures
                        // stay suspended (OverlayPanel.isEditing).
                        TextEditor(text: $model.editableText)
                            .font(.system(size: 17))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: ChromeSlotMetrics.contentMin)
                            .focused($editorFocused)
                            .onAppear { editorFocused = true }
                            // #85: dispatch edit-mode keys through the shared
                            // OverlayKeymap decision table (the same one the unit
                            // tests cover), so the editor and the panel can't
                            // silently diverge. Non-handled keys return .ignored
                            // so ordinary typing / newline pass through.
                            .onKeyPress(phases: .down) { press in
                                switch OverlayKeymap.action(
                                    key: Self.keymapKey(forKeyPress: press),
                                    hasCommand: press.modifiers.contains(.command),
                                    hasOtherModifiers: !press.modifiers
                                        .intersection([.shift, .control, .option]).isEmpty,
                                    isEditing: true
                                ) {
                                case .commitAndAccept: model.onCommitEdit?(true); return .handled
                                case .saveAndReview: model.onCommitEdit?(false); return .handled
                                case .discardAndReview: model.onDiscardEdit?(); return .handled
                                case .insertNewline, .typeIntoEditor,
                                     .enterEditMode, .reviewKey:
                                    return .ignored
                                }
                            }
                    } else {
                        #if Concord
                        if !model.correctionSpans.isEmpty {
                            // On-device corrector highlight: amber-tint the spans
                            // Concord changed, with a small superscript number per
                            // span (Option+digit reverts that one). See
                            // highlightedReviewText.
                            Self.highlightedReviewText(model.text, spans: model.correctionSpans)
                                .font(.system(size: 17))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            correctionLegend(model.correctionSpans)
                        } else {
                            Text(model.text)
                                .font(.system(size: 17))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        #else
                        Text(model.text)
                            .font(.system(size: 17))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
                    }
                    // Cleanup-failure decoration. AppState passes a
                    // non-nil message when LLM cleanup threw — the user
                    // is being shown the raw ASR transcript (the
                    // fallback) and needs to know that's why it looks
                    // less polished than usual, plus what to do to fix
                    // it. Provider-specific hint comes from each
                    // LLMProvider's `cleanupFailureHint`.
                    if let failure = model.cleanupFailureMessage {
                        if model.cleanupFailureReauthable {
                            // Org-sign-in-recoverable fail-closed: the row
                            // is a single tappable control (see
                            // reauthNoticeRow). Reuses the same visual.
                            reauthNoticeRow()
                        } else {
                            // Unchanged static decoration for every
                            // non-reauthable failure.
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
                    } else if model.appendModeActive {
                        // Append-only refine: no Polished provider to interpret
                        // the instruction, so the spoken words were appended
                        // verbatim. A subtle, non-error note (no amber icon).
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "text.append")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                                .padding(.top, 2)
                            Text("Appended — add a Polished provider in Settings to refine.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        case .refining:
            // Spike: dimmed text only — the listening icon floats as a
            // centered overlay on the content slot (see contentArea) and
            // the refine cue lives in the header strip, so entering
            // refine doesn't change the content slot's height. 0.35
            // (down from the old 0.55) so the overlaid icon reads
            // clearly against the text.
            ZStack(alignment: .topLeading) {
                Color.clear.frame(height: ChromeSlotMetrics.contentMin)
                Text(model.text)
                    .font(.system(size: 17))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0.35)
            }
        }
    }

    /// Centered listening indicator used by both .capturing and
    /// .refining. The visual is Parleq's own brand-orange bar pattern
    /// (the same shape as the menu-bar favicon), with per-bar heights
    /// driven by `model.level` — so it's the static Parleq logo at
    /// rest and an audio-reactive waveform when audio is coming in.
    ///
    /// `label` is optional, and since the spike both call sites are the
    /// content-slot OVERLAY (zero layout height — see contentArea):
    /// .capturing passes nil when no references are attached (the header
    /// strip shows "Listening on <mic>"; a second label would duplicate
    /// it) and the teaching hint when references occupy the header.
    /// .refining passes nil only when the header carries the refine cue
    /// (reference windows enabled + no refs); otherwise the refine hint
    /// renders here so default-config users aren't left with a bare icon.
    @ViewBuilder
    private func listeningIndicator(label: String?) -> some View {
        VStack(spacing: 10) {
            ParleqListeningIndicator(level: model.level, scale: 1.5)
            // B2: a sustained dead-mic reading escalates the listening hint to
            // an explicit warning so a non-delivering mic is caught DURING the
            // dictation, not after it silently vanishes. Overrides the normal
            // listening label only while it's active.
            if model.notHearingMic {
                Text("⚠ Not hearing your mic — check your input device")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else if let label {
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
        }
        .padding(.vertical, 2)
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
        if model.transientNotice != nil {
            Text("[Esc] dismiss")   // B1: notice auto-dismisses; Esc closes it early
        } else {
            stateFooter
        }
    }

    @ViewBuilder
    private var stateFooter: some View {
        switch model.state {
        case .initializing:
            Text("[Esc] dismiss")
        case .staging:
            Text("[hold \(hotkeyLabel)] start dictating   [Esc] cancel")
        case .capturing:
            // #83: continuous (hands-free) recording is stopped by a tap, not a
            // release — show the matching hint.
            if model.continuousRecording {
                Text("Recording… [tap \(hotkeyLabel)] stop   [Esc] cancel")
            } else {
                // Note: during a real hold-to-talk capture composeState is
                // .recording, so OverlayHintStrip (not this stateFooter) renders
                // — the "R: recover" hint lives there. This branch only shows
                // when composeState == .idle (rare for .capturing).
                Text("Release \(hotkeyLabel) when done")
            }
        case .cleaning:
            // C1: a deferred eager-accept shows a subtle "Finishing…" cue so
            // the user knows the Enter registered and the full cleaned result
            // will paste itself the moment the stream completes.
            if model.pendingAcceptArmed {
                Text("Finishing… will accept   [Esc] cancel")
            } else {
                Text("[Esc] cancel")
            }
        case .awaitingAccept:
            // #85: in edit mode, show the editor keymap; otherwise the review
            // gestures plus the [E] edit affordance.
            if model.editing {
                Text("[⌘↵] accept   [⌘S] save   [esc] discard")
            } else {
                Text("[tap \(hotkeyLabel)] accept   [E] edit   [Esc] cancel   [hold \(hotkeyLabel)] refine")
            }
        case .refining:
            Text("Release \(hotkeyLabel) when done")
        }
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

    /// LLM-processing mode (task #53 follow-up): the bars stop tracking
    /// the mic and instead play a fixed self-driven ripple in the AI
    /// gradient's colors — visually distinct from the voice-reactive
    /// orange so the user can tell "Parleq is thinking" from "Parleq is
    /// listening" at a glance.
    var processing: Bool = false

    /// Per-bar colors for the processing ripple: a ramp through the AI
    /// gradient's endpoints (brand amber → warm coral) so the five bars
    /// read as one gradient sweep.
    private static let processingColors: [Color] = {
        // Manual RGB lerp (Color.mix needs macOS 15; we target 14):
        // brandAccent (0xd97706) → aiGradient's warm coral endpoint.
        let from: (Double, Double, Double) = (0xd9 / 255.0, 0x77 / 255.0, 0x06 / 255.0)
        let to: (Double, Double, Double) = (0.95, 0.45, 0.50)
        return (0..<5).map { i in
            let t = Double(i) / 4.0
            return Color(
                red: from.0 + (to.0 - from.0) * t,
                green: from.1 + (to.1 - from.1) * t,
                blue: from.2 + (to.2 - from.2) * t
            )
        }
    }()

    var body: some View {
        if processing {
            // Fixed ripple: a TimelineView-driven travelling sine over
            // the idle silhouette. No mic input involved.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 1 * scale) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule(style: .continuous)
                            .fill(Self.processingColors[i])
                            .frame(width: 2 * scale,
                                   height: processingBarHeight(at: i, time: t))
                    }
                }
                .frame(height: peakHeight)
            }
        } else {
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
    }

    /// Travelling-wave height for the processing ripple: each bar
    /// oscillates gently above its idle silhouette, phase-offset so a
    /// crest sweeps left→right about once a second. Amplitude is half
    /// the voice boost — calm, deliberate, unmistakably "working".
    private func processingBarHeight(at index: Int, time: TimeInterval) -> CGFloat {
        let phase = time * 2 * .pi * 0.9 - Double(index) * 0.9
        let wave = (sin(phase) + 1) / 2  // 0…1
        return (idlePattern[index] + CGFloat(wave) * (levelBoost * 0.5)) * scale
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

private extension View {
    /// Shows the macOS pointing-hand cursor while hovering. Used by the
    /// tappable signed-out re-auth notice so the minimal-change row reads
    /// as clickable. The `.onHover` is ALWAYS attached (never
    /// conditionally removed) so every push on enter is balanced by a pop
    /// on exit — conditionally dropping the modifier mid-hover would tear
    /// down the tracking area without a balancing pop and strand the
    /// pushed cursor. The hand briefly showing over the transient
    /// "Signing in…" state is an accepted cosmetic tradeoff for that
    /// balance.
    func pointingHandCursor() -> some View {
        self.onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
