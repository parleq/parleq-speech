// AppState — central state machine for the per-utterance lifecycle.
//
// One instance lives for the whole app. The hotkey listener calls
// `hotkeyDown` / `hotkeyUp`; the overlay calls `accept` / `cancel`;
// and an auto-accept timer fires `accept` after a delay. All
// transitions go through this object, so the rules for what's
// allowed when live in one place.
//
// The states correspond 1:1 to the design-doc state machine:
//
//     IDLE → CAPTURING → CLEANING → (PASTING → IDLE | IDLE)
//                              ↑
//                              ╰── REFINING ←─ hotkey while CLEANING
//
// PASTING is a near-instantaneous transient state (paste + close);
// we model it explicitly so an external observer can tell "we're
// committing the result" from "we're done."
//
// All callbacks are invoked on the main run loop because that's
// where the hotkey, overlay, and timer all originate. AppState is
// @MainActor so the compiler enforces this.

import AppKit
import Combine
import Foundation

@MainActor
public final class AppState {
    // MARK: - States and inputs

    public enum Phase: Equatable {
        case idle
        case staging                     // overlay open, no audio, user curating refs
        case capturing                   // mic is hot, audio streaming to ASR pipeline
        case cleaning                    // LLM cleanup in flight; overlay open
        case awaitingAccept              // cleanup done; overlay open with finished text
        case refining                    // mic hot again, refining the existing text
        case pasting                     // brief: pasting and closing
    }

    // MARK: - Dependencies

    private let recorder: AudioRecorder
    private let asr: ASRClient
    private let llm: (any LLMProvider)?
    /// Optional second provider for the context-model tier. When
    /// Config.contextModel is configured and the user has references
    /// attached, llmForInvocation() returns this instead of llm so
    /// the higher-capability model services reference-aware calls
    /// without changing the default cleanup provider.
    private let contextLLM: (any LLMProvider)?
    private let overlay: OverlayWindow

    // MARK: - Per-utterance state

    private(set) var phase: Phase = .idle {
        didSet {
            logPhase(from: oldValue, to: phase)
            if oldValue != phase { onPhaseChanged?(phase) }
        }
    }
    /// Called on every phase transition. Used by the menu-bar status
    /// item to keep its icon and "Status: …" line in sync with the
    /// current state. Set on @MainActor; called on @MainActor (didSet
    /// inside an @MainActor type runs on the main actor).
    public var onPhaseChanged: (@MainActor (Phase) -> Void)?

    /// Fired after every cleanup attempt to surface (or clear) the
    /// menu-bar cleanup-failure badge (#28). Non-nil message →
    /// cleanup just failed; the menu-bar icon goes amber and a
    /// dismissable "Cleanup failed — <message>" row appears in
    /// the dropdown. nil → cleanup just succeeded (or was skipped);
    /// the menu-bar reverts to normal. Wired in ParleqApp.main to
    /// MenuBar.setCleanupFailure(_:).
    ///
    /// Fires for every applyResult — both quick mode and the
    /// overlay path — so a successful normal-mode cleanup also
    /// clears any leftover badge from a prior quick-mode failure.
    /// The overlay-mode awaitingAccept decoration from #27 still
    /// surfaces the same hint inline, so users in normal mode see
    /// the failure twice (overlay + menu badge) — acceptable
    /// redundancy because the menu-bar badge is the only thing
    /// quick-mode users will see.
    public var onCleanupResult: (@MainActor (String?) -> Void)?
    private var pasteTarget: PasteTarget?
    private var currentText: String = ""        // last cleaned/refined text in the overlay
    /// True when the most recent applyResult came back with a
    /// cleanup-failure message — i.e. `currentText` is the raw ASR
    /// fallback rather than an LLM-cleaned version. Carried into the
    /// TranscriptHistory entry on accept (#27) so the Recent
    /// Dictations submenu can mark these as "raw" — useful when a
    /// user scans the history after a stretch of auth/network
    /// failures to spot dictations worth re-running with cleanup
    /// working. Reset by every fresh capture and by closeAndReset.
    private var lastCleanupFailed: Bool = false
    private var autoAcceptTimer: Timer?
    /// Timer that delays the initial overlay show on a fresh capture
    /// so a brief tap (the first half of a double-tap-and-hold, or a
    /// fumbled keypress) doesn't flash the overlay. Cancelled when
    /// the first partial transcript arrives, the utterance is
    /// short-circuited, or the user cancels.
    private var pendingOverlayShowTimer: Timer?
    private var inFlightTask: Task<Void, Never>?  // cleanup or refine task — cancel on abort
    /// Raw ASR transcript from the most-recent utterance. Retained so
    /// switchModelAndRecleanup(_:) can re-run cleanup with a different
    /// provider against the original spoken words rather than the
    /// already-cleaned text. Reset at the start of each fresh capture
    /// and cleared in closeAndReset().
    private var lastRawTranscript: String = ""
    // ConversationState is intentionally NOT stored here. Phase 1 is
    // single-turn-per-dispatch: streamCleanupOrRefine builds messages
    // directly from overlay.model.references each call, so the dispatch
    // is stateless across turns. The type exists for Phase 2 multi-turn
    // wiring; we'll thread it through when prompt caching + conversation
    // history land.
    private let captureService: ReferenceCapturer = ScreenCaptureKitReferenceCapture()
    private let pasteTargetTracker = PasteTargetTracker()
    private var pasteTargetSubscription: AnyCancellable?
    /// Floating titled-panel picker. Lifted out of an NSPopover so the
    /// thumbnail grid actually has room. Opened by the overlay's `+`
    /// chip-row button, hidden after a pick or via Esc / close.
    private let windowPickerWindow = WindowPickerWindow()
    /// Transparent per-screen overlay that draws an orange border
    /// around the window under the cursor during hold-pick mode.
    private let windowHighlight = WindowHighlightOverlay()
    /// CGEventTap installed during hold-pick mode to intercept
    /// leftMouseDown globally and route clicks to handlePickClick().
    private var pickEventTap: CFMachPort?
    private var pickRunLoopSource: CFRunLoopSource?
    /// True when pick-mode was entered via the WindowPicker's "Pick by
    /// clicking on screen" button — single-pick semantics: capture one
    /// window then exit. Distinct from the legacy hotkey-hold path which
    /// was sticky (multi-pick until release). Reset in endHoldPickMode().
    private var isPickByClickingSinglePick: Bool = false
    /// Pending-pick timer for .staging state. On hotkey-down in
    /// .staging a short timer distinguishes "tap → start audio" from
    /// "hold → enter pick mode". If the key-up arrives before the
    /// timer fires, it's treated as a tap and audio starts normally.
    private var pendingStagingPickTimer: Timer?
    private static let stagingPickHoldThreshold: TimeInterval = 0.18
    /// Per-utterance streaming ASR session. Created at hotkey-down,
    /// drained at hotkey-up. nil between utterances.
    private var streamingSession: StreamingASRSession?
    /// Quick-mode flag: true when this utterance was started by a
    /// double-tap-and-hold gesture from the IDLE state. The
    /// pipeline runs the same cleanup, but skips the overlay
    /// entirely and pastes directly. Reset to false on every
    /// transition back to idle. Public-readable so the listener
    /// wiring can suppress the end-Pop sound for quick-mode
    /// captures (#6 — the Pop + BT-routing-click combo on release
    /// sounded like a doubled end-cue; in quick mode the paste is
    /// the end-cue, no sound needed).
    public private(set) var quickMode = false

    // The configured auto-accept delay. Default 6 s per the design;
    // wired to Config.autoAcceptSeconds at construction time.
    private var autoAcceptInterval: TimeInterval

    /// How long to wait after hotkey-down before showing the overlay
    /// for a fresh capture. Empirical: 200 ms is longer than any
    /// realistic first-tap of a double-tap-and-hold gesture (50–150 ms)
    /// and short enough that a real hold still gets visual feedback
    /// before the user has finished their first word.
    private static let overlayShowDelay: TimeInterval = 0.20

    /// Whether to append a trailing space to pasted text. Wired
    /// from Config.trailingSpace at construction. Effective per
    /// paste, with the per-app denylist applied to skip the space
    /// for specific bundle IDs.
    private let trailingSpaceEnabled: Bool
    /// Bundle IDs where the trailing space is suppressed regardless
    /// of the global setting. Wired from
    /// Config.noTrailingSpaceAppBundleIDs.
    private let noTrailingSpaceAppBundleIDs: Set<String>

    /// Predicate the app uses to gate hotkey-triggered captures on
    /// speech-engine readiness. Default returns true so unit tests
    /// and dev paths work without wiring; ParleqApp.main replaces
    /// this with a closure that reads `LocalASR.isReady` (or
    /// constant-true when a custom external `asr.endpoint` is
    /// configured). When false at hotkey-down time we surface an
    /// "Initializing…" overlay instead of starting a capture
    /// against an unloaded model.
    public var isSystemReady: () -> Bool = { true }
    /// Pending refine timer. When the user taps the hotkey while
    /// the overlay is in awaitingAccept, the natural read is
    /// "accept this transcript", not "start refining" — so we delay
    /// starting refine by this short window. If a key-up arrives
    /// first, the tap counts as accept and we paste.
    private var pendingRefineTimer: Timer?
    private static let refineHoldThreshold: TimeInterval = 0.18
    /// True between showing the "Initializing…" overlay (a hotkey
    /// press while !isSystemReady) and either Esc-dismiss or the
    /// supervisor reporting ready. Without tracking this, cancel()
    /// would no-op for phase=.idle and the overlay would sit
    /// forever, and notifySystemReady() wouldn't know it was meant
    /// to hide a stale init message.
    private var initializingOverlayShowing = false
    /// One-shot guard so the audio-engine warmup capture in
    /// notifySystemReady() runs at most once per app launch — even
    /// if `LocalASR` cycles `isReady` (e.g. user invoked "Reset
    /// ASR" from the menu). The goal is to pay the audio cold-
    /// start cost once before the user's first dictation; on a
    /// reset the audio engine has already warmed once, so re-
    /// warming would just be a redundant mic-indicator flash.
    private var audioWarmupAttempted = false

    /// Latest model-load progress snapshot from `LocalASR`. ParleqApp
    /// wires `LocalASR.onProgressChanged` to call
    /// `notifyDownloadProgress(_:)` whenever FluidAudio reports a new
    /// fraction / phase. Cached here so the init overlay can render a
    /// real progress bar the instant the user presses the hotkey
    /// during a download, rather than waiting for the next progress
    /// event to arrive.
    private var latestDownloadProgress: ASRDownloadProgress?

    public init(
        recorder: AudioRecorder,
        asr: ASRClient,
        llm: (any LLMProvider)?,
        contextLLM: (any LLMProvider)? = nil,
        overlay: OverlayWindow,
        autoAcceptSeconds: TimeInterval = 0,  // 0 = never auto-accept
        trailingSpaceEnabled: Bool = true,
        noTrailingSpaceAppBundleIDs: [String] = []
    ) {
        self.recorder = recorder
        self.asr = asr
        self.llm = llm
        self.contextLLM = contextLLM
        self.overlay = overlay
        self.autoAcceptInterval = autoAcceptSeconds
        self.trailingSpaceEnabled = trailingSpaceEnabled
        self.noTrailingSpaceAppBundleIDs = Set(noTrailingSpaceAppBundleIDs)
        overlay.onAccept = { [weak self] in self?.accept() }
        overlay.onCancel = { [weak self] in self?.cancel() }
        overlay.onCopy = { [weak self] in self?.copy() }
        overlay.onShowWindowPicker = { [weak self] in
            self?.windowPickerWindow.show()
        }
        overlay.onSwitchToVisionModelAndRecleanup = { [weak self] id in
            self?.switchModelAndRecleanup(id)
        }

        windowPickerWindow.setCallbacks(
            onPick: { [weak self] entry in
                guard let self else { return }
                self.windowPickerWindow.hide()
                Task { @MainActor in
                    await self.capture(entry)
                }
            },
            onAddFile: { [weak self] in
                Task { @MainActor in self?.handleAddFileFromPicker() }
            },
            onAddClipboard: { [weak self] in
                Task { @MainActor in self?.handleAddClipboardFromPicker() }
            },
            onPickByClicking: { [weak self] in
                Task { @MainActor in self?.handlePickByClickingFromPicker() }
            }
        )

        pasteTargetSubscription = pasteTargetTracker.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] target in
                self?.overlay.model.pasteTarget = target
            }
    }

    /// Apply the trailing-space rule for this paste:
    /// - Disabled globally → no change.
    /// - Target's bundle ID is on the per-app denylist → no change.
    /// - Text already ends in whitespace → no change (don't double-up).
    /// - Otherwise → append a single space.
    private func textForPaste(_ raw: String, target: PasteTarget?) -> String {
        guard trailingSpaceEnabled else { return raw }
        if let bundleID = target?.bundleID, noTrailingSpaceAppBundleIDs.contains(bundleID) {
            return raw
        }
        if let last = raw.last, last.isWhitespace { return raw }
        return raw + " "
    }

    // MARK: - External inputs

    /// Hotkey was pressed (key-down). Behavior depends on current
    /// phase and the double-tap flag from the listener:
    ///   - speech engine not ready: show the "Initializing…"
    ///     overlay so the user has a clear "wait" signal instead of
    ///     a black-hole capture against an unloaded model.
    ///   - from IDLE + isDoubleTapHold: quick mode (paste directly,
    ///     no overlay).
    ///   - from IDLE: normal mode (overlay flow).
    ///   - from awaitingAccept: schedule a delayed refine. If a
    ///     key-up arrives before the threshold, we treat the press
    ///     as a tap-accept and paste the transcript. Anything held
    ///     longer than the threshold becomes a refine capture.
    ///   - from cleaning: refine the in-flight transcript directly
    ///     (already a hold by the time we got here).
    public func hotkeyDown(isDoubleTapHold: Bool = false, isShiftHeld: Bool = false) {
        if !isSystemReady() {
            initializingOverlayShowing = true
            overlay.show(
                state: .initializing,
                text: "",
                downloadProgress: latestDownloadProgress
            )
            return
        }
        // System is ready. If the init overlay was up, drop the flag
        // — the next overlay.show (.capturing, .refining, etc.) will
        // replace its content cleanly.
        initializingOverlayShowing = false
        switch phase {
        case .idle:
            if isShiftHeld {
                // Shift+hotkey = staging mode: open the overlay so the
                // user can curate references before speaking. No audio
                // captured. Picker auto-opens since that's the point.
                enterStaging()
                return
            }
            quickMode = isDoubleTapHold
            startFreshCapture()
        case .staging:
            // Hotkey-down in staging means "start dictating with the
            // references I just picked." Phase 1 behavior — immediate
            // audio start. (Task 13 briefly used a tap-vs-hold timer
            // here that routed hold to pick-mode, but that inverted
            // the natural press-and-hold dictation gesture: ordinary
            // multi-second dictation holds always cleared the
            // threshold and locked the user into pick mode. Hold-and-
            // click capture remains available from .idle via the
            // existing + button menu and Shift+hotkey staging.)
            windowPickerWindow.hide()
            startFreshCapture()
        case .awaitingAccept:
            // Phase 1 contract: tap = accept, hold = refine. We
            // schedule a 0.18 s timer; if the user releases before
            // it fires (tap), hotkeyUp calls accept(). If it fires
            // (hold), refine capture starts. Task 13 tried to route
            // hold to pick-mode here, but that broke iterative
            // refinement — the core Phase 1 feature.
            schedulePendingRefine()
        case .cleaning:
            startRefineCapture()
        case .capturing, .refining, .pasting:
            // Already capturing or in transient state — ignore the
            // re-trigger.
            return
        }
    }

    /// Enter staging mode (Shift+hotkey from idle). Shows the overlay
    /// with the chip strip + + button visible but no transcript;
    /// auto-opens the WindowPickerWindow so the user can start picking
    /// references immediately. Released by either the user pressing
    /// the hotkey again without Shift (→ start dictation), or Esc /
    /// Cancel (→ discard and return to idle).
    ///
    /// When referenceWindowsEnabled is false the staging path is
    /// bypassed — Shift+hotkey falls through to a normal capture
    /// instead of opening the reference picker. A one-liner is logged
    /// so it's visible in the debug stream but not surfaced to the user.
    private func enterStaging() {
        guard Config.load().config.referenceWindowsEnabled else {
            log("referenceWindowsEnabled=false: staging skipped, entering capture directly")
            quickMode = false
            startFreshCapture()
            return
        }
        phase = .staging
        overlay.show(state: .staging, text: "")
        windowPickerWindow.show()
    }

    /// Hotkey was released (key-up). Whichever capture phase we're
    /// in, this finalizes the audio and runs the ASR-then-LLM
    /// pipeline.
    public func hotkeyUp() {
        // Tap-on-awaitingAccept: refine timer still armed means the
        // user released before the 0.18 s hold threshold — they meant
        // "accept", not "refine."
        if pendingRefineTimer != nil {
            cancelPendingRefine()
            if phase == .awaitingAccept {
                accept()
            }
            return
        }
        switch phase {
        case .capturing:
            finalizeCapture(asRefine: false)
        case .refining:
            finalizeCapture(asRefine: true)
        default:
            // Spurious key-up (we ignored its key-down) — no-op.
            return
        }
    }

    /// Called by `LocalASR` when its TDT model finishes loading and
    /// `isReady` flips true. If the user is currently looking at
    /// the "Initializing…" overlay, dismiss it — without this it
    /// stays on screen even though hotkey presses now work
    /// normally, which is what the user reported as "the overlay
    /// just stays there forever."
    ///
    /// Also runs a one-shot AudioRecorder warmup capture so the
    /// audio engine's cold-start cost is paid here instead of
    /// stealing the first ~100 ms of the user's first dictation. We
    /// gate on the audio recorder being idle (phase == .idle) — if
    /// the user happened to press the hotkey during model load and
    /// we're already mid-capture, skip; their press already paid
    /// the cold-start tax once and the next press will be hot.
    public func notifySystemReady() {
        if initializingOverlayShowing {
            initializingOverlayShowing = false
            overlay.hide()
        }
        guard !audioWarmupAttempted, phase == .idle else { return }
        audioWarmupAttempted = true
        recorder.warmupCapture()
    }

    /// Called by ParleqApp.main from `LocalASR.onProgressChanged`
    /// whenever FluidAudio emits a new progress snapshot. Caches the
    /// latest value so the next `hotkeyDown` during init can render
    /// a populated progress bar immediately, and live-updates the
    /// init overlay when one is already on screen.
    ///
    /// `nil` updates skip the live re-render but still clear the
    /// cache. The two scenarios that produce a `nil` snapshot are:
    /// (a) successful load — LocalASR clears progress right before
    /// `isReady` flips true, which triggers `notifySystemReady()`
    /// and hides the overlay anyway; re-rendering the overlay back
    /// to its indeterminate spinner in the tiny window between
    /// would be a visible flash. (b) `reset()` clearing progress
    /// while the overlay is up — same outcome wanted (don't flash
    /// back to spinner; let the next progress event repopulate).
    public func notifyDownloadProgress(_ progress: ASRDownloadProgress?) {
        latestDownloadProgress = progress
        guard let progress, initializingOverlayShowing else { return }
        overlay.show(
            state: .initializing,
            text: "",
            downloadProgress: progress
        )
    }

    private func schedulePendingRefine() {
        cancelPendingRefine()
        pendingRefineTimer = Timer.scheduledTimer(
            withTimeInterval: AppState.refineHoldThreshold, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.pendingRefineTimer = nil
                guard self.phase == .awaitingAccept else { return }
                self.startRefineCapture()
            }
        }
    }

    private func cancelPendingRefine() {
        pendingRefineTimer?.invalidate()
        pendingRefineTimer = nil
    }

    // MARK: - Hold-pick mode (Task 13)

    /// Schedule the staging hold-pick timer. If the user releases
    /// before it fires we treat the press as a tap-to-dictate (handled
    /// in hotkeyUp). If it fires we enter pick mode instead.
    private func scheduleStagingPick() {
        cancelStagingPickTimer()
        pendingStagingPickTimer = Timer.scheduledTimer(
            withTimeInterval: AppState.stagingPickHoldThreshold, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingStagingPickTimer = nil
                guard self.phase == .staging else { return }
                self.beginHoldPickMode()
            }
        }
    }

    private func cancelStagingPickTimer() {
        pendingStagingPickTimer?.invalidate()
        pendingStagingPickTimer = nil
    }

    /// Schedule the awaitingAccept hold-pick timer. Reuses the same
    /// pendingRefineTimer slot so hotkeyUp's tap-detection (timer still
    /// armed ⟹ accept) continues to work unchanged. On fire, enters
    /// pick mode instead of launching a refine.
    private func schedulePendingPickFromAwaitingAccept() {
        cancelPendingRefine()
        pendingRefineTimer = Timer.scheduledTimer(
            withTimeInterval: AppState.refineHoldThreshold, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingRefineTimer = nil
                guard self.phase == .awaitingAccept else { return }
                self.beginHoldPickMode()
            }
        }
    }

    /// Enter hold-pick mode: show highlight overlays and install the
    /// click event tap. Called when the hotkey is held in .staging or
    /// .awaitingAccept past the hold threshold.
    ///
    /// M1 fix: if CGEvent.tapCreate returns nil (Accessibility revoked
    /// between launches, or sandbox denial), the highlight and
    /// isPickingWindow flag are rolled back so the user isn't left with
    /// an orange highlight that tracks the cursor while clicks pass
    /// through to the underlying app.
    private func beginHoldPickMode() {
        overlay.model.isPickingWindow = true
        windowHighlight.activate()
        let installed = installPickEventTap()
        if !installed {
            // Roll back: the tap couldn't be installed, so the user
            // would see the orange highlight but clicks wouldn't be
            // intercepted and no chip would appear. Tear down and
            // surface a hint so the user knows what to do.
            windowHighlight.deactivate()
            overlay.model.isPickingWindow = false
            overlay.model.permissionPrompt = "Accessibility permission needed to capture clicks. Open System Settings → Privacy & Security → Accessibility and enable Parleq."
        }
    }

    /// Exit hold-pick mode: tear down the highlight overlays and event
    /// tap. Called on hotkey release while isPickingWindow is true, or
    /// after a single-pick capture from the WindowPicker button, or on
    /// Esc while the event tap is active.
    private func endHoldPickMode() {
        overlay.model.isPickingWindow = false
        windowHighlight.deactivate()
        uninstallPickEventTap()
        isPickByClickingSinglePick = false
    }

    /// Install the CGEvent tap for hold-pick mode. Returns true if the
    /// tap was successfully created (or was already installed), false if
    /// CGEvent.tapCreate returned nil (Accessibility revoked or denied).
    /// Callers must roll back any UI changes on false.
    ///
    /// The tap intercepts two event types:
    /// - leftMouseDown: routed to handlePickClick(); swallowed.
    /// - keyDown keycode 53 (Esc): exits pick mode and swallows the
    ///   event so it doesn't reach any underlying app. All other
    ///   keyDown events pass through unchanged so the user can still
    ///   type into other apps if pick-mode lingers unexpectedly.
    @discardableResult
    private func installPickEventTap() -> Bool {
        guard pickEventTap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let appState = Unmanaged<AppState>.fromOpaque(refcon).takeUnretainedValue()

                if type == .leftMouseDown {
                    Task { @MainActor in appState.handlePickClick() }
                    // Swallow the click so the underlying app doesn't receive it.
                    return nil
                }

                if type == .keyDown {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    if keyCode == 53 {  // Esc
                        Task { @MainActor in appState.endHoldPickMode() }
                        // Swallow Esc so it doesn't trigger actions in
                        // apps behind the overlay (e.g. closing dialogs).
                        return nil
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: info
        )
        pickEventTap = tap
        if let tap {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            pickRunLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }
        // tapCreate returned nil — Accessibility permission was revoked
        // or was never granted. Callers check the return value and roll
        // back UI state.
        log("CGEvent.tapCreate returned nil — Accessibility permission unavailable")
        return false
    }

    private func uninstallPickEventTap() {
        if let tap = pickEventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = pickRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        pickRunLoopSource = nil
        pickEventTap = nil
    }

    @MainActor
    private func handlePickClick() {
        guard let target = windowHighlight.currentTarget else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reference = try await self.captureService.captureWindow(
                    windowID: target.windowID,
                    displayTitle: target.appName
                )
                await MainActor.run {
                    self.overlay.model.references.append(reference)
                    // Single-pick exit: when pick-mode was entered via the
                    // WindowPicker button, exit after one successful capture.
                    // The legacy hotkey-hold sticky path is not currently
                    // wired, so this is the only active exit semantic today.
                    if self.isPickByClickingSinglePick {
                        self.endHoldPickMode()
                    }
                }
            } catch CaptureError.permissionDenied {
                await MainActor.run {
                    self.overlay.model.permissionPrompt = "Screen Recording permission needed. Grant in System Settings, then try again."
                }
            } catch {
                await MainActor.run {
                    self.overlay.model.errorMessage = "Couldn't capture window: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - WindowPicker action handlers

    /// "Add file…" button in the WindowPicker: open an NSOpenPanel
    /// and attach each selected file as a Reference.
    ///
    /// The picker is hidden BEFORE the panel opens so the file dialog
    /// isn't occluded by the floating picker window. We also activate
    /// Parleq so the NSOpenPanel gets proper key-window status —
    /// without this, the .nonactivating panel chain means the dialog
    /// opens without focus, leaving clicks unresponsive until the
    /// user Cmd-Tabs away and back.
    ///
    /// Gated by fileReferenceEnabled — when false this is a no-op.
    @MainActor
    private func handleAddFileFromPicker() {
        guard Config.load().config.fileReferenceEnabled else {
            log("fileReferenceEnabled=false: file picker ignored")
            return
        }
        // Hide first so the file dialog isn't occluded by the picker.
        windowPickerWindow.hide()
        // Activate Parleq so NSOpenPanel becomes the key window.
        NSApplication.shared.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard let self, response == .OK else { return }
            let urls = panel.urls
            Task.detached(priority: .userInitiated) {
                for url in urls {
                    // NSOpenPanel only returns file:// URLs, but guard
                    // defensively. File-type validation (image / PDF /
                    // safe text formats) lives inside reference(forFileAt:)
                    // — unsupported types throw and surface as errorMessage.
                    guard url.isFileURL else { continue }
                    do {
                        let ref = try ScreenCaptureKitReferenceCapture.reference(forFileAt: url)
                        await MainActor.run {
                            self.overlay.model.references.append(ref)
                        }
                    } catch {
                        await MainActor.run {
                            self.overlay.model.errorMessage =
                                "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
                        }
                    }
                }
                // Picker already hidden above — no hide() needed here.
            }
        }
    }

    /// "Add from clipboard" button in the WindowPicker: attach the
    /// current pasteboard contents as a Reference and hide the picker.
    /// Gated by clipboardReferenceEnabled — when false this is a no-op
    /// (the button itself should already be hidden in the picker UI,
    /// but defense-in-depth guards the handler as well).
    @MainActor
    private func handleAddClipboardFromPicker() {
        guard Config.load().config.clipboardReferenceEnabled else {
            log("clipboardReferenceEnabled=false: clipboard attach ignored")
            return
        }
        if let ref = ScreenCaptureKitReferenceCapture.referenceFromClipboard() {
            overlay.model.references.append(ref)
            windowPickerWindow.hide()
        } else {
            overlay.model.errorMessage = "Nothing to attach from clipboard."
        }
    }

    /// "Pick by clicking on screen" button in the WindowPicker: hide
    /// the picker and enter click-pick mode (orange highlight + event
    /// tap). Single-pick semantics — handlePickClick exits the mode
    /// after one successful capture. Esc (intercepted by the tap) also
    /// exits cleanly.
    @MainActor
    private func handlePickByClickingFromPicker() {
        windowPickerWindow.hide()
        isPickByClickingSinglePick = true
        beginHoldPickMode()
    }

    /// User accepted (Enter on overlay) or auto-accept timer fired.
    ///
    /// Critical ordering: hide the overlay BEFORE the paste call.
    /// The overlay panel becomes the system key window when shown
    /// (it has to, in order to receive Enter/Esc keys), and while
    /// it's visible our process can keep the input focus even after
    /// `runningApp.activate()` is called on the target. The Cmd-V
    /// CGEvent then lands on our process instead of the target,
    /// silently dropping the paste. Hiding the overlay first
    /// releases key-window status so activate-then-Cmd-V actually
    /// reaches the target. Verified the hard way after M3 broke
    /// what M1 had working.
    public func accept() {
        guard phase == .awaitingAccept else { return }
        // H2 conflict gate: when image-mode references are attached to
        // a non-vision model and the user hasn't acknowledged the
        // downgrade, Accept is suppressed. OverlayButtons already hides
        // the Accept button in this situation, but the Enter-key path
        // (OverlayPanel.keyDown → onEnter → here) was bypassing the
        // gate. NSSound.beep() gives the user a "denied" signal so the
        // keypress doesn't feel silently ignored.
        if hasUnresolvedConflict() {
            NSSound.beep()
            return
        }
        phase = .pasting
        cancelAutoAcceptTimer()
        // Use the live-tracked target rather than the one captured at
        // hotkey-down. The chip in the overlay reflects the live
        // tracker (PasteTargetTracker), so whatever the user sees as
        // 'Pastes to: X' is what they expect Accept to honor. If the
        // tracker has nothing newer than the captured-at-start value,
        // fall through to the original.
        let target = liveTrackedPasteTarget() ?? pasteTarget
        let textToPaste = textForPaste(currentText, target: target)
        // Record to the in-memory transcription history before the
        // paste attempt — even if the paste lands in the wrong app
        // (focus changed mid-flight) the user can grab the text
        // back from the menu bar's Recent Dictations submenu.
        // Stores the bare cleaned text without the trailing-space
        // rule applied, so re-pastes match the user's intent rather
        // than the previous target's convention.
        if !currentText.isEmpty {
            let refs = overlay.model.references
            TranscriptHistory.shared.append(TranscriptEntry(
                text: currentText,
                targetAppName: target?.name,
                wasCleanupSuccessful: !lastCleanupFailed,
                referenceCount: refs.count,
                referenceLabels: refs.map(\.label)
            ))
        }
        if overlay.model.isPickingWindow { endHoldPickMode() }
        overlay.hide()
        resetPerDictationOverlayState()
        Task { @MainActor in
            if let target = target {
                do {
                    try await Paster.paste(text: textToPaste, into: target)
                    log("pasted into \(target.name)")
                } catch {
                    log("paste failed: \(error)")
                }
            } else {
                log("no paste target captured; closing overlay without pasting")
            }
            await closeAndReset()
        }
    }

    /// User cancelled (Esc) or some external abort.
    public func cancel() {
        // The init overlay is shown in idle phase, so it would be
        // missed by the phase switch below. Handle it explicitly.
        if initializingOverlayShowing {
            initializingOverlayShowing = false
            overlay.hide()
            return
        }
        switch phase {
        case .idle, .pasting:
            return  // nothing to cancel
        case .staging:
            // Nothing async to tear down — just close the picker and
            // fall through to the standard overlay-hide / refs-clear
            // path below.
            windowPickerWindow.hide()
        case .capturing, .refining:
            // Stop the recorder so the audio engine releases its
            // input tap; the returned WAV bytes are discarded
            // (we're cancelling the utterance). Also cancel the
            // streaming ASR session so the upload connection
            // closes immediately instead of waiting for body close.
            _ = try? recorder.stop()
            recorder.chunkHandler = nil
            streamingSession?.cancel()
            streamingSession = nil
        case .cleaning, .awaitingAccept:
            break
        }
        inFlightTask?.cancel()
        inFlightTask = nil
        cancelAutoAcceptTimer()
        cancelPendingOverlayShow()
        cancelPendingRefine()
        cancelStagingPickTimer()
        if overlay.model.isPickingWindow { endHoldPickMode() }
        resetPerDictationOverlayState()
        Task { @MainActor in
            await closeAndReset()
        }
    }

    // MARK: - Phase transitions

    private func startFreshCapture() {
        pasteTarget = Paster.captureFrontmost()
        currentText = ""
        lastRawTranscript = ""
        lastCleanupFailed = false
        guard openRecorder() else { return }
        phase = .capturing
        if quickMode {
            log("quick-mode capture (no overlay)")
        } else {
            // Delay the overlay show. Either the first partial
            // transcript arrives first and shows it with content, or
            // the timer fires and shows it empty. A brief tap
            // cancels the timer before either, so no flash.
            schedulePendingOverlayShow()
        }
        if let t = pasteTarget {
            log("target app: \(t.name) (pid=\(t.pid))")
        }
    }

    private func schedulePendingOverlayShow() {
        cancelPendingOverlayShow()
        pendingOverlayShowTimer = Timer.scheduledTimer(
            withTimeInterval: AppState.overlayShowDelay, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Only show if we're still in a capture phase. A
                // fast hotkey-up + finalize that landed on the same
                // run-loop turn could have already advanced us out.
                guard self.phase == .capturing || self.phase == .refining else { return }
                self.overlay.show(
                    state: .capturing,
                    text: "",
                    microphoneName: self.activeMicrophoneName()
                )
            }
        }
    }

    /// Resolve the name of the microphone the recorder is currently
    /// (or would be) capturing from, for surfacing in the overlay's
    /// "listening on <name>…" line. Reads the recorder's explicit-
    /// UID selection and delegates to the shared
    /// `effectiveMicrophoneName(forExplicitUID:)` resolver in
    /// AudioRecorder.swift so the overlay, menu submenu, and
    /// menu-bar tooltip all agree on which name to show.
    private func activeMicrophoneName() -> String? {
        return effectiveMicrophoneName(forExplicitUID: recorder.explicitInputDeviceUID)
    }

    private func cancelPendingOverlayShow() {
        pendingOverlayShowTimer?.invalidate()
        pendingOverlayShowTimer = nil
    }

    private func startRefineCapture() {
        // Cancel any in-flight LLM stream from the prior turn before
        // we overwrite currentText with a refined version.
        inFlightTask?.cancel()
        inFlightTask = nil
        cancelAutoAcceptTimer()
        guard openRecorder() else { return }
        phase = .refining
        overlay.show(
            state: .refining,
            text: currentText,
            microphoneName: activeMicrophoneName()
        )
    }

    /// Start the audio recorder. Returns false (and logs) if the
    /// engine fails to start — the caller bails the phase transition.
    ///
    /// We previously opened a StreamingASRSession alongside the
    /// recorder so live partial transcripts could update the overlay
    /// during speech. That path used FluidAudio's Nemotron streaming
    /// model, which has end-of-utterance detection baked into its
    /// CoreML graph: after the first sentence-end pause the decoder
    /// stops emitting tokens for the rest of the session and the
    /// transcript truncates. Reverted to the original M1 batch path
    /// (Parakeet TDT v3 via ASRClient.transcribe), which doesn't
    /// share that behavior. Trade-off: no live partials in the
    /// overlay during speech (it just shows "Listening…"), in
    /// exchange for correct transcription of arbitrary length.
    /// StreamingASRSession itself stays in the repo for cloud-ASR
    /// experiments; we just don't wire it from AppState today.
    private func openRecorder() -> Bool {
        recorder.chunkHandler = nil
        // Wire mic-level → overlay so the SoundWaveBars view has live
        // signal during .capturing. The handler fires on the audio
        // tap thread (~12 calls/sec at 4096-frame buffers), so we hop
        // to MainActor to mutate the @Published level on the model.
        // Captured weakly because AppState owns both ends of the
        // pipeline; we don't want the recorder closure to keep us
        // alive past dealloc.
        recorder.levelHandler = { [weak self] value in
            Task { @MainActor [weak self] in
                self?.overlay.setLevel(value)
            }
        }
        do {
            try recorder.start()
        } catch {
            log("recorder start failed: \(error)")
            recorder.levelHandler = nil
            return false
        }
        return true
    }

    private func finalizeCapture(asRefine: Bool) {
        let capture: AudioRecorder.Capture
        do {
            capture = try recorder.stop()
        } catch {
            log("recorder stop failed: \(error)")
            cancelPendingOverlayShow()
            streamingSession?.cancel()
            streamingSession = nil
            recorder.chunkHandler = nil
            resetPerDictationOverlayState()
            phase = .idle
            overlay.hide()
            return
        }
        log("captured \(capture.wavData.count / 1024) KB, \(String(format: "%.2f", capture.durationSeconds))s")

        // Detach the streaming session so the closure that holds
        // `session` doesn't leak past this utterance, then clear the
        // chunk handler on the recorder so subsequent captures
        // don't accidentally pump into a stale session.
        let session = streamingSession
        streamingSession = nil
        recorder.chunkHandler = nil

        // Short-utterance guard: if the user held the hotkey for less
        // than ~200 ms it's almost certainly an accidental tap (or
        // the start of a press they didn't follow through on).
        // Bail out without running the ASR/LLM pipeline. 200 ms is
        // empirical — shorter than that, ASR returns near-empty
        // anyway and we'd just paste blank text.
        if capture.durationSeconds < 0.2 {
            log("utterance too short (\(String(format: "%.2f", capture.durationSeconds))s); skipping pipeline")
            cancelPendingOverlayShow()
            session?.cancel()
            resetPerDictationOverlayState()
            phase = .idle
            overlay.hide()
            return
        }

        // Silence-hallucination guard: Parakeet TDT sometimes returns
        // a phantom short word ("yeah", "okay", "thank you") when given
        // audio that passes the duration guard but contains no real
        // speech (held hotkey with mic open in a quiet room, breath,
        // BT-routing thumps). The empty-transcript guard further down
        // doesn't catch this because the transcript is non-empty —
        // just hallucinated. We pre-check with an RMS-over-20ms-frames
        // analyzer; under 50ms of voiced audio means the user almost
        // certainly didn't speak, so we short-circuit before invoking
        // ASR. The threshold matches a quiet "yes" (~150ms voiced) with
        // a healthy margin.
        //
        // Gate on isAnalyzable so a malformed WAV buffer (defensive
        // path that shouldn't be reachable today) falls through to
        // ASR rather than getting suppressed by SilenceDetector's
        // zero-default voicedDuration fallback.
        let silence = SilenceDetector.analyze(wavData: capture.wavData)
        if silence.isAnalyzable && silence.voicedDurationSeconds < 0.05 {
            log("captured audio voiced=\(String(format: "%.3f", silence.voicedDurationSeconds))s peak=\(String(format: "%.4f", silence.peakRMS)); skipping pipeline (silence)")
            cancelPendingOverlayShow()
            session?.cancel()
            // Mirror the empty-transcript branch below: on a silent
            // REFINE attempt, keep the prior text on screen so the
            // user can still accept the unmodified version (a silent
            // refine isn't a "cancel everything" gesture — the user
            // may have meant to confirm the existing text and didn't
            // realize they needed to actively speak). On a silent
            // INITIAL dictation there is no prior text, so the
            // full-reset is the right end state.
            if asRefine, !currentText.isEmpty {
                applyResult(currentText)
            } else {
                resetPerDictationOverlayState()
                phase = .idle
                overlay.hide()
            }
            return
        }

        phase = .cleaning
        if quickMode {
            // In quick mode we don't show the overlay — the user
            // is going to get the paste directly. Acoustic cues
            // (Tink/Pop) and the brief LLM-cleanup wait are the
            // only feedback.
            log("quick-mode cleaning (no overlay)")
        } else {
            // For cleanup we start with an empty overlay (text
            // streams in). For refinement we show the prior text
            // faded; the overlay's appendText starts replacing it
            // as the LLM streams the refined version.
            overlay.show(state: .cleaning, text: asRefine ? currentText : "")
        }

        let overlay = self.overlay
        let priorText = currentText
        let asrClient = self.asr
        let wavBytes = capture.wavData
        inFlightTask = Task { @MainActor [weak self] in
            do {
                // Batch ASR via /inference (Parakeet TDT v3) — uploads
                // the whole WAV after the user releases the hotkey.
                // No live partials in the overlay during speech, but
                // no end-of-utterance truncation either. Typical
                // post-release latency on representative human-voice
                // recordings was ~64 ms p50 for 5 s clips.
                _ = session  // captured for compatibility; unused now
                // Re-read the dictionary from disk once per utterance.
                // Used by both the ASR pass (term list — biases
                // recognition via CTC keyword spotting) and the LLM
                // cleanup pass (term + context — feeds the smart
                // vocabulary hint). Edits in Settings apply on the
                // next utterance without restart.
                // When customDictionaryEnabled is false, treat the
                // dictionary as empty for the LLM prompt boundary (the
                // stored entries are preserved on disk and will be used
                // again when the toggle is re-enabled).
                let loadedConfig = Config.load().config
                let dictionary = loadedConfig.customDictionaryEnabled
                    ? loadedConfig.customDictionary
                    : []
                // ASR-side vocabulary biasing covers entries marked
                // `.asrAndLLM` only — `.llmOnly` entries skip the
                // STT pass to avoid CTC false positives (issue #15).
                // For each ASR-included entry we send the canonical
                // term plus its aliases as a structured pair (issue
                // #14): the aliases flow into FluidAudio's
                // CustomVocabularyTerm.aliases, which makes the
                // rescorer emit the canonical spelling whenever any
                // alias matches. The LLM cleanup pass
                // below still receives the full dictionary, including
                // `.llmOnly` entries — the smart-vocab hint operates
                // on every entry regardless of mode.
                let vocabularyEntries: [VocabularyEntry] = dictionary
                    .filter { $0.biasing == .asrAndLLM }
                    .map { VocabularyEntry(term: $0.term, aliases: $0.aliases) }
                let asrStart = Date()
                let asrResultRaw = try await asrClient.transcribe(
                    wav: wavBytes,
                    vocabulary: vocabularyEntries
                )
                let asrLatency = Date().timeIntervalSince(asrStart)
                // Compliance #17: log length-only, never the
                // transcript itself. The overlay still renders the
                // full text — it just doesn't get persisted to
                // stderr / log files.
                let chars = asrResultRaw.text.count
                let words = asrResultRaw.text
                    .split(whereSeparator: { $0.isWhitespace })
                    .count
                self?.log("ASR batch (post-utterance \(Int(asrLatency * 1000))ms, \(chars) chars / \(words) words)")
                if Task.isCancelled { return }
                let asrResult = (text: asrResultRaw.text, latency: asrLatency)

                // Empty-transcript guard: if the recording was long
                // enough to pass the duration check but ASR returned
                // nothing (silence, room noise, mic muted), don't
                // bother running the LLM. Refinement can fall back
                // to leaving the prior text intact.
                let trimmed = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self?.log("ASR returned empty; closing overlay without paste")
                    if asRefine, !priorText.isEmpty {
                        // Keep the prior text on screen so the user
                        // can still accept the unmodified version.
                        self?.applyResult(priorText)
                    } else {
                        self?.resetPerDictationOverlayState()
                        self?.phase = .idle
                        self?.overlay.hide()
                    }
                    return
                }

                let useOverlay = !(self?.quickMode ?? false)
                let targetBundleID = self?.pasteTarget?.bundleID
                // Retain the raw transcript so switchModelAndRecleanup
                // can re-run the LLM pass with a different provider
                // (M2 fix: Switch button re-runs cleanup, not just
                // flips the badge).
                self?.lastRawTranscript = asrResult.text
                // Resolve which provider to use for this dictation:
                // override > context > cleanup, honoring the
                // pickedModelOverride the user may have set via the
                // in-overlay ModelPicker (Task 9).
                let resolvedLLM = self?.llmForInvocation()
                // When imageReferenceEnabled is false, downgrade any
                // image-mode references to text mode for prompt-building.
                // The reference chips in the overlay still show the
                // original mode (they were captured before the toggle
                // was checked here), but the LLM sees text-only content.
                let rawRefs = self?.overlay.model.references ?? []
                let effectiveRefs: [Reference]
                if loadedConfig.imageReferenceEnabled {
                    effectiveRefs = rawRefs
                } else {
                    effectiveRefs = rawRefs.map { ref in
                        guard ref.captureMode == .image else { return ref }
                        var degraded = ref
                        degraded.captureMode = .text
                        return degraded
                    }
                    if rawRefs.contains(where: { $0.captureMode == .image }) {
                        self?.log("imageReferenceEnabled=false: image refs degraded to text for prompt-building")
                    }
                }
                let outcome = await streamCleanupOrRefine(
                    llm: resolvedLLM,
                    overlay: overlay,
                    useOverlay: useOverlay,
                    asRefine: asRefine,
                    rawTranscript: asrResult.text,
                    priorText: priorText,
                    targetBundleID: targetBundleID,
                    customDictionary: dictionary,
                    references: effectiveRefs,
                    pasteDestinationLabel: self?.overlay.model.pasteTarget.map { dest in
                        if let title = dest.windowTitle, !title.isEmpty {
                            return "\(dest.appName) — \(title)"
                        }
                        return dest.appName
                    }
                )
                if Task.isCancelled { return }

                self?.applyResult(outcome.text, cleanupFailureMessage: outcome.failureMessage)
            } catch {
                self?.log("pipeline failed: \(error)")
                self?.resetPerDictationOverlayState()
                self?.phase = .idle
                self?.overlay.hide()
            }
        }
    }

    private func applyResult(_ text: String, cleanupFailureMessage: String? = nil) {
        currentText = text
        lastCleanupFailed = (cleanupFailureMessage != nil)
        // Notify the menu bar of the cleanup outcome regardless of
        // mode (#28). Non-nil message lights up the amber-bar
        // status icon + a dismissable menu row; nil clears any
        // prior badge from an earlier failure. Quick mode is the
        // primary use case here since its overlay-less paste path
        // doesn't surface the failure inline, but firing in normal
        // mode too means a successful subsequent dictation
        // automatically clears the menu badge even if the user
        // didn't dismiss it manually.
        onCleanupResult?(cleanupFailureMessage)
        if quickMode {
            // Skip the review step entirely. Transition straight to
            // .pasting and paste right away — same flow as accept()
            // but synchronous from the LLM-stream-done callback.
            // Also log the failure to ~/.parleq/app.log so users
            // who don't notice the menu-bar badge can still
            // diagnose from the log.
            if let failure = cleanupFailureMessage {
                log("quick-mode cleanup failed: \(failure)")
            }
            phase = .pasting
            let target = pasteTarget
            let textToPaste = textForPaste(text, target: target)
            Task { @MainActor in
                if let t = target {
                    do {
                        try await Paster.paste(text: textToPaste, into: t)
                        log("quick-mode pasted into \(t.name)")
                    } catch {
                        log("quick-mode paste failed: \(error)")
                    }
                } else {
                    log("quick-mode: no paste target captured; dropping result")
                }
                await closeAndReset()
            }
            return
        }
        phase = .awaitingAccept
        // Don't re-set the text — it was streamed in already; just
        // change the state so the footer updates to "[⏎] accept",
        // and pass through any cleanup-failure message so the
        // overlay decorates the accept view with the provider's
        // recovery hint.
        overlay.show(
            state: .awaitingAccept,
            text: text,
            cleanupFailureMessage: cleanupFailureMessage
        )
        startAutoAcceptTimer()
    }

    private func closeAndReset() async {
        cancelPendingOverlayShow()
        cancelPendingRefine()
        currentText = ""
        lastRawTranscript = ""
        lastCleanupFailed = false
        pasteTarget = nil
        quickMode = false
        phase = .idle
        overlay.hide()
    }

    /// Clear per-dictation overlay state that must not bleed into the
    /// next utterance. Called from every exit path that returns the
    /// state machine to .idle — accept(), cancel(), the empty-ASR
    /// branch, the recorder-stop-failure branch, the short-utterance
    /// guard, and the pipeline-catch handler.
    ///
    /// Without this, pickedModelOverride or userDowngradedConflict set
    /// during one dictation would silently persist into the next,
    /// misrouting the model or suppressing the conflict warning.
    @MainActor
    private func resetPerDictationOverlayState() {
        overlay.model.references = []
        overlay.model.pickedModelOverride = nil
        overlay.model.userDowngradedConflict = false
    }

    // MARK: - Timer

    private func startAutoAcceptTimer() {
        cancelAutoAcceptTimer()
        guard autoAcceptInterval > 0 else { return }
        autoAcceptTimer = Timer.scheduledTimer(withTimeInterval: autoAcceptInterval, repeats: false) { [weak self] _ in
            // Timer callbacks run on the run loop the timer was
            // scheduled on (main here), but we hop to MainActor
            // explicitly to satisfy Swift 6.
            Task { @MainActor in self?.accept() }
        }
    }

    private func cancelAutoAcceptTimer() {
        autoAcceptTimer?.invalidate()
        autoAcceptTimer = nil
    }

    // MARK: - Helpers

    /// Returns true when a ModelConflict is active and the user has
    /// NOT acknowledged it via "Downgrade & send". Used by accept()
    /// to block the Enter-key path when the visible Accept button has
    /// already been removed by OverlayButtons.
    private func hasUnresolvedConflict() -> Bool {
        if overlay.model.userDowngradedConflict { return false }
        let cfg = Config.load().config
        let resolved = cfg.modelForInvocation(
            hasReferences: !overlay.model.references.isEmpty,
            override: overlay.model.pickedModelOverride
        )
        return ModelConflict.from(
            modelSupportsVision: ModelCapability.supportsVision(resolved),
            references: overlay.model.references
        ) != nil
    }

    /// Resolve which LLM provider should service the current
    /// dictation by calling Config.modelForInvocation with the
    /// current reference count and per-invocation override.
    /// Priority: override > context > cleanup (same as Config's
    /// resolution chain). Returns contextLLM when config says to
    /// use the context tier, llm otherwise. nil when no provider
    /// is configured for the resolved tier.
    ///
    /// M5 fix: if the resolved identifier matches neither the cleanup
    /// nor the context provider (a latent path today — the picker only
    /// offers cleanup + context — but load-bearing once a third
    /// provider is wired), log a warning and fall back to the best
    /// available provider rather than silently returning `llm` whose
    /// baked-in model is NOT the override.
    private func llmForInvocation() -> (any LLMProvider)? {
        let config = Config.load().config
        let resolved = config.modelForInvocation(
            hasReferences: !overlay.model.references.isEmpty,
            override: overlay.model.pickedModelOverride
        )
        let cleanupId = ModelIdentifier(provider: config.llmProvider, model: config.llmModel)

        // Cleanup tier — most common path.
        if resolved == cleanupId {
            return llm
        }

        // Context tier — use contextLLM when configured.
        if let contextModel = config.contextModel, resolved == contextModel {
            // Degrade gracefully when contextLLM isn't wired (e.g.
            // context model set in config but provider init failed).
            return contextLLM ?? llm
        }

        // Resolved is neither cleanup nor context — the in-overlay
        // picker produced an identifier no pre-built provider services.
        // This is a latent path today (picker scope is cleanup+context
        // only) but we log and fall back rather than silently returning
        // `llm` whose baked-in model is not the intended override.
        log("llmForInvocation: resolved model \(resolved.provider)/\(resolved.model) has no matching pre-built provider; falling back to context/cleanup")
        return contextLLM ?? llm
    }

    /// Resolve the *currently intended* paste target by looking at the
    /// live PasteTargetTracker (the same source the overlay's chip
    /// reads from). If the user switched apps after starting the
    /// dictation, this returns the app they're currently focused on
    /// — matching the chip — rather than the app that happened to be
    /// frontmost at hotkey-down.
    @MainActor
    private func liveTrackedPasteTarget() -> PasteTarget? {
        guard let dest = pasteTargetTracker.current else { return nil }
        // Resolve the running NSRunningApplication for this bundle ID
        // so we can fill in pid (Paster.PasteTarget requires pid for
        // the actual Cmd-V dispatch).
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == dest.bundleID })
        else {
            return nil
        }
        return PasteTarget(
            pid: app.processIdentifier,
            name: app.localizedName ?? dest.appName,
            bundleID: dest.bundleID
        )
    }

    @MainActor
    private func capture(_ entry: WindowPickerModel.Entry) async {
        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            overlay.model.permissionPrompt = "Screen Recording permission needed. Grant in System Settings, then try again."
            return
        }
        // Clear any stale banners up front so success implicitly
        // dismisses them — otherwise an "Permission denied" banner
        // from a prior capture lingers after the user grants and
        // retries.
        overlay.model.errorMessage = nil
        overlay.model.permissionPrompt = nil
        do {
            let reference = try await captureService.captureWindow(
                windowID: entry.windowID,
                displayTitle: entry.title
            )
            overlay.model.references.append(reference)
        } catch CaptureError.permissionDenied {
            overlay.model.permissionPrompt = "Screen Recording permission denied. Grant in System Settings, then try again."
        } catch {
            overlay.model.errorMessage = "Couldn't capture window: \(error.localizedDescription)"
        }
    }

    /// M2 fix: Switch-to-vision-model re-runs cleanup with the new
    /// provider rather than just flipping the badge.
    ///
    /// Previously, tapping "Switch to <model>" in the conflict warning
    /// row only wrote pickedModelOverride — it did NOT re-invoke
    /// streamCleanupOrRefine. Because resolvedLLM was captured ONCE
    /// when the pipeline ran (with the wrong non-vision model), Switch
    /// and Downgrade were functionally identical for the current
    /// dictation: the user would click Accept and paste the output
    /// produced by the non-vision model. This method wires the Switch
    /// button to re-run the full cleanup pass with the newly-resolved
    /// provider against the retained raw ASR transcript.
    @MainActor
    public func switchModelAndRecleanup(_ newModel: ModelIdentifier) {
        guard phase == .awaitingAccept else { return }
        // Write the override first so llmForInvocation() picks it up.
        overlay.model.pickedModelOverride = newModel
        // lastRawTranscript is empty only when the pipeline didn't run
        // (no-LLM / mock provider). In that case there's nothing to
        // re-clean; fall through gracefully.
        guard !lastRawTranscript.isEmpty else { return }

        // Cancel any lingering auto-accept timer so it doesn't fire
        // mid-re-cleanup.
        cancelAutoAcceptTimer()
        phase = .cleaning

        let overlay = self.overlay
        let rawTranscript = lastRawTranscript
        let targetBundleID = pasteTarget?.bundleID
        let recleanConfig = Config.load().config
        let dictionary = recleanConfig.customDictionaryEnabled
            ? recleanConfig.customDictionary
            : []
        let resolvedLLM = llmForInvocation()
        // Apply the same image-reference degradation as the primary
        // capture path: when imageReferenceEnabled is false, downgrade
        // any image-mode references to text for prompt-building.
        let rawRefs = overlay.model.references
        let effectiveRefs: [Reference]
        if recleanConfig.imageReferenceEnabled {
            effectiveRefs = rawRefs
        } else {
            effectiveRefs = rawRefs.map { ref in
                guard ref.captureMode == .image else { return ref }
                var degraded = ref
                degraded.captureMode = .text
                return degraded
            }
        }
        inFlightTask = Task { @MainActor [weak self] in
            let outcome = await streamCleanupOrRefine(
                llm: resolvedLLM,
                overlay: overlay,
                useOverlay: true,
                asRefine: false,
                rawTranscript: rawTranscript,
                priorText: "",
                targetBundleID: targetBundleID,
                customDictionary: dictionary,
                references: effectiveRefs,
                pasteDestinationLabel: self?.overlay.model.pasteTarget.map { dest in
                    if let title = dest.windowTitle, !title.isEmpty {
                        return "\(dest.appName) — \(title)"
                    }
                    return dest.appName
                }
            )
            if Task.isCancelled { return }
            self?.applyResult(outcome.text, cleanupFailureMessage: outcome.failureMessage)
        }
    }

    @MainActor
    private func copy() {
        let text = currentText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func logPhase(from old: Phase, to new: Phase) {
        if old == new { return }
        log("phase: \(old) → \(new)")
    }

    private func log(_ message: String) {
        if let data = "[parleq] \(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

/// Result of a cleanup / refine attempt: the text to display +
/// paste, plus an optional one-line failure message AppState shows
/// in the overlay's awaitingAccept state when cleanup didn't run
/// (or ran and failed). The text is always populated — it's either
/// the cleaned output (success) or the raw transcript / prior
/// text (fallback). `failureMessage` is nil on success.
struct CleanupOutcome {
    public let text: String
    public let failureMessage: String?
}

/// Stream a cleanup or refine call into the overlay — chunks are
/// appended to the overlay text as they arrive (so the user sees
/// text grow incrementally), and the final assembled text is
/// returned so AppState can store it for the paste step.
///
/// Constructs the message list per the design's "fresh stateless
/// LLM call per refinement turn" invariant: the current overlay text
/// is part of the prompt itself, never retained on a server.
///
/// On LLM failure the fallback is to use the raw ASR transcript
/// (cleanup) or the prior text (refine) — whatever the user has
/// most-correctly. We log the failure but never propagate it; the
/// overlay should always show *something*. The optional
/// `CleanupOutcome.failureMessage` carries a user-facing recovery
/// hint when the failure is one a user can act on (auth expired,
/// API key rejected, network down).
@MainActor
private func streamCleanupOrRefine(
    llm: (any LLMProvider)?,
    overlay: OverlayWindow,
    useOverlay: Bool,
    asRefine: Bool,
    rawTranscript: String,
    priorText: String,
    targetBundleID: String? = nil,
    customDictionary: [DictionaryEntry] = [],
    references: [Reference] = [],
    pasteDestinationLabel: String? = nil
) async -> CleanupOutcome {
    let fallback = asRefine ? priorText : rawTranscript
    guard let llm = llm else {
        // No LLM provider configured at launch (e.g., the user
        // selected provider=none, or every provider's init failed).
        // Render the fallback without any failure decoration —
        // there's no error here, just an intentional no-cleanup
        // posture.
        if useOverlay {
            overlay.show(state: .cleaning, text: fallback)
        }
        return CleanupOutcome(text: fallback, failureMessage: nil)
    }
    if rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if useOverlay {
            overlay.show(state: .cleaning, text: fallback)
        }
        return CleanupOutcome(text: fallback, failureMessage: nil)
    }

    let systemPrompt: String
    let messages: [LLMMessage]
    if !references.isEmpty {
        // Reference-aware mode: use PromptBuilder. Phase 1 stays
        // single-turn — we don't preserve assistant responses across
        // refinement yet — but we DO carry priorText into the user
        // content when refining, otherwise hold-⌥ refine while
        // references are attached would silently throw away the
        // current cleaned text and re-treat the instruction as a
        // fresh ask. Document the regression possibility in the
        // prompt itself by labeling the prior output.
        // The reference-aware prompt is its own self-contained system
        // message, but we still want the user's custom-dictionary
        // canonical-spelling hints — exactly the turn where on-screen
        // product / jargon context is most likely to come up. Append
        // the dictionary hint when non-empty so the LLM can bias toward
        // the user's preferred spellings on reference-aware turns too.
        let dictHint = SystemPrompts.dictionaryHint(dictionary: customDictionary)
        systemPrompt = dictHint.isEmpty
            ? PromptBuilder.referenceAwareSystem
            : PromptBuilder.referenceAwareSystem + "\n\n" + dictHint
        var firstTurn = PromptBuilder.buildFirstTurnMessage(
            references: references,
            destination: pasteDestinationLabel,
            instruction: rawTranscript
        )
        if asRefine, !priorText.isEmpty {
            // Append prior-text annotation to the text part so the LLM
            // knows what it's refining. Image parts stay unchanged.
            var newParts = firstTurn.parts.dropLast().map { $0 }
            let baseText: String
            if case .text(let s) = firstTurn.parts.last {
                baseText = s
            } else {
                baseText = firstTurn.legacyContentString
            }
            newParts.append(.text(baseText + "\n\nCurrent text (apply the instruction above to refine this):\n\(priorText)"))
            firstTurn = LLMMessage(role: "user", parts: newParts)
        }
        messages = [firstTurn]
    } else if asRefine {
        systemPrompt = SystemPrompts.refine
        messages = [LLMMessage(role: "user", content: "Current text:\n\(priorText)\n\nEdit instruction:\n\(rawTranscript)")]
    } else {
        // Wrap the raw transcript in explicit cleanup-task framing.
        // Without this, models trained heavily on safety guardrails
        // (notably Claude Haiku 4.5) read second-person dictation
        // ("Got it, please proceed", "Can you try that again",
        // commentary referring to AI systems) as a direct address
        // and refuse with "I'm a transcript cleaner, not a chatbot"
        // instead of cleaning. The structural wrapper makes the
        // user message a meta-instruction containing the data,
        // rather than being mistakable for the data itself.
        systemPrompt = SystemPrompts.cleanup(dictionary: customDictionary)
        messages = [LLMMessage(role: "user", content: "Transcript to clean up:\n\n\(rawTranscript)")]
    }

    // Reset the overlay text before streaming begins so the new
    // content fully replaces any prior text (especially important on
    // refinement, where we showed the prior text faded). Skip in
    // quick mode — there's no overlay to update.
    if useOverlay {
        overlay.show(state: .cleaning, text: "")
    }

    let assembled = AssembledTextBox()

    do {
        try await llm.generateStreaming(
            systemPrompt: systemPrompt,
            messages: messages
        ) { event in
            // The streaming callback fires on URLSession's queue, not
            // MainActor. Hop to the main actor for any overlay
            // mutation.
            switch event {
            case .chunk(let text):
                assembled.append(text)
                if useOverlay {
                    Task { @MainActor in
                        overlay.appendText(text)
                    }
                }
            case .done(let summary):
                let kind = asRefine ? "refine" : "cleanup"
                let ttftMs = Int(summary.ttft * 1000)
                let totalMs = Int(summary.totalLatency * 1000)
                let logLine = "[parleq] \(kind) stream done (ttft=\(ttftMs)ms, total=\(totalMs)ms, in=\(summary.inputTokens) out=\(summary.outputTokens) tok)\n"
                FileHandle.standardError.write(logLine.data(using: .utf8) ?? Data())
                // Persist to the usage ledger for the Settings →
                // Usage view. Fire-and-forget; the ledger queues the
                // file write off this URLSession queue.
                UsageLedger.shared.append(UsageEntry(
                    ts: Date(),
                    kind: kind,
                    provider: llm.providerName,
                    model: llm.model,
                    inputTokens: summary.inputTokens,
                    outputTokens: summary.outputTokens,
                    ttftMs: ttftMs,
                    totalMs: totalMs,
                    targetApp: targetBundleID
                ))
            }
        }
        let final = assembled.value
        if final.isEmpty {
            // Stream produced nothing visible — paste the fallback
            // instead of leaving the overlay empty. This is treated
            // as a non-failure (no decorations) because some LLMs
            // legitimately return empty for unusable input, and we
            // don't want to flag that as an auth / provider error.
            if useOverlay {
                overlay.show(state: .cleaning, text: fallback)
            }
            return CleanupOutcome(text: fallback, failureMessage: nil)
        }
        return CleanupOutcome(text: final, failureMessage: nil)
    } catch {
        // Log the error SHAPE but strip any HTTP response body the
        // provider's LLMError cases would otherwise carry into
        // ~/.parleq/app.log. `LLMError.logSafeDescription` covers all
        // five cases (.badStatus, .malformedResponse, .requestFailed,
        // .missingAPIKey, …) — BedrockBearerProvider in particular
        // embeds up to 400 chars of body preview in .malformedResponse
        // detail strings, which would otherwise persist unredacted on
        // disk. The full descriptive error still reaches the user via
        // the cleanupFailureMessage path below; only the on-disk log
        // is sanitized.
        let logSafeDescription: String
        if let llmError = error as? LLMError {
            logSafeDescription = llmError.logSafeDescription
        } else {
            logSafeDescription = String(describing: error)
        }
        let logLine = "[parleq] LLM \(asRefine ? "refine" : "cleanup") stream failed: \(logSafeDescription). Using fallback text.\n"
        FileHandle.standardError.write(logLine.data(using: .utf8) ?? Data())
        // Build a user-facing recovery hint: prefer the provider's
        // own `cleanupFailureHint` (auth-mode-aware, points the user
        // at the specific command or Settings entry that fixes the
        // underlying issue), fall back to a network-specific message
        // when the error originates from URLSession, fall back to a
        // generic see-the-log message otherwise. Either way, AppState
        // wires this into OverlayModel.cleanupFailureMessage so the
        // awaitingAccept overlay surfaces it next to the raw
        // transcript (#27).
        //
        // The network detection has to unwrap `LLMError.requestFailed`
        // first: every provider wraps underlying URLSession errors in
        // that case before throwing, so the outer `error as NSError`
        // is the auto-bridged LLMError (no NSURLErrorDomain), not
        // the underlying network error. Checking the underlying error
        // inside the `.requestFailed` payload is the only path that
        // actually reaches the network message.
        // Every provider wraps its thrown errors in LLMError before
        // re-throwing, so the catch above receives an LLMError in
        // every practical path. The provider's own hint wins; if it
        // returned nil, fall back to a network-specific message
        // when the underlying URLSession error is reachable through
        // `.requestFailed`, otherwise a generic "see the log" copy.
        // Any non-LLMError throw falls to the generic copy too —
        // no contracted path produces one, but the catch-all keeps
        // failureMessage assigned no matter what.
        let networkHint = "Network unavailable — pasting raw transcript. Check your connection and try again."
        let genericHint = "Cleanup unavailable — pasting raw transcript. See ~/.parleq/app.log for details."
        let failureMessage: String
        if let llmError = error as? LLMError {
            if let providerHint = llm.cleanupFailureHint(for: llmError) {
                failureMessage = providerHint
            } else if case .requestFailed(let underlying) = llmError,
                      (underlying as NSError).domain == NSURLErrorDomain {
                failureMessage = networkHint
            } else {
                failureMessage = genericHint
            }
        } else {
            failureMessage = genericHint
        }
        if useOverlay {
            overlay.show(state: .cleaning, text: fallback)
        }
        return CleanupOutcome(text: fallback, failureMessage: failureMessage)
    }
}

/// Reference-typed string accumulator so the streaming callback can
/// build up the assembled text across many invocations. The
/// callback fires sequentially on URLSession's stream-handling
/// queue (one chunk at a time per HTTP response), and the final
/// `.value` read happens on the main actor after the stream
/// completes — so access is provably serial across the chunk-by-
/// chunk write phase and the post-stream read. We mark the class
/// `@unchecked Sendable` to signal that to the Swift 6 concurrency
/// model.
private final class AssembledTextBox: @unchecked Sendable {
    private var _value: String = ""
    func append(_ chunk: String) {
        _value.append(chunk)
    }
    var value: String { _value }
}
