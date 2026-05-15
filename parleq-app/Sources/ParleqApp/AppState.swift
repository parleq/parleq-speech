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
import Foundation

@MainActor
final class AppState {
    // MARK: - States and inputs

    enum Phase: Equatable {
        case idle
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
    var onPhaseChanged: (@MainActor (Phase) -> Void)?
    private var pasteTarget: PasteTarget?
    private var currentText: String = ""        // last cleaned/refined text in the overlay
    private var autoAcceptTimer: Timer?
    /// Timer that delays the initial overlay show on a fresh capture
    /// so a brief tap (the first half of a double-tap-and-hold, or a
    /// fumbled keypress) doesn't flash the overlay. Cancelled when
    /// the first partial transcript arrives, the utterance is
    /// short-circuited, or the user cancels.
    private var pendingOverlayShowTimer: Timer?
    private var inFlightTask: Task<Void, Never>?  // cleanup or refine task — cancel on abort
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
    private(set) var quickMode = false

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
    var isSystemReady: () -> Bool = { true }
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

    init(
        recorder: AudioRecorder,
        asr: ASRClient,
        llm: (any LLMProvider)?,
        overlay: OverlayWindow,
        autoAcceptSeconds: TimeInterval = 0,  // 0 = never auto-accept
        trailingSpaceEnabled: Bool = true,
        noTrailingSpaceAppBundleIDs: [String] = []
    ) {
        self.recorder = recorder
        self.asr = asr
        self.llm = llm
        self.overlay = overlay
        self.autoAcceptInterval = autoAcceptSeconds
        self.trailingSpaceEnabled = trailingSpaceEnabled
        self.noTrailingSpaceAppBundleIDs = Set(noTrailingSpaceAppBundleIDs)
        overlay.onAccept = { [weak self] in self?.accept() }
        overlay.onCancel = { [weak self] in self?.cancel() }
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
    func hotkeyDown(isDoubleTapHold: Bool = false) {
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
            quickMode = isDoubleTapHold
            startFreshCapture()
        case .awaitingAccept:
            schedulePendingRefine()
        case .cleaning:
            startRefineCapture()
        case .capturing, .refining, .pasting:
            // Already capturing or in transient state — ignore the
            // re-trigger.
            return
        }
    }

    /// Hotkey was released (key-up). Whichever capture phase we're
    /// in, this finalizes the audio and runs the ASR-then-LLM
    /// pipeline.
    func hotkeyUp() {
        // Tap-on-awaitingAccept: if the pending refine timer is
        // still armed, the user released before the hold threshold,
        // so they meant "accept" not "refine". Cancel the pending
        // refine and run accept().
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
    func notifySystemReady() {
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
    func notifyDownloadProgress(_ progress: ASRDownloadProgress?) {
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
    func accept() {
        guard phase == .awaitingAccept else { return }
        phase = .pasting
        cancelAutoAcceptTimer()
        let textToPaste = textForPaste(currentText, target: pasteTarget)
        let target = pasteTarget
        // Record to the in-memory transcription history before the
        // paste attempt — even if the paste lands in the wrong app
        // (focus changed mid-flight) the user can grab the text
        // back from the menu bar's Recent Dictations submenu.
        // Stores the bare cleaned text without the trailing-space
        // rule applied, so re-pastes match the user's intent rather
        // than the previous target's convention.
        if !currentText.isEmpty {
            TranscriptHistory.shared.append(TranscriptEntry(
                text: currentText,
                targetAppName: target?.name
            ))
        }
        overlay.hide()
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
    func cancel() {
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
        Task { @MainActor in
            await closeAndReset()
        }
    }

    // MARK: - Phase transitions

    private func startFreshCapture() {
        pasteTarget = Paster.captureFrontmost()
        currentText = ""
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
            phase = .idle
            overlay.hide()
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

        let llm = self.llm
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
                let dictionary = Config.load().config.customDictionary
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
                        self?.phase = .idle
                        self?.overlay.hide()
                    }
                    return
                }

                let useOverlay = !(self?.quickMode ?? false)
                let targetBundleID = self?.pasteTarget?.bundleID
                let outcome = await streamCleanupOrRefine(
                    llm: llm,
                    overlay: overlay,
                    useOverlay: useOverlay,
                    asRefine: asRefine,
                    rawTranscript: asrResult.text,
                    priorText: priorText,
                    targetBundleID: targetBundleID,
                    customDictionary: dictionary
                )
                if Task.isCancelled { return }

                self?.applyResult(outcome.text, cleanupFailureMessage: outcome.failureMessage)
            } catch {
                self?.log("pipeline failed: \(error)")
                self?.phase = .idle
                self?.overlay.hide()
            }
        }
    }

    private func applyResult(_ text: String, cleanupFailureMessage: String? = nil) {
        currentText = text
        if quickMode {
            // Skip the review step entirely. Transition straight to
            // .pasting and paste right away — same flow as accept()
            // but synchronous from the LLM-stream-done callback.
            // Cleanup-failure visibility in quick mode is deferred:
            // the menu-bar badge approach is filed as a follow-up
            // to #27 since it's substantial UI work; for now we
            // log loudly so the user can see the failure in
            // ~/.parleq/app.log when something feels off.
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
        pasteTarget = nil
        quickMode = false
        phase = .idle
        overlay.hide()
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
    let text: String
    let failureMessage: String?
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
    customDictionary: [DictionaryEntry] = []
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

    let systemPrompt = asRefine
        ? SystemPrompts.refine
        : SystemPrompts.cleanup(dictionary: customDictionary)
    let userMessage: String
    if asRefine {
        userMessage = "Current text:\n\(priorText)\n\nEdit instruction:\n\(rawTranscript)"
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
        userMessage = "Transcript to clean up:\n\n\(rawTranscript)"
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
            messages: [LLMMessage(role: "user", content: userMessage)]
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
        let logLine = "[parleq] LLM \(asRefine ? "refine" : "cleanup") stream failed: \(error). Using fallback text.\n"
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
        } else if (error as NSError).domain == NSURLErrorDomain {
            // Non-LLMError NSURLError — shouldn't happen in practice
            // (every provider wraps these) but covers any future
            // direct-throw path.
            failureMessage = networkHint
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
