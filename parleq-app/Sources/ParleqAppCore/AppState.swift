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
    /// Optional third provider for the refine-model tier. When
    /// Config.refineModel is configured, llmForInvocation() returns this
    /// for REFINE-shaped turns (hotkey voice-refine, quick chips, styled
    /// per-app-preset cleanup) instead of llm — so those operations reach
    /// a cloud provider even when the cleanup tier is the on-device
    /// Concord model (which can't perform them). nil → routing falls the
    /// refine tier back to contextLLM, then llm.
    private let refineLLM: (any LLMProvider)?
    /// Enterprise OIDC federation handles. All optional and nil for
    /// non-enterprise users. The session is retained for the Company
    /// Account UI (Task 8); the two exchange caches are pre-warmed at
    /// capture start (the ONLY hot-path addition this feature makes)
    /// so the boundary-hour credential exchange overlaps recording +
    /// ASR instead of delaying cleanup. Failures are swallowed by
    /// warm() and surface fail-closed when cleanup actually runs.
    private let oidcSession: OIDCSession?
    private let oidcAWSExchange: CachedExchange<AWSWebIdentityExchanger>?
    private let oidcGCPExchange: CachedExchange<GCPWorkforceExchanger>?
    /// True in the Vertex `googleOAuth` mode, where there is NO exchange
    /// cache to warm — the session's access token IS the Vertex bearer.
    /// When set, capture-start pre-warms `oidcSession.accessToken()` instead
    /// (fire-and-forget; the refresh-if-needed overlaps recording + ASR).
    private let oidcPrewarmSessionAccessToken: Bool
    /// Injected by main.swift when an OIDC session exists. Runs the
    /// SAME interactive sign-in the Settings → Company Account button
    /// drives (shared OIDCSessionModel), returning whether the session
    /// ended signed in. nil in non-enterprise launches.
    public var oidcInteractiveSignIn: (() async -> Bool)?
    private let overlay: OverlayWindow
    /// Near-transparent floating pulse shown while a quick (double-tap-
    /// hold) dictation records — the visual stand-in for the start
    /// sound, since quick mode shows no overlay. Owned here (not
    /// injected like `overlay`) because it's a self-contained leaf with
    /// no external wiring. Lifecycle driven by `updateRecordingPulse()`.
    private let recordingPulse = RecordingPulseWindow()

    // MARK: - Per-utterance state

    private(set) var phase: Phase = .idle {
        didSet {
            logPhase(from: oldValue, to: phase)
            if oldValue != phase { onPhaseChanged?(phase) }
            // Latched-compose: when the dictation cycle resets to
            // .idle (cancel OR successful submit-and-paste), also
            // reset composeState so the next gesture starts a fresh
            // session. We deliberately do NOT reset on transitions to
            // .awaitingAccept — the user may still iterate via
            // refinement, and the latched session should be
            // considered done only when the cycle FULLY closes.
            if phase == .idle, composeState != .idle {
                composeState = nextComposeState(composeState, event: .submitted)
            }
            // Defense-in-depth: clear the per-hold Space-armed visual
            // flag at dictation-cycle close. startFreshCapture also
            // clears it at every new hotkey-down, but that reset
            // happens AFTER the new dictation's overlay model state
            // has started rendering. Resetting at cycle close keeps
            // the flag's lifetime scoped to the dictation cycle that
            // observed the Space press. Investigation of the related
            // press-Space-after-plain-dictation regression continues
            // in a separate followup (the regression survives this
            // reset, so it has a different root cause).
            if phase == .idle, overlay.model.spaceArmedDuringHold {
                overlay.model.spaceArmedDuringHold = false
            }
            // Clear the latched-from-refining marker on cycle close
            // so a future fresh dictation (entered from .idle, not
            // from .refining) doesn't inherit refine semantics from
            // a prior session. See `latchedFromRefining` docstring.
            if phase == .idle, latchedFromRefining {
                latchedFromRefining = false
            }
            // Force-hide the help overlay on ANY reset to .idle —
            // including cleaning-failure / empty-result paths that don't
            // route through closeAndReset — so the help panel and its
            // flags can't be orphaned past the dictation cycle. Teardown
            // context: don't resume the recorder (it's being stopped).
            if phase == .idle, helpVisible {
                helpVisible = false
                helpPausedRecorder = false
                holdEndedDuringHelp = false
                helpReleaseSpaceWasPressed = false
                helpOverlay.hide()
            }
            // Drive the quick-mode recording pulse off the phase. It's
            // the single source of truth for show/hide, so every exit
            // path (release, cancel, error reset → .idle / .cleaning /
            // …) tears the pulse down without per-callsite bookkeeping.
            updateRecordingPulse()
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
    /// B3: fires when a fresh-capture audio buffer becomes available to
    /// recover (true on the first retained capture of a session). main.swift
    /// wires it to enable/disable the menu-bar "Recover last dictation" item.
    public var onRecoverableDictationChanged: (@MainActor (Bool) -> Void)?
    private var pasteTarget: PasteTarget?
    /// User-chosen send-to destination (picked via V during review).
    /// When set, accept() pastes here instead of the default target.
    /// Reset at the start of every fresh capture.
    private var chosenDestination: PasteTarget?
    /// Which role the shared window picker is currently serving. The
    /// picker's onPick is wired once; this flag routes a pick to either
    /// reference-capture (.source) or send-to-destination (.destination).
    private enum PickerMode { case source, destination }
    private var pickerMode: PickerMode = .source
    /// True when the current latched-compose session was entered
    /// from `.refining` phase (user pressed Space during a refine
    /// hold). Determines what the latched-resume branch sets `phase`
    /// to on a subsequent hold (`.refining` if true, `.capturing`
    /// otherwise) AND what `finalizeCapture` is called with on the
    /// eventual release (`asRefine: true` if true, false otherwise).
    /// Without this flag, latched-resume unconditionally clobbers
    /// `phase` to `.capturing` and the eventual submit drops the
    /// prior refinement's accumulated text — treating the new
    /// audio + new reference as a fresh dictation instead of a
    /// continuation of the refine.
    ///
    /// Lifetime: set when transitioning to `.pickerOpen` from
    /// `.refining` in `hotkeyUp(spaceWasPressedDuringHold: true)`;
    /// cleared when `composeState` resets to `.idle` (via the
    /// `phase == .idle` branch in `phase`'s `didSet`). Survives
    /// across multiple holds within the same latched session.
    private var latchedFromRefining: Bool = false
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
    /// C1 (eager-accept deferral): set when the user presses Enter during
    /// .cleaning before the cleaned result is final. Instead of pasting a
    /// half-streamed fragment + cancelling the stream, we hold the accept;
    /// applyResult() auto-accepts the full cleaned text the instant the
    /// stream completes. Cleared on that auto-accept, on cancel (Esc), and
    /// on every reset path (resetPerDictationOverlayState).
    private var pendingAcceptOnCleanupComplete = false
    /// B2: live dead-mic watchdog. Fed the raw mic peak during capture; flips
    /// the overlay's "⚠ not hearing your mic" warning when input stays flat-
    /// zero past the threshold. Reset at every capture start.
    private var micSignalMonitor = MicSignalMonitor()
    /// A2: debounce for the audio config-change rebuild. A device/format change
    /// posts a burst of notifications; coalesce them into one rebuild ~250 ms
    /// after the last so we don't thrash the engine.
    private var audioConfigRebuildTask: Task<Void, Never>?
    /// Bumped every time the auto-accept timer is cancelled/re-armed.
    /// A fired Timer has already dispatched its `Task { accept() }` onto
    /// the MainActor by the time `invalidate()` runs, so invalidation
    /// alone can't stop a just-fired auto-accept from pasting out from
    /// under a review action (C/Space/V suspend auto-accept but can lose
    /// that race). The queued task captures the generation and bails if
    /// it no longer matches.
    private var autoAcceptGeneration = 0
    /// True once the user attaches a reference (C/Space) DURING review —
    /// a strong signal they intend to refine, not walk away — so the
    /// auto-accept timer suspends rather than pasting the un-refined
    /// text. Set by the references subscription on any count INCREASE
    /// while phase == .awaitingAccept (so it catches a remove-then-add
    /// "replace" edit, which a net-count comparison would miss). Reset
    /// at the start of each review. References carried in from the
    /// original dictation don't set it — only additions made in review.
    ///
    /// One-way within a review cycle, by design (the maintainer chose
    /// "suspend until they act"): once set, removing the attached chip
    /// does NOT clear it or re-arm auto-accept. Attaching signals "I'm
    /// composing a refine"; the user resumes by refining, accepting, or
    /// cancelling — not by un-attaching. Cleared only at the next review
    /// start (applyResult).
    private var didAttachReferenceDuringReview = false
    /// Last-seen reference count, tracked by the references subscription
    /// so it can detect an increase (an attach) vs a removal.
    private var previousReferenceCount = 0
    /// Watches overlay.model.references to set didAttachReferenceDuringReview.
    private var referencesSubscription: AnyCancellable?
    /// Timer that delays the initial overlay show on a fresh capture
    /// so a brief tap (the first half of a double-tap-and-hold, or a
    /// fumbled keypress) doesn't flash the overlay. Cancelled when
    /// the first partial transcript arrives, the utterance is
    /// short-circuited, or the user cancels.
    private var pendingOverlayShowTimer: Timer?
    private var inFlightTask: Task<Void, Never>?  // cleanup or refine task — cancel on abort
    /// The FIRST cleanup's task, captured when the user presses the
    /// hotkey to refine while that cleanup is still streaming
    /// (phase == .cleaning). Held separately from `inFlightTask` so the
    /// refine's own `inFlightTask` reassignment can't lose the handle —
    /// teardown (Esc / accept) must still be able to cancel the cleanup.
    /// nil except during the chained-refine window.
    private var chainedCleanupTask: Task<Void, Never>?
    /// Resolves with the first cleanup's FINAL text (cleaned output, or
    /// the raw fallback on failure) so the chained refine can await the
    /// baseline before building its messages. Created when entering
    /// refine from .cleaning; resolved by applyResult; cleared after the
    /// refine reads it (or on teardown). See BaselineGate.swift.
    private var chainedBaselineGate: BaselineGate?
    /// True while a refine captured during .cleaning is pending — the
    /// first cleanup is running in the background and the refine owns the
    /// next terminal transition. Suppresses the first cleanup's
    /// applyResult from transitioning to .awaitingAccept / arming
    /// auto-accept. Cleared after the refine consumes the baseline or on
    /// teardown.
    private var refineChainedDuringCleanup = false
    /// Low-frequency timer that flushes a small correction-journal
    /// backlog (below the per-capture threshold) to the analyzer when
    /// the user is idle. Rate-capped inside LearningAnalyzer.
    private var learningIdleTimer: Timer?
    /// Raw ASR transcript from the most-recent utterance. Retained so
    /// switchModelAndRecleanup(_:) can re-run cleanup with a different
    /// provider against the original spoken words rather than the
    /// already-cleaned text. Reset at the start of each fresh capture
    /// and cleared in closeAndReset().
    private var lastRawTranscript: String = ""
    /// B3 (recover last dictation): the most recent FRESH capture's audio
    /// (16 kHz mono WAV bytes) + its duration, retained so hold+R or the
    /// menu-bar "Recover last dictation" item can re-run ASR + cleanup on it
    /// when the user loses the result (Esc, hasty double-Enter, focus change).
    /// **Memory-only** — overwritten by the next fresh dictation, wiped on
    /// quit; never written to disk (compliance invariant #1). nil until the
    /// first successful fresh capture this session.
    private var lastDictationAudio: (wav: Data, durationMs: Int)?
    /// Whether the most recent LLM turn was a REFINE — drives
    /// switchModelAndRecleanup's re-run shape (task #41): after a
    /// refine, lastRawTranscript holds the refine INSTRUCTION, and
    /// re-cleaning it as a dictation produced garbage. The switch
    /// re-runs the refine instead (same instruction, same prior text,
    /// new model).
    private var lastTurnWasRefine: Bool = false
    /// The prior text the most recent refine turn operated on — what a
    /// model-switch refine re-run feeds as priorText.
    private var lastRefinePriorText: String = ""

    /// The per-app default preset folded into the CURRENT dictation's
    /// cleanup, if any. Drives the overlay chip, is reused by the
    /// model-switch recleanup so styling survives a provider swap, and
    /// is cleared per dictation and by the style-undo action (wired in a later task).
    private var appliedPreset: TransformPreset?

    /// The per-app default preset resolved for the CURRENT dictation,
    /// independent of whether the cleanup that would have applied it
    /// succeeded. `appliedPreset` tracks what the on-screen text actually
    /// reflects (cleared on every fallback render); this tracks what the
    /// user configured for the target app, so a model-switch re-run after
    /// a failed first cleanup (e.g. image refs on a non-vision model)
    /// still applies the intended styling. Cleared per dictation and
    /// whenever a successful refine / manual transform / style-undo
    /// supersedes the default's claim on this dictation.
    private var intendedDefaultPreset: TransformPreset?

    /// Raw ASR transcript of the dictation that `appliedPreset` styled.
    /// `undoStyle()` replays plain cleanup from THIS snapshot — never
    /// from `lastRawTranscript`, which every refine turn overwrites with
    /// the refine utterance. Without the snapshot, an Undo after any
    /// refine attempt (even a failed one, which keeps the chip) would
    /// "clean" the spoken edit instruction and replace the reviewed
    /// text with the wrong content. Set/cleared in lockstep with
    /// `appliedPreset`.
    private var styledRawTranscript: String = ""

    /// References (post-degradation, exactly as sent) and destination
    /// label of the cleanup call that `appliedPreset` styled. undoStyle()
    /// replays against THESE, not the overlay's current references — if
    /// the user attaches/removes references after the styled result
    /// appears, Undo must still produce the un-styled version of the SAME
    /// dictation-with-context, not a re-generation against new context.
    /// Set/cleared in lockstep with `appliedPreset`/`styledRawTranscript`.
    private var styledReferences: [Reference] = []
    private var styledPasteDestLabel: String?

    /// Per-utterance flywheel accumulator. See PendingContribution +
    /// flushContribution. nil unless an ARMED fresh capture is in flight.
    private var pendingContribution: PendingContribution?

    // 0.14.0 PR 4 (#219): per-dictation timing capture for the Stats
    // section in PR 5. All three reset on every fresh capture; ASR
    // / LLM latencies are populated by the cleanup pipeline as it
    // runs, then read at accept() time when the TranscriptEntry is
    // built. Audio duration is captured at recorder-stop time
    // (capture.durationSeconds) which is the actual audio length,
    // not the wall-clock from hotkey-down to accept — the latter
    // would include LLM streaming + user review time.

    /// Recorded audio duration in milliseconds for the most recent
    /// capture. Populated immediately after `recorder.stop()`
    /// returns the Capture in finalizeCapture. 0 between
    /// dictations or when the recorder didn't produce audio
    /// (cancelled mid-capture).
    private var lastAudioDurationMs: Int = 0

    /// ASR latency in milliseconds for the most recent dictation.
    /// Populated immediately after the ASR call returns; read at
    /// accept() time. nil when ASR was skipped (empty utterance)
    /// or hasn't run yet for the current capture.
    private var lastASRLatencyMs: Int?

    /// LLM cleanup latency in milliseconds for the most recent
    /// dictation. Populated when streamCleanupOrRefine completes
    /// successfully; read at accept() time. nil when cleanup was
    /// skipped (no LLM configured / empty transcript) or failed
    /// before timing. Also re-populated by switchModelAndRecleanup
    /// so accepting after a model switch records the LATENCY OF
    /// THE ACCEPTED CLEANUP, not the originally-rendered one.
    private var lastLLMLatencyMs: Int?

    /// Stable identity for the active dictation session. Minted once
    /// per fresh dictation (in `startFreshCapture`) and **reused**
    /// across all refine turns within the same overlay session so
    /// copy → refine → accept all land on a single history entry.
    /// Cleared by `resetPerDictationOverlayState()` when the session
    /// ends. `appendTranscriptHistory` and `copy()` both build their
    /// `TranscriptEntry` with this id and route through
    /// `TranscriptHistory.upsert(_:)` so duplicate rows are never
    /// created for the same session.
    private var currentSessionEntryID: UUID?

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
    /// "?" help overlay — a transient floating panel listing every
    /// gesture. Shown while the dictation overlay has focus.
    private let helpOverlay = HelpOverlayWindow()
    /// True while the help panel is up. Used to pause the in-progress
    /// dictation (audio preserved) and to suppress submit-on-release so
    /// reading help can't accidentally finalize or pollute the capture.
    private var helpVisible = false
    /// True when showHelp() paused the recorder, so hideHelp() knows to
    /// resume it (and doesn't resume a recorder that was never running,
    /// e.g. help opened from the review state).
    private var helpPausedRecorder = false
    /// True when the hotkey was RELEASED while help was up (so there's no
    /// pending hotkeyUp to finalize the capture). hideHelp() then
    /// replays the release through hotkeyUp() instead of resuming into a
    /// capture with no terminator.
    private var holdEndedDuringHelp = false
    /// The `spaceWasPressedDuringHold` value from the release that
    /// happened while help was up, so hideHelp() can replay it faithfully
    /// (latched-compose vs plain submit).
    private var helpReleaseSpaceWasPressed = false
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
    public private(set) var quickMode = false {
        didSet {
            // quickMode can flip false mid-capture (e.g. the user
            // presses Space, handing off to the full overlay) without a
            // phase change, so reconcile the pulse here too.
            if oldValue != quickMode { updateRecordingPulse() }
        }
    }

    /// #83: true while a hands-free continuous recording is in progress. Entered
    /// by the double-tap-and-release gesture; the mic stays hot after the gesture
    /// releases and a subsequent hotkey tap (or Esc) stops it. Distinct from
    /// quickMode (which finalizes on release) and the latched-compose machine
    /// (which pauses the mic).
    public private(set) var continuousRecording = false

    /// #83: set when a hotkey tap stops a continuous recording, so the matching
    /// key-up (which arrives a moment later) is swallowed rather than re-entering
    /// the capture machinery.
    private var stopTapAwaitingKeyUp = false

    /// #85: the review text snapshotted when in-place edit mode opened, so the
    /// corrections journal can record the before/after of a confirmed edit.
    private var editPreEditText = ""

    // The configured auto-accept delay. Default 6 s per the design;
    // wired to Config.autoAcceptSeconds at construction time.
    private var autoAcceptInterval: TimeInterval

    /// How long to wait after hotkey-down before showing the overlay
    /// for a fresh capture. Empirical: 200 ms is longer than any
    /// realistic first-tap of a double-tap-and-hold gesture (50–150 ms)
    /// and short enough that a real hold still gets visual feedback
    /// before the user has finished their first word.
    /// How long to wait after hotkey-down before showing the overlay
    /// for a fresh capture. User-configurable via Config.overlayShowDelayMs
    /// (#56); refreshed from config at every fresh capture so a
    /// Settings change takes effect on the next dictation. Default
    /// 200ms — longer than any realistic first-tap of a double-tap-
    /// and-hold gesture (50–150 ms) and short enough that a real
    /// hold still gets visual feedback before the first word.
    private var overlayShowDelaySeconds: TimeInterval = 0.20

    /// Whether the quick-mode recording pulse is enabled. Refreshed
    /// from `Config.recordingPulse` at every fresh capture so a Settings
    /// toggle takes effect on the next dictation without a restart.
    private var recordingPulseEnabled = true

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
    /// Generation token guarding the refine timer's dispatched task —
    /// same race as autoAcceptGeneration. cancelPendingRefine() (called
    /// by showHelp, among others) invalidates the timer, but a refine
    /// that already fired keeps phase at .awaitingAccept, so its queued
    /// task would otherwise call startRefineCapture() under the help
    /// overlay. The task bails when the generation no longer matches.
    private var refineGeneration = 0
    private static let refineHoldThreshold: TimeInterval = 0.18
    /// In-flight reference capture tasks spawned from any of the
    /// async reference-attachment paths (window pick, file pick,
    /// pick-by-clicking). Tracked so a fast hotkey-release-without-space
    /// submit (the tap-to-send gesture after picking a window) can
    /// await pending captures before finalizing — otherwise the
    /// ASR/LLM pipeline could read overlay.model.references before
    /// the async capture call appends the picked reference, and the
    /// composition would submit without it.
    ///
    /// Keyed by UUID rather than a plain array so completed tasks can
    /// self-remove via the trackCaptureTask completion handler — that
    /// way a second submit gesture can't see an empty list while
    /// the first submit is still awaiting (which would let the second
    /// finalize early and produce a submission with the wrong audio
    /// or no references). Tasks stay in the dictionary until they
    /// fully complete, regardless of whether anyone is awaiting them.
    private var pendingCaptureTasks: [UUID: Task<Void, Never>] = [:]

    /// State of the Reference Windows v2 latched-compose gesture
    /// flow. Layered ON TOP of `phase` — phase tracks the dictation
    /// lifecycle (capturing, cleaning, awaiting accept); composeState
    /// tracks whether the user is in the latched-compose flow and
    /// where within it. When composeState is .idle, AppState behaves
    /// identically to v1 (release submits). When the user presses
    /// Space during a hold, composeState advances through
    /// .pickerOpen / .latched / .latchedRecording and the
    /// release-submits behavior is replaced with release-stays-latched
    /// until a release-without-Space fires the submit pipeline.
    ///
    /// See `LatchedComposeState.swift` for the transition table.
    /// didSet mirrors the value into overlay.model.composeState so
    /// the SwiftUI overlay (OverlayHintStrip) can re-render its
    /// per-state hint copy reactively without each callsite having
    /// to remember to push the value across.
    private var composeState: ComposeState = .idle {
        didSet {
            if oldValue != composeState {
                overlay.model.composeState = composeState
            }
        }
    }
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
        refineLLM: (any LLMProvider)? = nil,
        overlay: OverlayWindow,
        autoAcceptSeconds: TimeInterval = 0,  // 0 = never auto-accept
        trailingSpaceEnabled: Bool = true,
        noTrailingSpaceAppBundleIDs: [String] = [],
        oidcSession: OIDCSession? = nil,
        oidcAWSExchange: CachedExchange<AWSWebIdentityExchanger>? = nil,
        oidcGCPExchange: CachedExchange<GCPWorkforceExchanger>? = nil,
        oidcPrewarmSessionAccessToken: Bool = false
    ) {
        self.recorder = recorder
        self.asr = asr
        self.llm = llm
        self.contextLLM = contextLLM
        self.refineLLM = refineLLM
        self.oidcSession = oidcSession
        self.oidcAWSExchange = oidcAWSExchange
        self.oidcGCPExchange = oidcGCPExchange
        self.oidcPrewarmSessionAccessToken = oidcPrewarmSessionAccessToken
        self.overlay = overlay
        self.autoAcceptInterval = autoAcceptSeconds
        self.trailingSpaceEnabled = trailingSpaceEnabled
        self.noTrailingSpaceAppBundleIDs = Set(noTrailingSpaceAppBundleIDs)
        overlay.onAccept = { [weak self] in self?.accept() }
        overlay.onSendTo = { [weak self] in self?.sendToPressed() }
        overlay.onShowHelp = { [weak self] in self?.showHelp() }
        overlay.onAttachWindow = { [weak self] in self?.attachWindowFromReview() }
        overlay.onAttachCurrent = { [weak self] in self?.attachCurrentWindowFromReview() }
        overlay.onShowParleq = { [weak self] in self?.pPressedDuringReview() }
        helpOverlay.onDismiss = { [weak self] in self?.hideHelp() }
        overlay.onCancel = { [weak self] in self?.cancel() }
        overlay.onCopy = { [weak self] in self?.copy() }
        overlay.onShowWindowPicker = { [weak self] in
            guard let self else { return }
            // Pause audio if we're mid-capture so user interaction
            // with the picker doesn't get recorded into the
            // composition. presentPicker() handles the state-machine
            // transition.
            if self.phase == .capturing { self.recorder.pause() }
            self.presentPicker()
        }
        overlay.onSwitchToVisionModelAndRecleanup = { [weak self] id in
            self?.switchModelAndRecleanup(id)
        }
        overlay.onRunPreset = { [weak self] id in self?.runPreset(id: id) }
        overlay.onRunPresetNumber = { [weak self] n in self?.runPresetByNumber(n) ?? false }
        overlay.onUndoStyle = { [weak self] in self?.undoStyle() }
        // Wire the overlay's async file-pick into AppState's pending-
        // capture bookkeeping. Submit (hotkeyUp) and accept() both
        // wait on / cancel pendingCaptureTasks; without this, an
        // overlay-initiated Add file that resolves after submit can
        // leak its append into the next session.
        overlay.model.onTrackCaptureTask = { [weak self] task in
            self?.trackCaptureTask(task)
        }
        overlay.model.onReauthSignIn = { [weak self] in self?.reauthSignIn() }
        overlay.model.onReauthReclean = { [weak self] in self?.reauthReclean() }
        // #85: in-place edit callbacks.
        overlay.model.onEnterEdit = { [weak self] in self?.enterEditMode() }
        overlay.model.onCommitEdit = { [weak self] accept in self?.commitEdit(accept: accept) }
        overlay.model.onDiscardEdit = { [weak self] in self?.discardEdit() }

        windowPickerWindow.setCallbacks(
            onPick: { [weak self] entry in
                guard let self else { return }
                switch self.pickerMode {
                case .source:
                    self.dismissPicker()
                    // Track the capture task so a fast submit (release
                    // hotkey without space immediately after picking)
                    // can await it before finalizing. Without this, the
                    // race window between picker-dismiss and async
                    // capture-append could submit the composition with
                    // a missing reference. See trackCaptureTask /
                    // awaitPendingCaptures below.
                    let task = Task { @MainActor in
                        await self.capture(entry)
                    }
                    self.trackCaptureTask(task)
                case .destination:
                    // Destination pick (send-to). Not part of the
                    // latched-compose flow, so hide directly rather than
                    // routing through dismissPicker (which mutates
                    // composeState).
                    self.windowPickerWindow.hide()
                    self.setDestination(from: entry)
                }
                // Always fall back to source mode after a pick so a
                // later reference pick can't be misrouted.
                self.pickerMode = .source
            },
            onAddFile: { [weak self] in
                // Add-File / Add-Clipboard / Pick-by-clicking are
                // source-capture actions. If invoked while the picker is
                // in destination (send-to) mode, abort the send-to
                // cleanly instead of half-switching to source semantics
                // (which previously dropped the auto-accept timer or
                // misrouted a later pick). Otherwise run the source action.
                Task { @MainActor in
                    guard let self else { return }
                    if self.abortSendToIfDestination() { return }
                    self.handleAddFileFromPicker()
                }
            },
            onAddClipboard: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if self.abortSendToIfDestination() { return }
                    self.handleAddClipboardFromPicker()
                }
            },
            onPickByClicking: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if self.abortSendToIfDestination() { return }
                    self.handlePickByClickingFromPicker()
                }
            }
        )
        // Native close paths (title-bar close button, Esc, Cmd-W)
        // route through onDismiss. Our own dismissPicker() uses
        // orderOut and does NOT fire windowWillClose, so this
        // callback fires only when the user takes one of those
        // native paths without selecting anything.
        // windowWillClose fires on MainActor (WindowPickerWindow +
        // AppState are both @MainActor); execute the state
        // transition synchronously rather than deferring through a
        // Task so a rapid sequence (native picker close immediately
        // followed by a hotkey press) doesn't observe a stale
        // composeState in the interim.
        windowPickerWindow.onDismiss = { [weak self] in
            guard let self else { return }
            self.composeState = nextComposeState(
                self.composeState,
                event: .pickerDismissed
            )
            // If the send-to (destination) picker was abandoned via a
            // native close without choosing a window, restore source
            // mode and re-arm auto-accept (sendToPressed cancelled it
            // when opening the picker). Our own hide() on a successful
            // pick uses orderOut and does not fire onDismiss, so this
            // only runs on the abandon path.
            if self.pickerMode == .destination {
                self.pickerMode = .source
                if self.phase == .awaitingAccept {
                    self.startAutoAcceptTimer()
                }
            }
        }

        pasteTargetSubscription = pasteTargetTracker.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] target in
                self?.overlay.model.pasteTarget = target
            }

        // Flag a review-time reference attach the moment the count goes
        // UP while in review, from any append path (picker pick, hold/
        // review C, Add file, Add clipboard, click-pick). Comparing
        // against the last-seen count (not the review-start baseline)
        // catches a remove-then-add "replace" edit, where the net count
        // is unchanged but the user did attach new context.
        referencesSubscription = overlay.model.$references
            .receive(on: DispatchQueue.main)
            .sink { [weak self] refs in
                guard let self else { return }
                if self.phase == .awaitingAccept, refs.count > self.previousReferenceCount {
                    self.didAttachReferenceDuringReview = true
                }
                self.previousReferenceCount = refs.count
            }

        // One-time launch cleanup: delete any legacy on-disk correction
        // files written by an earlier disk-backed build of "learn from
        // corrections". Runs here (AppState is built unconditionally at
        // launch) rather than in the stores' lazy init, so it fires even
        // when the feature is off (the default) and the stores are never
        // touched — otherwise an upgraded machine could retain
        // dictation-derived data on disk for the whole session.
        CorrectionJournal.purgeLegacyOnDiskFile()
        LearnedStore.purgeLegacyOnDiskFile()

        // Idle flush for "learn from corrections": every 5 min, if there
        // are any unanalyzed corrections and the rate cap has elapsed,
        // run analysis with threshold=1 to catch a small backlog.
        learningIdleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let (cfg, _) = Config.load()
                guard cfg.learnFromCorrectionsEnabled,
                      let provider = self.resolveLearningProvider() else { return }
                await LearningAnalyzer.shared.runIfDue(provider: provider, threshold: 1)
            }
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

    /// The cleanup-tier provider for off-path learning analysis — the
    /// same one built at launch from config. nil when no usable provider
    /// is configured (e.g. provider=none); analysis then simply doesn't run.
    private func resolveLearningProvider() -> (any LLMProvider)? {
        return llm
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
        // If the help overlay is up, a hotkey press dismisses it and
        // RESUMES the paused dictation — "press the hotkey to resume."
        // This is distinct from an Esc/?/click dismiss: if the user
        // released the hotkey while help was up and now presses it to
        // continue, we must resume (not replay that release as a submit).
        // When help was opened from review (.awaitingAccept), the press
        // simply dismisses and returns to review (re-arming auto-accept);
        // the reviewed text is still there to accept/cancel.
        if helpVisible {
            dismissHelpForResume()
            return
        }
        // #83: a hotkey tap while continuously recording STOPS it — finalize the
        // captured audio through the normal review path. The matching key-up is
        // swallowed (stopTapAwaitingKeyUp) so it doesn't re-trigger anything.
        if continuousRecording {
            continuousRecording = false
            stopTapAwaitingKeyUp = true
            log("hotkeyDown stops continuous recording → finalize")
            finalizeCapture(asRefine: false)
            return
        }
        // Reset the per-hold Space-armed visual flag at every fresh
        // hotkey-down. The flag's semantic is "Space has been pressed
        // during THIS specific hold" — scoping it to a single hold.
        // Without this reset the flag survives across latched-compose
        // re-holds (e.g. .latched → .latchedRecording when the user
        // resumes after picking a reference), so the second hold's
        // overlay opens already showing the "Picker opens on release"
        // armed variant even though the user hasn't pressed Space
        // yet in this hold. startFreshCapture clears it too for the
        // .idle → fresh-dictation path, but that doesn't cover the
        // latched-compose resume branches that bypass
        // startFreshCapture.
        if overlay.model.spaceArmedDuringHold {
            overlay.model.spaceArmedDuringHold = false
        }
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

        // Latched-compose resume branch. When composeState is
        // .latched, the recorder is paused (engine still running) and
        // the overlay is locked open with prior audio segments + refs
        // accumulated. A fresh hotkey-down here resumes audio capture
        // into a new appended segment rather than starting fresh.
        // Skips the entire phase-switch below because we're not
        // entering a NEW dictation — we're continuing the current one.
        if composeState == .latched {
            composeState = nextComposeState(composeState, event: .hotkeyDown)
            // If the latched session was entered from a refine, the
            // resume keeps refine semantics — phase stays `.refining`
            // and the eventual release will call
            // `finalizeCapture(asRefine: true)` so the prior text
            // isn't dropped. See `latchedFromRefining` docstring.
            phase = latchedFromRefining ? .refining : .capturing
            // B2 follow-up (RoboRev): a fresh latched hold begins here, but
            // resume() doesn't route through openRecorder(), so clear the
            // dead-mic watchdog explicitly — otherwise a prior hold's flat-zero
            // tail can trip a spurious "not hearing your mic" early in this one.
            micSignalMonitor.reset()
            overlay.model.notHearingMic = false
            recorder.resume()
            log("hotkeyDown in latched compose → \(latchedFromRefining ? "latched-refining" : "latchedRecording"); audio resumed")
            return
        }
        // User pressed the hotkey while the picker is still open.
        // The state machine defines .pickerOpen + .hotkeyDown →
        // .latchedRecording — dismiss the picker, resume audio,
        // continue dictation. Lets an impatient user skip past the
        // picker without manually closing it first.
        if composeState == .pickerOpen {
            dismissPicker()
            composeState = nextComposeState(composeState, event: .hotkeyDown)
            phase = latchedFromRefining ? .refining : .capturing
            // B2 follow-up (RoboRev): same as the latched branch — a fresh hold
            // resumes outside openRecorder(), so reset the dead-mic watchdog.
            micSignalMonitor.reset()
            overlay.model.notHearingMic = false
            recorder.resume()
            log("hotkeyDown while picker open → \(latchedFromRefining ? "refining" : "latchedRecording"); audio resumed")
            return
        }

        switch phase {
        case .idle:
            if isShiftHeld {
                // Shift+hotkey = staging mode: open the overlay so the
                // user can curate references before speaking. No audio
                // captured. Picker auto-opens since that's the point.
                enterStaging()
                return
            }
            // #84: the double-tap-and-HOLD gesture is configurable between Quick
            // mode (default) and Dictate (Settings offers only those two for the
            // hold — continuous/off belong to the release gesture). We can't yet
            // know at key-down whether this double-tap will be a hold or a quick
            // release, so always start a capture and set quickMode only for the
            // quickMode action; if it turns out to be a release, hotkeyUp
            // reinterprets it (continuous / cancel) via wasDoubleTapRelease (#83).
            let dtAction = isDoubleTapHold
                ? Config.load().config.hotkeyGestureMap.action(for: .doubleTapHold)
                : .dictate
            quickMode = (dtAction == .quickMode)
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
            dismissPicker()
            startFreshCapture()
        case .awaitingAccept:
            // If a send-to (destination) picker is open, a hotkey hold
            // means the user wants to refine/accept — not send-to. Close
            // the stray picker and restore source mode before proceeding,
            // so we don't schedule a refine with the picker still
            // floating and pickerMode stuck at .destination. (Timer is
            // governed by schedulePendingRefine below, so no re-arm here.)
            if pickerMode == .destination {
                windowPickerWindow.hide()
                pickerMode = .source
            }
            // Phase 1 contract: tap = accept, hold = refine. We
            // schedule a 0.18 s timer; if the user releases before
            // it fires (tap), hotkeyUp calls accept(). If it fires
            // (hold), refine capture starts. Task 13 tried to route
            // hold to pick-mode here, but that broke iterative
            // refinement — the core Phase 1 feature.
            schedulePendingRefine()
        case .cleaning:
            // The first cleanup is still streaming. Capture the refine
            // INSTRUCTION immediately WITHOUT cancelling that cleanup —
            // it runs to completion in the background and becomes the
            // baseline the refine applies to. (Contrast startRefineCapture,
            // used from .awaitingAccept, which cancels the prior turn.)
            startChainedRefineCapture()
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
        presentPicker()
    }

    /// #83: transition the in-flight capture into a hands-free continuous
    /// recording. The recorder (hot since key-down) keeps running — we neither
    /// pause nor finalize. The overlay switches to the recording state with a
    /// stop hint. Stopped by a hotkey tap (hotkeyDown) or cancelled by Esc.
    private func enterContinuousRecording() {
        quickMode = false
        continuousRecording = true
        overlay.model.continuousRecording = true
        // Show the recording overlay immediately — a hands-free session must be
        // visible (normal holds defer the overlay behind overlayShowDelaySeconds).
        overlay.show(state: .capturing, text: "")
        log("entered continuous recording (hands-free; tap or Esc to stop)")
    }

    /// Hotkey was released (key-up). Whichever capture phase we're
    /// in, this finalizes the audio and runs the ASR-then-LLM
    /// pipeline.
    ///
    /// `spaceWasPressedDuringHold` reports whether the user pressed
    /// Space at any point during the hold that's now ending.
    /// HotkeyListener tracks this flag per-hold. The latched-compose
    /// state machine routes on this flag:
    ///   - false → existing v1 release-submits flow (finalizeCapture)
    ///   - true → pause audio + open picker, latch the overlay.
    ///     Audio segments accumulate across multiple holds in this
    ///     session and submit together at the eventual release-without-
    ///     space.
    public func hotkeyUp(spaceWasPressedDuringHold: Bool = false,
                         wasDoubleTapRelease: Bool = false) {
        // #83: swallow the key-up that follows a stop-tap (the tap that ended a
        // continuous recording in hotkeyDown) so it doesn't re-enter capture.
        if stopTapAwaitingKeyUp {
            stopTapAwaitingKeyUp = false
            return
        }
        // #83: a double-tap-and-release while capturing latches into continuous
        // recording instead of finalizing — the mic (hot since key-down) keeps
        // running hands-free until a stop tap or Esc. Resolved against the
        // configurable gesture map (default: continuous; remappable / disablable).
        // Guarded by wasDoubleTapRelease, which is false for every existing path,
        // so normal dictation/quick-mode/compose flows are untouched.
        if wasDoubleTapRelease, phase == .capturing, !continuousRecording,
           !spaceWasPressedDuringHold {
            switch Config.load().config.hotkeyGestureMap.action(for: .doubleTapRelease) {
            case .continuousRecording:
                enterContinuousRecording()
                return
            case .disabled:
                // Double-tap-and-release is turned off → discard the brief capture
                // started at key-down rather than pasting a near-empty quick result.
                cancel()
                return
            case .quickMode, .dictate:
                break  // fall through to the normal release/finalize path
            }
        }
        // While the help overlay is up, a release must NOT submit the
        // utterance — the user paused to read help, not to finish. Record
        // that the hold ended so dismissing help finalizes the preserved
        // buffer (rather than resuming into a capture with no pending
        // release). The capture stays paused until help is dismissed.
        if helpVisible {
            holdEndedDuringHelp = true
            helpReleaseSpaceWasPressed = spaceWasPressedDuringHold
            return
        }
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

        // Latched-compose branch: Space was pressed during the hold
        // → don't submit. Pause audio so subsequent picker interaction
        // doesn't get captured, open the picker, latch the overlay.
        // The accumulated audio sits in the recorder until either a
        // later hotkeyUp(space:false) submits OR Esc cancels.
        // Refinement flow (.refining phase) deliberately bypasses
        // latched-compose — refinement is its own existing iteration
        // model; we don't pivot it into latched mode.
        //
        // Gate on referenceWindowsEnabled (Privacy & Features /
        // MDM master switch) so users / IT admins who disabled
        // reference capture can't accidentally bypass that switch
        // via the new Space gesture. When disabled, fall through
        // to the normal submit path.
        if spaceWasPressedDuringHold {
            let rwEnabled = Config.load().config.referenceWindowsEnabled
            // Keep the overlay's model in sync so OverlayHintStrip
            // suppresses its teaching copy when the feature is off
            // (otherwise the hint would promise "Press Space to
            // attach a window" while the same flag prevents Space
            // from doing anything).
            overlay.model.referenceWindowsEnabled = rwEnabled
            // Honor the press-Space-attach gesture during BOTH active
            // dictation phases. Originally only .capturing was gated;
            // .refining is also an active hold from the user's
            // perspective (they're recording audio that will merge
            // into / replace the current dictation), so refusing
            // Space there breaks the "press Space anytime to attach"
            // mental model. The latched-compose state machine
            // handles both phases identically once we route into
            // .pickerOpen.
            if (phase == .capturing || phase == .refining), rwEnabled {
                // Remember if we're entering latched compose from a
                // refine — used by the latched-resume + finalize
                // branches to preserve refine semantics across the
                // intervening picker / latched-recording cycle.
                latchedFromRefining = (phase == .refining)
                recorder.pause()
                // Quick mode bypasses the review overlay and paste-
                // directly path. Latched compose requires the picker
                // + review overlay, so the two modes are mutually
                // exclusive. If the user started a double-tap-hold
                // (quickMode=true) and then pressed Space, drop
                // quick mode so submit takes the normal review path
                // — otherwise the eventual submit would skip
                // resetPerDictationOverlayState and leak references
                // into the next dictation.
                quickMode = false
                // Cancel any pending overlay-show timer. The 200ms
                // delay between hotkey-down and overlay.show() exists
                // to suppress the overlay flash on a quick stray tap;
                // if Space lands before that timer fires we don't want
                // the timer to later show the overlay as key on top of
                // (or stealing focus from) the freshly-opened picker.
                cancelPendingOverlayShow()
                // …but if the timer hadn't fired yet (sub-200ms hold
                // before Space), the overlay was never shown — which
                // would leave the latched composition completely
                // invisible after the picker dismisses (no chips, no
                // hint strip, no cancel affordance). Force it visible
                // here so the latched flow always has UI to anchor
                // to. overlay.show() is idempotent on visibility, so
                // this is a no-op when the timer already fired.
                overlay.show(state: .capturing, text: "")
                // presentPicker handles both the windowPickerWindow.show()
                // call and the .pickerOpen state-machine transition,
                // so the open path stays consistent across all
                // entry points (here, overlay + button, .staging).
                presentPicker()
                log("hotkeyUp(space=true): latched compose → pickerOpen; audio paused")
                return
            }
            // Narrowed log: only fire when the feature flag IS the
            // deciding factor (an active dictation phase means we'd
            // have taken the latch path).
            if (phase == .capturing || phase == .refining), !rwEnabled {
                log("hotkeyUp(space=true) but referenceWindowsEnabled=false; falling through to normal submit")
            }
        }

        switch phase {
        case .capturing:
            // Don't finalize if the picker is open — the user is
            // mid-attach, not mid-submit. Could happen if the user
            // opened the picker via the overlay + button (which
            // pauses audio but leaves phase=.capturing) and then
            // released the hotkey. composeState being .pickerOpen
            // means "we're interacting with the picker"; let the
            // picker close naturally and re-enter via the next
            // hotkey gesture.
            if composeState == .pickerOpen {
                log("hotkeyUp while .pickerOpen — picker is active, not submitting")
                return
            }
            // Update compose state BEFORE finalizing so the submit
            // pipeline sees the correct .idle / submission flow.
            composeState = nextComposeState(
                composeState,
                event: .hotkeyUp(spaceWasPressedDuringHold: false)
            )
            // Audio handoff happens HERE — synchronously, before any
            // async waiting. Pausing the recorder freezes the audio
            // at the moment of release; without this, the recorder
            // would keep capturing during the awaitPendingCaptures()
            // window below and any ambient noise / user interaction
            // sounds would land in the final WAV. recorder.stop()
            // inside finalizeCapture will then return the audio
            // captured up through the pause moment.
            if !pendingCaptureTasks.isEmpty {
                recorder.pause()
                // Cancel any prior in-flight task before launching the
                // wait-and-finalize task. Without this, a rapid double-
                // release could create two wait-and-finalize tasks
                // that both resume after the awaits complete and both
                // call finalizeCapture — the second tries to stop an
                // already-stopped recorder and resets state mid-pipeline.
                inFlightTask?.cancel()
                // Track the wait-and-finalize task in inFlightTask so
                // cancel() can interrupt it. Without this, a cancel
                // while we're awaiting pending captures would proceed
                // to finalizeCapture against reset state — corrupting
                // the next session. The isCancelled check after the
                // await guards the same race for the case where the
                // task wakes up just as cancel completes.
                inFlightTask = Task { @MainActor [weak self] in
                    await self?.awaitPendingCaptures()
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    self.finalizeCapture(asRefine: false)
                }
            } else {
                finalizeCapture(asRefine: false)
            }
        case .refining:
            // Mirrors the `.capturing` bookkeeping above. The
            // 0.14.0 latched-compose-from-refine flow can leave
            // pending async reference-attach Tasks in flight at
            // the refine's release moment (e.g. user pressed Space
            // mid-refine, picked a window, picker's async append
            // hasn't resolved yet, user re-holds and submits) —
            // without pause-and-await here, the cleanup task would
            // read `overlay.model.references` before the picked
            // reference lands in the array, dropping it from the
            // refine. composeState advance + recorder pause +
            // pendingCaptureTasks await + inFlightTask serialization
            // all replicated; only the eventual `asRefine` flag
            // differs.
            if composeState == .pickerOpen {
                log("hotkeyUp while .pickerOpen during refine — picker is active, not submitting")
                return
            }
            composeState = nextComposeState(
                composeState,
                event: .hotkeyUp(spaceWasPressedDuringHold: false)
            )
            if !pendingCaptureTasks.isEmpty {
                recorder.pause()
                inFlightTask?.cancel()
                inFlightTask = Task { @MainActor [weak self] in
                    await self?.awaitPendingCaptures()
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    self.finalizeCapture(asRefine: true)
                }
            } else {
                finalizeCapture(asRefine: true)
            }
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
        let gen = refineGeneration
        pendingRefineTimer = Timer.scheduledTimer(
            withTimeInterval: AppState.refineHoldThreshold, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Bail if this timer was cancelled/superseded after it
                // fired but before this task ran (e.g. "?" opened help,
                // which leaves phase == .awaitingAccept so the phase
                // guard below wouldn't catch it).
                guard self.refineGeneration == gen else { return }
                self.pendingRefineTimer = nil
                guard self.phase == .awaitingAccept, !self.helpVisible else { return }
                self.startRefineCapture()
            }
        }
    }

    private func cancelPendingRefine() {
        pendingRefineTimer?.invalidate()
        pendingRefineTimer = nil
        refineGeneration &+= 1
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

    /// Centralized picker-close path. Every site that closes the
    /// window picker MUST route through here so the latched-compose
    /// state machine consistently transitions on dismissal. Without
    /// this, the four picker actions (pick / add-file / add-clipboard
    /// / pick-by-clicking) each call `windowPickerWindow.hide()` and
    /// the state machine only saw three of them (or one), leaving
    /// composeState stuck in `.pickerOpen` after the others.
    ///
    /// nextComposeState's same-state fallthrough makes this a no-op
    /// when we're not in the latched flow (composeState is .idle),
    /// so non-latched callers don't need a separate code path.
    private func dismissPicker() {
        windowPickerWindow.hide()
        composeState = nextComposeState(composeState, event: .pickerDismissed)
    }

    /// Centralized picker-open path. Mirror of dismissPicker for the
    /// open direction. Every site that opens the window picker for
    /// the latched-compose flow MUST route through here so the
    /// state machine consistently transitions to .pickerOpen — the
    /// hotkeyDown handlers (.latched branch + .pickerOpen branch)
    /// rely on composeState being .pickerOpen to know the picker is
    /// visible. Without this, the overlay's + button could open the
    /// picker without transitioning, leaving the next hotkey press
    /// to take the .latched resume branch with the picker still
    /// visible.
    ///
    /// Does NOT pause the recorder — that's the caller's
    /// responsibility (e.g. hotkeyUp's space-pressed branch pauses
    /// before calling here; the overlay + button click pauses
    /// inside its caller chain). Separating concerns keeps this
    /// helper trivial.
    private func presentPicker() {
        // Source-context open. Reset the mode so a previously-cancelled
        // destination pick can't leave the picker routing to send-to.
        pickerMode = .source
        windowPickerWindow.show()
        // Synthesize a "picker opened" transition. Use the existing
        // events to walk through .recording / .latchedRecording →
        // .pickerOpen by simulating .hotkeyUp(space:true) — that's
        // the state-machine path for "we paused audio and opened a
        // picker." When called from .idle (the staging path) this
        // is a no-op via the default fallthrough.
        composeState = nextComposeState(
            composeState,
            event: .hotkeyUp(spaceWasPressedDuringHold: true)
        )
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
        // Tracked the same way as the picker's onPick path so a fast
        // tap-to-send after pick-by-clicking can't outrace the
        // async SCK capture.
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let reference = try await self.captureService.captureWindow(
                    windowID: target.windowID,
                    displayTitle: target.appName
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.overlay.model.references.append(reference)
                    // Restore focus to the user's origin Space/app
                    // after a cross-Space capture. The capture may
                    // have switched the visible Space to the source
                    // app's full-screen Space; without this, the
                    // user is stranded there. See
                    // restoreFocusToDictationOrigin for why this is
                    // at the outer scope rather than relying on the
                    // inner restorePriorFrontmost.
                    self.restoreFocusToDictationOrigin()
                    // Single-pick exit: when pick-mode was entered via the
                    // WindowPicker's "Pick by clicking" button, exit
                    // immediately after a successful capture. The
                    // alternative entry paths (staging-pick timer +
                    // awaitingAccept-refine-timer fall-through into
                    // beginHoldPickMode) keep pick mode sticky for
                    // multi-pick, so this flag toggles the exit
                    // semantic per entry path.
                    if self.isPickByClickingSinglePick {
                        self.endHoldPickMode()
                    }
                }
            } catch CaptureError.permissionDenied {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.overlay.model.permissionPrompt = "Screen Recording permission needed. Grant in System Settings, then try again."
                    self.restoreFocusToDictationOrigin()
                }
            } catch let captureError as CaptureError {
                guard !Task.isCancelled else { return }
                // CaptureError already produces a user-facing description
                // (LocalizedError conformance), so surface it as-is
                // rather than wrapping in "Couldn't capture window:"
                // which is redundant for messages like the
                // full-screen-Space case ("Simulator is in a full-
                // screen Space. Switch…").
                await MainActor.run {
                    self.overlay.model.errorMessage = captureError.localizedDescription
                    self.restoreFocusToDictationOrigin()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.overlay.model.errorMessage = "Couldn't capture window: \(error.localizedDescription)"
                    self.restoreFocusToDictationOrigin()
                }
            }
        }
        trackCaptureTask(task)
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
        dismissPicker()
        // Activate Parleq so NSOpenPanel becomes the key window.
        NSApplication.shared.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Register the tracking task BEFORE the panel opens. Earlier
        // versions registered only INSIDE panel.begin's completion
        // handler, leaving the entire panel-open interval invisible
        // to cancelPendingCaptures() — a cancel/submit during that
        // window had nothing to cancel, and a late panel completion
        // would create a new task that appended into a reset
        // session. Bridging panel.begin into a Task via continuation
        // closes that window: the outer Task is tracked from the
        // moment the panel opens, and Task.isCancelled propagates
        // to the eventual completion handler — selecting a file
        // after the parent session was cancelled is a no-op.
        let task = Task { @MainActor in
            let urls: [URL] = await withCheckedContinuation { cont in
                panel.begin { response in
                    cont.resume(returning: response == .OK ? panel.urls : [])
                }
            }
            guard !Task.isCancelled, !urls.isEmpty else { return }
            for url in urls {
                // NSOpenPanel only returns file:// URLs, but guard
                // defensively. File-type validation (image / PDF /
                // safe text formats) lives inside reference(forFileAt:)
                // — unsupported types throw and surface as errorMessage.
                guard url.isFileURL else { continue }
                guard !Task.isCancelled else { return }
                do {
                    // Synchronous decode on the main actor. The
                    // earlier detached-task pattern was added to keep
                    // the UI responsive on multi-file picks, but it
                    // forced Reference across a Sendable boundary
                    // (which NSImage doesn't satisfy). Inline is
                    // acceptable here — multi-file picks of large
                    // PDFs are rare for the dictation use case.
                    let ref = try ScreenCaptureKitReferenceCapture.reference(forFileAt: url)
                    guard !Task.isCancelled else { return }
                    self.overlay.model.references.append(ref)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.overlay.model.errorMessage =
                        "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
        trackCaptureTask(task)
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
            dismissPicker()
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
        dismissPicker()
        isPickByClickingSinglePick = true
        beginHoldPickMode()
    }

    // MARK: - #85 in-place edit

    /// E in review → open the editor seeded with the current text. Cancels the
    /// auto-accept timer so it can't paste mid-edit; snapshots the pre-edit text
    /// for the corrections journal. No-op outside the review state.
    private func enterEditMode() {
        guard phase == .awaitingAccept, !overlay.model.editing else { return }
        cancelAutoAcceptTimer()
        editPreEditText = currentText
        overlay.model.editableText = currentText
        overlay.model.editing = true
        log("in-place edit: entered")
    }

    /// ⌘Return (accept=true) or ⌘S (accept=false). Applies the edited text,
    /// records the before/after to the corrections journal, then pastes (accept)
    /// or returns to review with auto-accept re-armed (save).
    private func commitEdit(accept: Bool) {
        guard phase == .awaitingAccept, overlay.model.editing else { return }
        let edited = overlay.model.editableText
        overlay.model.editing = false
        if edited != editPreEditText {
            currentText = edited
            overlay.model.text = edited
            recordInPlaceEdit(before: editPreEditText, after: edited)
        }
        log("in-place edit: \(accept ? "commit+accept" : "save")")
        if accept {
            self.accept()
        } else {
            startAutoAcceptTimer()
        }
    }

    /// Esc in edit → drop the edits and return to review (auto-accept re-armed).
    /// A second Esc from review cancels the dictation via the normal path.
    private func discardEdit() {
        guard overlay.model.editing else { return }
        overlay.model.editing = false
        overlay.model.editableText = ""
        startAutoAcceptTimer()
        log("in-place edit: discarded")
    }

    /// Feed a confirmed in-place edit to the corrections-learning journal (opt-in;
    /// no-op when the feature is off). Modeled as a refine: instruction names the
    /// gesture, before/after carry the edit. Never written to disk by the journal.
    private func recordInPlaceEdit(before: String, after: String) {
        let enabled = Config.load().config.learnFromCorrectionsEnabled
        guard enabled, !before.isEmpty, before != after else { return }
        CorrectionJournal.shared.record(CorrectionRecord(
            kind: .refine, instruction: "in-place edit", before: before, after: after
        ), enabled: enabled)
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
        guard phase == .awaitingAccept || phase == .cleaning else { return }
        // Don't accept/paste while the help overlay is up — the user is
        // reading help, not finishing. Covers the case where the auto-
        // accept timer gets (re)armed by the cleaning→awaitingAccept
        // transition while help is open; hideHelp() re-arms it on
        // dismissal so auto-accept resumes normally afterward.
        guard !helpVisible else { return }
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
        // Accept during .cleaning (task #53 raw-first; C1 eager-accept
        // deferral). Two outcomes, decided by EagerAccept.resolve:
        //  • The full raw/prior transcript is on screen provisionally → the
        //    user is deliberately taking the raw as-is. Keep the original
        //    "kill-it" semantics: paste it and cancel the in-flight stream.
        //  • A partial cleanup is streaming, or nothing's shown yet → DON'T
        //    paste a fragment (or beep on empty) and discard the rest. Arm a
        //    pending-accept; applyResult() auto-accepts the FULL cleaned
        //    result the instant the stream completes (Jeff's hasty-Enter fix).
        //    Esc still cancels.
        if phase == .cleaning {
            let visible = overlay.model.text
            let visibleIsEmpty = visible
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            switch EagerAccept.resolve(
                provisionalRawShown: overlay.model.provisionalText,
                visibleIsEmpty: visibleIsEmpty
            ) {
            case .deferUntilComplete:
                // Idempotent: a second hasty Enter while already armed is a
                // no-op (the stream is still finishing).
                if !pendingAcceptOnCleanupComplete {
                    pendingAcceptOnCleanupComplete = true
                    overlay.model.pendingAcceptArmed = true
                    // Nothing to auto-accept yet — no review timer to run.
                    cancelAutoAcceptTimer()
                    log("accept during cleaning: deferred — will auto-accept full cleaned result on completion")
                }
                return
            case .acceptVisibleNow:
                inFlightTask?.cancel()
                inFlightTask = nil
                // Kill-it semantics extend to a chained refine still awaiting
                // its baseline: cancel the background first cleanup and
                // release the gate so the suspended refine task wakes and
                // bails. The visible text (the refine view's current content)
                // is what gets pasted. No-op outside the chained window.
                teardownChainedRefine()
                currentText = visible
                lastCleanupFailed = overlay.model.provisionalText
                // The cancelled stream never reported latency — don't let
                // the PREVIOUS dictation's value leak into this entry's
                // stats metadata.
                lastLLMLatencyMs = nil
                log("accept during cleaning: provisional raw accepted, LLM stream cancelled")
            }
        }
        phase = .pasting
        cancelAutoAcceptTimer()
        // Use the live-tracked target rather than the one captured at
        // hotkey-down. The chip in the overlay reflects the live
        // tracker (PasteTargetTracker), so whatever the user sees as
        // 'Pastes to: X' is what they expect Accept to honor. If the
        // tracker has nothing newer than the captured-at-start value,
        // fall through to the original.
        // A user-chosen send-to destination (V during review) wins over
        // the default/live-tracked target — that's the whole point of
        // "send this somewhere else."
        let target = chosenDestination ?? liveTrackedPasteTarget() ?? pasteTarget
        let textToPaste = textForPaste(currentText, target: target)
        // Record to the in-memory transcription history before the
        // paste attempt — even if the paste lands in the wrong app
        // (focus changed mid-flight) the user can grab the text
        // back from the menu bar's Recent Dictations submenu.
        // Stores the bare cleaned text without the trailing-space
        // rule applied, so re-pastes match the user's intent rather
        // than the previous target's convention.
        appendTranscriptHistory(
            text: currentText,
            target: target,
            wasCleanupSuccessful: !lastCleanupFailed
        )
        // Flywheel: capture the accepted dictation. final = the text the
        // user accepted, after any manual edits / refine / preset.
        flushContribution(disposition: .accepted, finalText: currentText)
        if overlay.model.isPickingWindow { endHoldPickMode() }
        // Cancel any in-flight reference captures before resetting
        // overlay state. Without this, a capture task that's still
        // resolving (e.g. user picked a reference from the review
        // overlay and pressed Enter before the SCK frame returned)
        // could append to overlay.model.references AFTER the reset
        // below — leaking that reference into the next dictation
        // session and omitting it from the just-accepted entry.
        cancelPendingCaptures()
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
        // B1: a transient capture-failure notice (dead mic) is shown in idle
        // phase; Esc dismisses it early. Handle before the phase switch.
        if overlay.model.transientNotice != nil {
            overlay.hide()
            return
        }
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
            dismissPicker()
        case .capturing, .refining:
            // Stop the recorder so the audio engine releases its
            // input tap. Also cancel the streaming ASR session so the
            // upload connection closes immediately instead of waiting
            // for body close.
            let cancelledCapture = try? recorder.stop()
            recorder.chunkHandler = nil
            streamingSession?.cancel()
            streamingSession = nil
            // B3: a mid-hold Esc is a fat-finger loss too. Before discarding
            // the cancelled utterance, retain its audio as the recoverable
            // buffer IF it's a real, voiced FRESH capture (not a refine — you
            // recover the dictation, not an edit; and not an accidental
            // sub-200ms tap or a dead/silent hold). Then hold+R / the menu can
            // bring it back, same as a lost reviewed dictation.
            if phase == .capturing, let cancelledCapture {
                let s = SilenceDetector.analyze(wavData: cancelledCapture.wavData)
                let health = CaptureHealth.classify(
                    durationSeconds: cancelledCapture.durationSeconds,
                    peakRMS: s.peakRMS,
                    voicedSeconds: s.voicedDurationSeconds,
                    isAnalyzable: s.isAnalyzable)
                if health == .ok {
                    retainRecoverableAudio(cancelledCapture)
                    log("cancel during capture: retained \(cancelledCapture.wavData.count / 1024) KB for recovery")
                }
            }
        case .cleaning, .awaitingAccept:
            break
        }
        // Flywheel: a discarded dictation still yields re-runnable audio +
        // ASR data. Flush as discarded (final = nil) before teardown; the
        // guard inside no-ops if there's no ASR-bearing accumulator (e.g. a
        // mid-capture Esc before ASR ran).
        flushContribution(disposition: .discarded, finalText: nil)
        inFlightTask?.cancel()
        inFlightTask = nil
        // Tear down a chained-refine-during-cleanup window if one is
        // active: cancel the still-running first cleanup, release any
        // awaiter on the baseline gate (so the refine task — if it was
        // suspended on the gate — wakes, sees Task.isCancelled, and
        // bails cleanly), and clear the chain state. No awaiting task
        // leaks. Done unconditionally; all three are nil/false outside
        // the chained window.
        teardownChainedRefine()
        cancelAutoAcceptTimer()
        // A2 follow-up (RoboRev): drop any queued config-change rebuild so a
        // debounce task armed just before this cancel can't fire afterward.
        // (The handler's `guard isRunning` already makes it a no-op, but this
        // avoids the dangling MainActor dispatch.)
        audioConfigRebuildTask?.cancel()
        audioConfigRebuildTask = nil
        cancelPendingOverlayShow()
        cancelPendingRefine()
        cancelStagingPickTimer()
        cancelPendingCaptures()
        // Dismiss the window picker if it's open. Latched-compose
        // flows can leave the picker showing across .pickerOpen /
        // .latched / .latchedRecording; the .staging branch above
        // handled the upfront-picker case but cancellation mid-
        // latched-compose would otherwise leave the picker as an
        // orphaned floating panel.
        if windowPickerWindow.isVisible { dismissPicker() }
        if overlay.model.isPickingWindow { endHoldPickMode() }
        resetPerDictationOverlayState()
        Task { @MainActor in
            await closeAndReset()
        }
    }

    // MARK: - Phase transitions

    /// Show the "?" help overlay. Triggered by "?" / "/" while the
    /// dictation overlay has key focus. If a dictation is actively
    /// capturing/refining, pause the recorder (audio is preserved) so
    /// the time spent reading help isn't recorded into the utterance;
    /// hideHelp() resumes it. No-op for the brief transient phases.
    @MainActor
    public func showHelp() {
        guard !helpVisible else { return }
        switch phase {
        case .capturing, .refining, .cleaning, .awaitingAccept, .staging:
            break
        case .idle, .pasting:
            return
        }
        helpVisible = true
        holdEndedDuringHelp = false
        helpReleaseSpaceWasPressed = false
        // Suspend the auto-accept timer so an enabled auto-accept can't
        // fire accept() and tear down the session while the user reads
        // help. Re-armed in hideHelp() if we return to review.
        cancelAutoAcceptTimer()
        // Likewise cancel a pending refine timer: if "?" is pressed within
        // the 0.18s hold window in review, the refine timer could
        // otherwise fire and start capturing the time spent reading help.
        // We don't restart it on dismiss — the user can re-press to refine.
        cancelPendingRefine()
        // Only pause if the recorder is ACTUALLY capturing — another flow
        // (latched-compose) may already have it paused; pausing again
        // here would make hideHelp's resume un-pause it incorrectly.
        if (phase == .capturing || phase == .refining), recorder.isCapturing {
            recorder.pause()
            helpPausedRecorder = true
        }
        helpOverlay.show(
            hotkeyName: overlay.model.hotkeyDisplayName,
            referenceWindowsEnabled: overlay.model.referenceWindowsEnabled,
            transformPresetsEnabled: Config.load().config.transformPresetsEnabled
        )
    }

    /// Dismiss the help overlay (Esc / "?" / click-away) and resume the
    /// paused dictation if showHelp() paused it.
    @MainActor
    public func hideHelp() {
        guard helpVisible else { return }
        helpVisible = false
        helpOverlay.hide()

        // If the hotkey was RELEASED while help was up, replay that
        // release through the normal hotkeyUp path (helpVisible is now
        // false, so it won't re-guard) so the proper bookkeeping runs —
        // awaiting in-flight reference attaches, advancing composeState,
        // and finalize/latched routing. Done first and unconditionally
        // (even if we never paused the recorder) so a terminating release
        // can never be silently dropped.
        if holdEndedDuringHelp {
            holdEndedDuringHelp = false
            helpPausedRecorder = false
            let spaceWasPressed = helpReleaseSpaceWasPressed
            helpReleaseSpaceWasPressed = false
            hotkeyUp(spaceWasPressedDuringHold: spaceWasPressed)
            return
        }
        helpReleaseSpaceWasPressed = false

        if helpPausedRecorder {
            // Still holding — continue capturing where we left off; the
            // eventual release submits as usual.
            helpPausedRecorder = false
            recorder.resume()
        } else if phase == .awaitingAccept {
            // Help was opened from review; re-arm the auto-accept timer
            // that showHelp() cancelled.
            startAutoAcceptTimer()
        }
    }

    /// Dismiss help via a HOTKEY PRESS — "press the hotkey to resume."
    /// Unlike hideHelp(), this discards any release that happened while
    /// help was up (so it does NOT finalize/submit) and resumes the
    /// paused capture, because the press signals intent to keep dictating.
    @MainActor
    private func dismissHelpForResume() {
        guard helpVisible else { return }
        helpVisible = false
        helpOverlay.hide()
        holdEndedDuringHelp = false
        helpReleaseSpaceWasPressed = false
        if helpPausedRecorder {
            helpPausedRecorder = false
            recorder.resume()
        } else if phase == .awaitingAccept {
            startAutoAcceptTimer()
        }
    }

    /// Called from HotkeyListener.onSpacePressed the first time Space
    /// is pressed within a single hotkey hold. Surfaces visual
    /// feedback in the overlay (the hint strip swaps to an "armed"
    /// variant) so the user sees that Space landed BEFORE they
    /// release the hotkey. Gated on the same referenceWindowsEnabled
    /// flag that gates the actual Space-to-picker behavior — promising
    /// "picker on release" while the flag is off would be misleading.
    /// Idempotent: the listener already edge-triggers, but the guard
    /// here doubles as defense against future caller changes.
    @MainActor
    public func spacePressedDuringHold() {
        // Honored during .capturing AND .refining — both phases
        // represent an active dictation hold where attaching a
        // reference window makes sense (the refine flow is just
        // another dictation segment from the user's perspective).
        // Space outside a hold isn't consumed by the listener
        // (case (a) gates on keyDown), so this code path shouldn't
        // fire from other phases, but guard anyway so a future
        // listener change can't surprise us.
        guard phase == .capturing || phase == .refining else { return }
        guard overlay.model.referenceWindowsEnabled else { return }
        overlay.model.spaceArmedDuringHold = true
        log("space pressed during hold — overlay armed (phase=\(phase))")
    }

    /// Called from HotkeyListener.onPPressed when the user taps P
    /// while the dictation hotkey is held. 0.14.0 "Show Parleq"
    /// gesture (#221 — replacing the deferred global hotkey
    /// question with a chord that builds on the existing hold
    /// pattern). Cancels the in-flight dictation and summons the
    /// app window, so the user can think of the gesture as
    /// "instead of dictating, show me the app." Quick Option-P
    /// taps without a hotkey hold still produce π — the listener
    /// only consumes P during a held hotkey, so this code path
    /// can't fire from a casual π-typing gesture.
    @MainActor
    public func pPressedDuringHold() {
        cancelAndShowParleqWindow(reason: "p pressed during hold")
    }

    /// Bare P during review (overlay has key focus): the resting-state
    /// twin of the hold+P gesture. We originally kept P out of review
    /// because it cancels the in-flight result — but P already works
    /// during a refine-hold, so withholding it at rest was an arbitrary
    /// gap. Cancels the reviewed dictation and summons the app window.
    @MainActor
    public func pPressedDuringReview() {
        guard phase == .awaitingAccept else { return }
        cancelAndShowParleqWindow(reason: "p pressed during review")
    }

    /// Shared body for the hold+P and review+P gestures: cancel whatever
    /// dictation is in flight and bring up the main Parleq window.
    /// cancel() handles every phase's teardown.
    @MainActor
    private func cancelAndShowParleqWindow(reason: String) {
        log("\(reason) — cancelling capture, opening app window")
        // Route through cancel() so the recorder is stopped, the
        // streaming session aborted, and the overlay closed —
        // same teardown as Esc-during-dictation. Whatever phase
        // we're in (.capturing, .staging, .latched, etc.) the
        // cancel() switch handles it.
        cancel()
        ParleqAppWindowController.shared.show()
    }

    /// B3: re-run ASR + cleanup on the retained audio of the most recent fresh
    /// dictation and drop the result into the review overlay. Reached two ways:
    ///   • hold-hotkey + R — fires mid-hold; aborts the in-flight capture (we're
    ///     recovering the PREVIOUS dictation, not this one) and re-runs.
    ///   • the menu-bar "Recover last dictation" item — fires from .idle.
    /// No-ops with a beep when nothing is retained (fresh launch, or the last
    /// capture was dead-input and never retained — that case pairs with B1).
    /// Memory-only: the buffer is the same retained bytes, never re-read from
    /// disk.
    @MainActor
    public func recoverLastDictation() {
        guard RecoveryEligibility.canRecover(hasRetainedAudio: lastDictationAudio != nil),
              let retained = lastDictationAudio else {
            log("recover-last-dictation: nothing retained to recover")
            NSSound.beep()
            return
        }
        log("recover-last-dictation: re-running ASR + cleanup on retained \(retained.wav.count / 1024) KB")
        // hold+R fires during an active capture — tear it down and discard its
        // audio (we're replacing it with the recovered dictation). All of these
        // are no-ops on the menu-bar path, which fires from .idle.
        if recorder.isCapturing { _ = try? recorder.stop() }
        recorder.chunkHandler = nil
        streamingSession?.cancel()
        streamingSession = nil
        inFlightTask?.cancel()
        inFlightTask = nil
        teardownChainedRefine()
        cancelAutoAcceptTimer()
        // A2 follow-up (RoboRev): cancel any pending rebuild from the aborted
        // capture so it can't fire during the recovery re-run.
        audioConfigRebuildTask?.cancel()
        audioConfigRebuildTask = nil
        cancelPendingOverlayShow()
        cancelPendingRefine()
        if windowPickerWindow.isVisible { dismissPicker() }
        if overlay.model.isPickingWindow { endHoldPickMode() }
        // Start a fresh session for the recovered dictation, pointed at the
        // current frontmost app (recover can be invoked from idle via the menu,
        // or mid-hold via hold+R; in both cases the user's target is whatever's
        // frontmost now). Clear any stale per-dictation overlay state first.
        resetPerDictationOverlayState()
        pasteTarget = Paster.captureFrontmost()
        resetFreshDictationState()
        // Keep the speaking-time stat honest — the retained buffer's measured
        // duration, not 0 (resetFreshDictationState cleared it).
        lastAudioDurationMs = retained.durationMs
        runCleanupPipeline(wavData: retained.wav, asRefine: false)
    }

    /// hold-hotkey + R entry point (HotkeyListener.onRPressed). Thin wrapper so
    /// the gesture wiring reads symmetrically with pPressedDuringHold.
    @MainActor
    public func rPressedDuringHold() {
        recoverLastDictation()
    }

    /// B3: stash a fresh capture's audio as the recoverable buffer. Memory-only
    /// (compliance invariant #1); fires onRecoverableDictationChanged the first
    /// time a buffer becomes available so the menu item enables. Called from
    /// both the normal finalize path AND a mid-hold cancel (Esc) — a cancelled
    /// dictation is a fat-finger loss too, and recovery is exactly for that.
    private func retainRecoverableAudio(_ capture: AudioRecorder.Capture) {
        let wasUnavailable = (lastDictationAudio == nil)
        lastDictationAudio = (capture.wavData, max(0, Int(capture.durationSeconds * 1000)))
        if wasUnavailable { onRecoverableDictationChanged?(true) }
    }

    /// Called from HotkeyListener.onCPressed when the user taps C while
    /// the dictation hotkey is held. Attaches the *current* frontmost
    /// window of the app that was frontmost at hotkey-down (the app's
    /// pid is recorded in `pasteTarget`; the specific window is resolved
    /// live, so if that app raised a different window during the hold it
    /// attaches the new one) as a reference — the no-picker shortcut for
    /// "use what I'm looking at as context." Mirrors the picker's capture
    /// path (permission handling, error banners, focus restoration) by
    /// routing through `capture(_:)`.
    @MainActor
    public func cPressedDuringHold() {
        guard phase == .capturing || phase == .refining else { return }
        attachOriginWindowAsReference(reason: "c pressed during hold")
    }

    /// Bare C in the overlay — attach the dictation-origin window as
    /// context. Fires in two states (the bare key only reaches here when
    /// the dictation hotkey is NOT held; during a normal hold the event
    /// tap consumes C → cPressedDuringHold):
    ///   - review (.awaitingAccept): stage context for the next refine.
    ///   - latched-compose recording (.capturing / .refining, e.g. "say
    ///     what to do with these references"): attach mid-compose.
    /// Both just attach the origin window via attachOriginWindowAsReference,
    /// a background capture with no recorder pause — matching hold+C. In
    /// review, the auto-accept timer defers while the capture is in flight
    /// (see startAutoAcceptTimer); a no-op attach registers no task so
    /// auto-accept proceeds normally.
    @MainActor
    public func attachCurrentWindowFromReview() {
        guard phase == .awaitingAccept || phase == .capturing || phase == .refining else { return }
        attachOriginWindowAsReference(reason: "c pressed (overlay)")
    }

    /// Bare Space in the overlay — open the window picker to attach a
    /// reference. Like attachCurrentWindowFromReview, fires in review
    /// (.awaitingAccept) AND in the latched-compose recording states
    /// (.capturing / .refining) — mirroring the overlay "+" button, which
    /// is the other way to attach in those states. In the recording
    /// states the recorder is live, so pause it first (as the + button
    /// and the during-hold Space path do) so picker interaction isn't
    /// recorded. The auto-accept timer defers while the picker is open
    /// (see startAutoAcceptTimer), so no explicit suspend/re-arm is
    /// needed — abandoning the picker lets auto-accept resume on its next
    /// tick.
    @MainActor
    public func attachWindowFromReview() {
        guard overlay.model.referenceWindowsEnabled else { return }
        guard phase == .awaitingAccept || phase == .capturing || phase == .refining else { return }
        if recorder.isCapturing { recorder.pause() }
        presentPicker()
    }

    /// Attach the current frontmost window of the dictation-origin app
    /// (the app whose pid was recorded in `pasteTarget` at hotkey-down;
    /// the window itself is resolved live via `Paster.frontmostWindow`)
    /// as a reference. Shared by the during-hold C gesture and the
    /// review C gesture. Routes through `capture(_:)` so it inherits
    /// permission handling, error banners, and focus restoration.
    /// No-ops (with a log) when reference windows are off or no origin
    /// window can be resolved.
    @MainActor
    private func attachOriginWindowAsReference(reason: String) {
        guard overlay.model.referenceWindowsEnabled else { return }
        guard let target = pasteTarget else {
            log("\(reason) — no front app captured at hotkey-down; ignoring")
            return
        }
        guard let win = Paster.frontmostWindow(forPID: target.pid) else {
            log("\(reason) — no front window resolved for \(target.name); ignoring")
            return
        }
        let displayTitle = win.title.isEmpty ? target.name : win.title
        let entry = WindowPickerModel.Entry(
            windowID: win.windowID,
            pid: target.pid,
            bundleID: target.bundleID ?? "",
            appName: target.name,
            title: displayTitle,
            appIcon: NSRunningApplication(processIdentifier: target.pid)?.icon
        )
        // Log the app name only, never the window title — titles can
        // carry sensitive content (document names, email subjects) that
        // should not land in the on-disk app.log. The title still shows
        // in the in-RAM overlay chip.
        log("\(reason) — attaching current window from \(target.name) as reference")
        let task = Task { @MainActor in await self.capture(entry) }
        _ = trackCaptureTask(task)
    }

    /// Bare V during review (overlay has key focus): choose a window to
    /// send the reviewed output to, then send immediately on pick. The
    /// focus-independent hold+V variant is deferred — during review a
    /// hotkey hold schedules a refine (0.18 s) before the secondary-key
    /// hold threshold (0.2 s) would fire, so the two gestures collide.
    @MainActor
    public func sendToPressed() {
        guard phase == .awaitingAccept else { return }
        // Honor the master reference-windows privacy/MDM gate, like every
        // other path that opens the window picker (staging, +-menu,
        // attachWindowFromReview, attachOriginWindowAsReference). The
        // picker enumerates on-screen window titles and offers "pick by
        // clicking" — exactly the surface this lock suppresses — and the
        // picker's own code assumes it never opens when the flag is off
        // (WindowPicker shows the window list unconditionally on that
        // premise). So send-to is unavailable when reference windows are
        // disabled. (A future dedicated managed key could decouple
        // paste-targeting from content capture if wanted.)
        guard overlay.model.referenceWindowsEnabled else {
            log("send-to: reference windows disabled — ignoring V")
            return
        }
        // Stop the auto-accept timer while the user chooses a
        // destination. Otherwise it could fire accept() with
        // chosenDestination == nil mid-pick, paste to the original
        // target, and move phase to .pasting — after which the
        // destination pick's accept() guard fails and the send-to is
        // silently dropped, landing the text in the wrong window.
        cancelAutoAcceptTimer()
        pickerMode = .destination
        windowPickerWindow.show()
    }

    /// If the picker is open in destination (send-to) mode, abort the
    /// send-to: hide the picker, restore source mode, and re-arm the
    /// auto-accept timer that sendToPressed() cancelled. Returns true if
    /// it aborted (caller should not proceed with a source action).
    /// Used by the source-only picker actions so taking one of them in
    /// destination mode can't leave a stuck timer or misroute a pick.
    @MainActor
    private func abortSendToIfDestination() -> Bool {
        guard pickerMode == .destination else { return false }
        pickerMode = .source
        windowPickerWindow.hide()
        if phase == .awaitingAccept { startAutoAcceptTimer() }
        return true
    }

    /// Resolve a picked window into a paste target and send the reviewed
    /// output there immediately — picking the destination is the commit
    /// (the text was already reviewed). The picker Entry already carries
    /// the owning app's pid/bundleID/name, so no extra lookup is needed.
    @MainActor
    private func setDestination(from entry: WindowPickerModel.Entry) {
        // Apply the same conflict gate as accept() BEFORE committing the
        // destination. Otherwise accept() would early-return on its beep
        // path, leaving chosenDestination stuck set — and a later plain
        // Enter would then silently route to this V-picked window instead
        // of the original target. Beep and bail without mutating state.
        if hasUnresolvedConflict() {
            NSSound.beep()
            // Re-arm auto-accept: sendToPressed() cancelled it when the
            // picker opened, and this bail leaves us back in review.
            startAutoAcceptTimer()
            return
        }
        // Intentionally APP-LEVEL: we keep pid/bundleID and drop
        // entry.windowID. Paster activates the app and Cmd-Vs into its
        // focused field, so for a multi-window target the paste lands in
        // that app's frontmost window, not necessarily the exact one
        // picked. This is the documented field-precise-targeting
        // limitation (see the cross-window plan); window-precise routing
        // is deferred to the broader targeting work.
        chosenDestination = PasteTarget(
            pid: entry.pid,
            name: entry.appName,
            bundleID: entry.bundleID.isEmpty ? nil : entry.bundleID
        )
        log("send-to: destination set to \(entry.appName) — sending")
        accept()
    }

    /// Reset the per-dictation scalar state shared by a fresh capture and a B3
    /// recovery re-run. Does NOT touch the recorder, the latched-compose state
    /// machine, or `pasteTarget` — the caller establishes the recorder/target
    /// for its own context (startFreshCapture opens the mic; recovery feeds a
    /// retained buffer).
    private func resetFreshDictationState() {
        chosenDestination = nil
        currentText = ""
        lastRawTranscript = ""
        lastTurnWasRefine = false
        lastRefinePriorText = ""
        appliedPreset = nil
        intendedDefaultPreset = nil
        styledRawTranscript = ""
        styledReferences = []
        styledPasteDestLabel = nil
        overlay.model.appliedPresetName = nil
        overlay.model.activeTransformName = nil
        lastCleanupFailed = false
        // 0.14.0 PR 4 (#219): clear last-pass timings so a previous
        // dictation's measurements don't leak into this entry if
        // the cleanup pass fails before populating them. The audio
        // duration is populated in finalizeCapture from the
        // recorder's reported duration; ASR + LLM latencies are
        // populated by the cleanup pipeline as they're measured.
        lastAudioDurationMs = 0
        lastASRLatencyMs = nil
        lastLLMLatencyMs = nil
        // Mint a fresh session id for this dictation. Every fresh
        // capture starts a new history entry; refine turns reuse
        // the same id (they never call startFreshCapture). The id
        // is cleared by resetPerDictationOverlayState() when the
        // session ends (accept / cancel / dismiss).
        currentSessionEntryID = UUID()
    }

    private func startFreshCapture() {
        pasteTarget = Paster.captureFrontmost()
        resetFreshDictationState()
        guard openRecorder() else { return }
        // Advance the latched-compose state machine so a subsequent
        // hotkeyUp(spaceWasPressedDuringHold: true) can transition
        // .recording → .pickerOpen. Without this the .hotkeyUp event
        // hits the default fallthrough on .idle and the picker
        // never opens. Quick mode also fires hotkeyDown for symmetry,
        // even though quick-mode users never press Space (they
        // double-tap-hold and release immediately) — keeping the
        // event consistent avoids future bugs if quick mode ever
        // grows space-attach support.
        composeState = nextComposeState(composeState, event: .hotkeyDown)
        // Sync the overlay model's referenceWindowsEnabled flag so the
        // hint strip's .recording-state teaching copy ("Press Space to
        // attach a window") suppresses when the feature is off. The
        // .recording hint shows BEFORE hotkeyUp, so we need the model
        // updated at hotkeyDown time, not later.
        let freshConfig = Config.load().config
        overlay.model.referenceWindowsEnabled = freshConfig.referenceWindowsEnabled
        // Refresh the overlay-show delay from config so a Settings
        // change applies on the next dictation without a restart (#56).
        overlayShowDelaySeconds = TimeInterval(freshConfig.overlayShowDelayMs) / 1000.0
        // Refresh the recording-pulse toggle from config too, so a
        // Settings change applies on the next quick dictation.
        recordingPulseEnabled = freshConfig.recordingPulse
        // Clear the per-hold Space-armed flag at every fresh down so
        // a stale "armed" state from a previous hold can't leak
        // visually into this one.
        overlay.model.spaceArmedDuringHold = false
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
            withTimeInterval: overlayShowDelaySeconds, repeats: false
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

    /// Show the recording pulse only while a quick-mode capture is in
    /// flight (and the feature is enabled); hide it otherwise. Called
    /// from the `phase` and `quickMode` didSets, so it reconciles on
    /// every relevant transition. show()/hide() are idempotent.
    private func updateRecordingPulse() {
        if phase == .capturing, quickMode, recordingPulseEnabled {
            recordingPulse.show()
        } else {
            recordingPulse.hide()
        }
    }

    private func startRefineCapture() {
        // Cancel any in-flight LLM stream from the prior turn before
        // we overwrite currentText with a refined version.
        inFlightTask?.cancel()
        inFlightTask = nil
        // Defense-in-depth: this path is the .awaitingAccept refine,
        // mutually exclusive with the chained-during-cleaning flow. Clear
        // any chain state so a prior chained turn can't leak its gate.
        teardownChainedRefine()
        cancelAutoAcceptTimer()
        guard openRecorder() else { return }
        phase = .refining
        // Advance the latched-compose state machine so the user's
        // current refine hold can also support press-Space-during-
        // hold → picker. Without this transition composeState stays
        // .idle and `OverlayHintStrip` renders nothing, AND the
        // press-Space gates in hotkeyUp + spacePressedDuringHold
        // reject the gesture during a refine. Treating .refining
        // symmetrically with .capturing matches the user mental
        // model "press Space anytime to attach a window" — the
        // refine itself is just another dictation segment.
        composeState = nextComposeState(composeState, event: .hotkeyDown)
        overlay.show(
            state: .refining,
            text: currentText,
            microphoneName: activeMicrophoneName()
        )
    }

    /// Enter refine capture while the FIRST cleanup is still streaming
    /// (hotkey pressed during .cleaning). Unlike startRefineCapture this
    /// does NOT cancel the in-flight cleanup: we hand its task off to
    /// `chainedCleanupTask` (so the refine's later inFlightTask
    /// reassignment can't lose the handle), create a BaselineGate the
    /// cleanup will resolve with its final text, and set
    /// `refineChainedDuringCleanup` so applyResult suppresses the
    /// cleanup's terminal transition — the refine owns the next one.
    /// The refine execution (finalizeCapture's asRefine task) awaits the
    /// gate before reading the baseline.
    private func startChainedRefineCapture() {
        // Quick mode can't reach here — the overlay (required for the
        // hotkey-press-during-cleaning window) is suppressed in quick
        // mode, which pastes directly with no review. Guard defensively:
        // if somehow chained while quick, fall back to the cancel-and-
        // refine behavior so we never strand a background cleanup with
        // no consumer.
        guard !quickMode else {
            startRefineCapture()
            return
        }
        guard openRecorder() else { return }
        // Hand the in-flight cleanup off to the dedicated handle BEFORE
        // the refine reassigns inFlightTask below. Do NOT cancel it.
        chainedCleanupTask = inFlightTask
        let gate = BaselineGate()
        chainedBaselineGate = gate
        refineChainedDuringCleanup = true
        // Clear inFlightTask so the refine's finalize path starts a
        // fresh refine task without touching the cleanup we just moved.
        inFlightTask = nil
        cancelAutoAcceptTimer()
        // C1 follow-up (RoboRev): pressing the hotkey to chain a refine is a
        // fresh intent — drop any deferred eager-accept armed by an earlier
        // Enter during this same .cleaning. Otherwise the refine's terminal
        // applyResult would fire the pending accept and auto-paste the refine
        // result WITHOUT a review step.
        pendingAcceptOnCleanupComplete = false
        overlay.model.pendingAcceptArmed = false
        phase = .refining
        // Symmetric with startRefineCapture: advance the latched-compose
        // state machine so press-Space-during-hold works in this refine
        // hold too.
        composeState = nextComposeState(composeState, event: .hotkeyDown)
        // Show the refine view with the best-available current text. The
        // first cleanup may still be streaming into `assembled`, but once
        // we leave .cleaning its chunk handler stops writing to the
        // overlay (gated in streamCleanupOrRefine), so it can't clobber
        // this refine view. currentText may be empty here (cleanup hasn't
        // resolved) — that's fine; the overlay reflects the live stream's
        // last frame already, and the FINAL baseline arrives via the gate.
        overlay.show(
            state: .refining,
            text: overlay.model.text,
            microphoneName: activeMicrophoneName()
        )
        log("hotkeyDown during cleaning → chained refine capture; first cleanup left running")
    }

    /// Whether a streaming cleanup/refine pass may write its chunks to
    /// the overlay right now. Phase fact this relies on: finalizeCapture
    /// sets `phase = .cleaning` for BOTH a fresh cleanup AND a voice
    /// refine before spawning the stream — `.refining` covers only the
    /// audio hold, not the LLM pass. So a NORMAL cleanup or refine (no
    /// chain) streams under .cleaning and renders normally. The one case
    /// suppressed is the first cleanup AFTER the user chained a refine
    /// onto it (`refineChainedDuringCleanup` true): it keeps assembling
    /// its text in the background but must not paint over the .refining
    /// capture / the chained refine's own stream. The chained refine
    /// clears the flag before IT streams (also under .cleaning), so its
    /// own chunks render.
    private func shouldStreamRenderToOverlay() -> Bool {
        return chainedRefineShouldRender(
            phase: phase,
            refineChainedDuringCleanup: refineChainedDuringCleanup
        )
    }

    /// Tear down the chained-refine-during-cleanup coordination. Cancels
    /// the background first-cleanup task, releases the baseline gate (so
    /// a refine task suspended on it wakes and bails on Task.isCancelled
    /// rather than hanging), and clears the chain state. Safe to call
    /// unconditionally — a no-op when no chain is active.
    private func teardownChainedRefine() {
        chainedCleanupTask?.cancel()
        chainedCleanupTask = nil
        chainedBaselineGate?.cancel()
        chainedBaselineGate = nil
        refineChainedDuringCleanup = false
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
                // Feed the same level to the quick-mode pulse; it's a
                // no-op while the pulse is hidden.
                self?.recordingPulse.setLevel(value)
            }
        }
        // B2: feed the raw mic peak to the dead-mic watchdog. Reset the monitor
        // + warning for this fresh hold so a prior capture's flat-zero tail
        // doesn't carry over.
        micSignalMonitor.reset()
        overlay.model.notHearingMic = false
        recorder.micSignalHandler = { [weak self] peak, dt in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let warn = self.micSignalMonitor.update(peak: peak, dt: dt)
                if self.overlay.model.notHearingMic != warn {
                    self.overlay.model.notHearingMic = warn
                }
            }
        }
        // A2: rebuild the tap + converter if the engine reconfigures mid-flight
        // (another app flips the default input to multichannel, the route
        // changes). Drop any rebuild queued against a prior capture first.
        audioConfigRebuildTask?.cancel()
        audioConfigRebuildTask = nil
        recorder.onConfigurationChange = { [weak self] in
            Task { @MainActor in self?.handleAudioConfigurationChange() }
        }
        do {
            try recorder.start()
        } catch {
            log("recorder start failed: \(error)")
            recorder.levelHandler = nil
            recorder.micSignalHandler = nil
            // A2 follow-up (RoboRev): clear the config-change callback + any
            // queued rebuild too, so a route change while idle after a failed
            // start doesn't fire a spurious handler. Symmetric with the other
            // handler clears above.
            recorder.onConfigurationChange = nil
            audioConfigRebuildTask?.cancel()
            audioConfigRebuildTask = nil
            return false
        }
        // OIDC pre-warm: refresh-if-needed overlaps recording + ASR so
        // the boundary-hour exchange never delays cleanup. Fire-and-
        // forget; failures surface fail-closed when cleanup runs.
        if let aws = oidcAWSExchange { Task { await aws.warm() } }
        if let gcp = oidcGCPExchange { Task { await gcp.warm() } }
        // googleOAuth Vertex mode has no exchange cache — pre-warm the
        // session's access token directly so a boundary-hour silent refresh
        // overlaps recording + ASR. Fire-and-forget; errors surface
        // fail-closed when cleanup runs.
        if oidcPrewarmSessionAccessToken, let session = oidcSession {
            Task { _ = try? await session.accessToken() }
        }
        return true
    }

    /// A2: debounced handler for AVAudioEngine config changes. A single
    /// device/format change posts a burst of notifications; coalesce them into
    /// one rebuild ~250 ms after the last. The rebuild itself (engine stop +
    /// tap/converter rebuild on a fresh format) runs on the MainActor inside
    /// AudioRecorder, so it never races a capture start/stop. No-op when the
    /// recorder isn't actively capturing (the next start() re-queries anyway).
    @MainActor
    private func handleAudioConfigurationChange() {
        audioConfigRebuildTask?.cancel()
        audioConfigRebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.log("audio configuration changed mid-capture — rebuilding tap + converter")
            self.recorder.handleConfigurationChange()
        }
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
        // A3: classify the capture so a DEAD mic (full-length but ~zero samples
        // — a capture failure) is distinguished from genuine quiet/silence. Both
        // skip the pipeline today; B1 will surface .deadInput to the user instead
        // of hiding silently. `peakRMS≈0` is the maintainer's "as if I never
        // dictated" signature.
        let silence = SilenceDetector.analyze(wavData: capture.wavData)
        let health = CaptureHealth.classify(
            durationSeconds: capture.durationSeconds,
            peakRMS: silence.peakRMS,
            voicedSeconds: silence.voicedDurationSeconds,
            isAnalyzable: silence.isAnalyzable)
        if health == .deadInput || health == .quietSilence {
            if health == .deadInput {
                log("captured audio peak=\(String(format: "%.4f", silence.peakRMS)) voiced=\(String(format: "%.3f", silence.voicedDurationSeconds))s — DEAD INPUT (mic delivered no audio); skipping pipeline")
            } else {
                log("captured audio voiced=\(String(format: "%.3f", silence.voicedDurationSeconds))s peak=\(String(format: "%.4f", silence.peakRMS)); skipping pipeline (silence)")
            }
            cancelPendingOverlayShow()
            session?.cancel()
            // On a silent/dead REFINE attempt, keep the prior text on screen so
            // the user can still accept the unmodified version; on an INITIAL
            // capture there's no prior text.
            if asRefine, !currentText.isEmpty {
                applyResult(currentText)
            } else {
                resetPerDictationOverlayState()
                phase = .idle
                if health == .deadInput {
                    // B1: a dead mic delivered no audio — tell the user instead of
                    // vanishing, so they know it failed and can re-dictate.
                    overlay.showTransientNotice("Didn't catch any audio — check your microphone.")
                } else {
                    overlay.hide()
                }
            }
            return
        }

        // 0.14.0 PR 4 (#219): ACCUMULATE the actual audio length
        // across refinement turns. A single accepted dictation
        // session can include the original capture plus N
        // refinement captures; the stat we want for the user
        // ("how much time did you speak today?") is the sum across
        // all of them, not just the last one. Placed AFTER both
        // the short-utterance + silence guards so accidental taps
        // / silent refinement holds aren't counted as speaking
        // time. Reset to 0 happens only in startFreshCapture,
        // marking the boundary of a new dictation session.
        lastAudioDurationMs += max(0, Int(capture.durationSeconds * 1000))

        // B3 (recover last dictation): retain this fresh capture's audio so
        // hold+R / the menu-bar item can re-run it if the user loses the
        // result (Esc, a hasty double-Enter, a focus change). Memory-only —
        // overwritten by the next fresh dictation and wiped on quit; never
        // written to disk (compliance invariant #1). Refine turns don't
        // overwrite the recoverable buffer: you recover the dictation, not an
        // in-place edit of it.
        if !asRefine {
            retainRecoverableAudio(capture)
        }

        runCleanupPipeline(wavData: capture.wavData, asRefine: asRefine)
    }

    /// Run batch ASR + LLM cleanup/refine on `wavData` and route the result to
    /// the review overlay (or the quick-mode direct paste). Extracted from
    /// finalizeCapture so B3 recovery (recoverLastDictation) can push a
    /// retained buffer through the identical pipeline.
    private func runCleanupPipeline(wavData: Data, asRefine: Bool) {
        phase = .cleaning
        // A new fresh dictation supersedes any uncommitted flywheel
        // accumulator (e.g. a prior empty-ASR capture that never reached a
        // terminal). Refine turns keep the existing one to append to.
        if !asRefine { pendingContribution = nil }
        if quickMode {
            // In quick mode we don't show the overlay — the user
            // is going to get the paste directly. Acoustic cues
            // (Tink/Pop) and the brief LLM-cleanup wait are the
            // only feedback.
            log("quick-mode cleaning (no overlay)")
        } else {
            // For cleanup we start with an empty overlay (the raw
            // transcript shows provisionally once ASR returns). For
            // refinement the prior text is ALREADY the provisional
            // content — show it dimmed from the first frame, so the
            // dim level carries straight through from .refining with
            // no opaque flash between release and the LLM stream
            // (maintainer finding).
            if asRefine {
                overlay.showProvisionalCleaning(text: currentText, isRefine: true)
            } else {
                overlay.show(state: .cleaning, text: "")
            }
        }

        let overlay = self.overlay
        // `var` because a chained refine (issued during .cleaning)
        // re-reads the baseline AFTER awaiting the first cleanup below —
        // at finalize time `currentText` is still empty/stale, so the
        // captured value here is only the seed.
        var priorText = currentText
        let asrClient = self.asr
        let wavBytes = wavData
        inFlightTask = Task { @MainActor [weak self] in
            do {
                // Batch ASR via /inference (Parakeet TDT v3) — uploads
                // the whole WAV after the user releases the hotkey.
                // No live partials in the overlay during speech, but
                // no end-of-utterance truncation either. Typical
                // post-release latency on representative human-voice
                // recordings was ~64 ms p50 for 5 s clips.
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
                // 0.14.0 PR 4 (#219): record ASR latency on the
                // AppState instance so the eventual TranscriptEntry
                // built in accept() can include it for the Stats
                // section.
                self?.lastASRLatencyMs = Int(asrLatency * 1000)
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

                // Chained-refine baseline await. When this refine was
                // captured WHILE the first cleanup was still streaming,
                // its final text is the baseline we refine against. Wait
                // for it here — after ASR, before we read priorText for
                // either the empty-transcript fallback or the refine
                // pass. Common case (cleanup already finished): the gate
                // is already resolved, so this returns immediately and
                // adds ZERO latency. The await ONLY suspends when the
                // user released the refine hotkey before the first
                // cleanup completed. Cleared after consumption so a later
                // turn doesn't re-await a stale gate.
                if asRefine, let gate = self?.chainedBaselineGate {
                    let baseline = await gate.value
                    if Task.isCancelled { return }
                    priorText = baseline
                    self?.chainedBaselineGate = nil
                    self?.chainedCleanupTask = nil
                    self?.refineChainedDuringCleanup = false
                }

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
                // Task #41: remember the SHAPE of this turn so a model
                // switch can re-run the same thing with the new model.
                self?.lastTurnWasRefine = asRefine
                self?.lastRefinePriorText = asRefine ? priorText : ""
                // Flywheel: on a fresh, ARMED capture, open a contribution
                // accumulator for this dictation carrying the exact utterance
                // audio + ASR diagnostics. Refine turns append later; it is
                // flushed at the terminal state. Disarmed (the default) → no
                // accumulator, zero overhead.
                // `!Task.isCancelled`: don't open an accumulator for a
                // dictation that was cancelled during the ASR await (the
                // existing guard above already returns in that case, but
                // keeping the check local to the mutation makes the intent
                // robust against future edits adding a suspension point).
                if !asRefine, loadedConfig.contributionCaptureArmed, !Task.isCancelled {
                    var pending = PendingContribution(
                        id: UUID(),
                        asrModel: BundledASREngine.model,
                        fluidaudioVersion: BundledASREngine.fluidAudioVersion,
                        llm: "\(loadedConfig.llmProvider):\(loadedConfig.llmModel)",
                        wav: wavBytes
                    )
                    pending.asrTranscript = asrResult.text
                    pending.diagnostics = asrResultRaw.diagnostics
                    pending.vocabulary = vocabularyEntries.map { $0.term }
                    pending.appBundle = targetBundleID
                    pending.spelloutTerms = SpellOutDetector.candidates(in: asrResult.text)
                    self?.pendingContribution = pending
                }
                // Per-app default preset: resolved on fresh cleanup turns
                // only. Refine turns never fold a transform (the text being
                // refined is already styled). Hoisted ABOVE the provider
                // resolution because a per-app default preset is a STYLE
                // the on-device Concord tier can't apply — so a fresh
                // cleanup that folds one must route to the refine (cloud)
                // tier, same as an explicit refine. (Re-used below for the
                // actual cleanup call's `transform` argument.)
                let defaultPreset: TransformPreset? = asRefine
                    ? nil
                    : loadedConfig.presetForApp(targetBundleID)
                // Resolve which provider to use for this dictation:
                // override > references > refine > cleanup, honoring the
                // pickedModelOverride the user may have set via the
                // in-overlay ModelPicker (Task 9). isRefine is true for an
                // explicit refine OR a styled (per-app preset) cleanup —
                // both are operations the on-device tier can't perform.
                let resolvedLLM = self?.llmForInvocation(
                    isRefine: asRefine || (defaultPreset != nil)
                )
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
                // (defaultPreset hoisted above the provider resolution so
                // a styled cleanup routes to the refine tier. A successful
                // refine CLEARS the styled provenance below.)
                // Hoisted so the styled-provenance snapshot below records
                // the SAME label this call was made with.
                let pasteDestLabel: String? = self?.overlay.model.pasteTarget.map { dest in
                    if let title = dest.windowTitle, !title.isEmpty {
                        return "\(dest.appName) — \(title)"
                    }
                    return dest.appName
                }
                // Concord ("Lightweight (on-device)") needs per-word ASR
                // confidence + the user dictionary, which the shared
                // LLMProvider.generateStreaming signature can't carry.
                // Hand them to the provider via a per-utterance side-channel
                // RIGHT BEFORE cleanup; the provider consumes + clears them
                // inside generateStreaming (fresh-stateless-per-utterance).
                // `asrResultRaw.diagnostics` is nil on the HTTP ASR path —
                // Concord falls back to safe all-1.0 confidence (its
                // dictionary stage then becomes a no-op).
                // Concord's per-utterance side-channels (diagnostics, dictionary,
                // bare transcript + isRefine) are set CENTRALLY inside
                // streamCleanupOrRefine so every call site is covered uniformly;
                // this site just forwards the ASR diagnostics it captured.
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
                    pasteDestinationLabel: pasteDestLabel,
                    transform: asRefine ? nil : defaultPreset?.prompt,
                    asrDiagnostics: asrResultRaw.diagnostics,
                    shouldRenderToOverlay: { [weak self] in
                        self?.shouldStreamRenderToOverlay() ?? false
                    }
                )
                if Task.isCancelled { return }

                // Flywheel: finish populating (fresh) or extend (refine) the
                // contribution accumulator now that the LLM outcome is known —
                // BEFORE applyResult, which on the quick-mode and C1 eager-
                // accept paths reaches a terminal (and flush) synchronously.
                if !asRefine {
                    self?.pendingContribution?.referenceWindowsAttached = !effectiveRefs.isEmpty
                    self?.pendingContribution?.transformApplied =
                        (defaultPreset != nil && outcome.usedLLMOutput)
                    self?.pendingContribution?.cleaned =
                        outcome.usedLLMOutput ? outcome.text : nil
                } else if outcome.usedLLMOutput, self?.pendingContribution != nil {
                    self?.pendingContribution?.refined = true
                    self?.pendingContribution?.refineTurns.append(
                        ContributionRefineTurn(
                            instruction: asrResult.text,
                            before: priorText,
                            after: outcome.text
                        )
                    )
                }

                // 0.14.0 PR 4 (#219): stash the LLM latency on
                // the instance so the eventual accept() can
                // include it in the TranscriptEntry. nil when no
                // LLM ran (no-LLM-configured / empty-transcript).
                self?.lastLLMLatencyMs = outcome.llmLatencyMs
                // Read the chain flag BEFORE applyResult — it's still true
                // for the cleanup half of a chained refine (the refine
                // task clears it only after consuming the gate). applyResult
                // resolves the gate and returns early in that case, so this
                // is the cleanup that the user has already chained a refine
                // onto: its styled-state bookkeeping and correction-journal
                // write below must be SUPPRESSED. The refine half owns the
                // styled provenance (it clears any chip) and records its own
                // correction signal; doing it here too would flash a
                // "Styled with X" chip on the .cleaning overlay during the
                // refine stream and feed the learning analyzer a spurious
                // cleanup-only record. False on every non-chained turn.
                let wasChainedCleanup = self?.refineChainedDuringCleanup ?? false
                self?.applyResult(outcome.text, cleanupFailureMessage: outcome.failureMessage, reauthable: outcome.reauthable)
                if !asRefine, !wasChainedCleanup {
                    // "Styled" requires the LLM to have actually used its output —
                    // usedLLMOutput is false on every fallback path (no-LLM-configured,
                    // empty-transcript, empty-stream, cancellation, error) so the chip
                    // is never shown on unstyled raw text.
                    let applied = outcome.usedLLMOutput ? defaultPreset : nil
                    self?.appliedPreset = applied
                    self?.overlay.model.appliedPresetName = applied?.name
                    // Bridge 2: record the successful DEFAULT-styled use
                    // (metadata only). Source "default" so it does NOT count
                    // toward the dominance rule — only manual chip taps drive
                    // a suggestion to set a default the user hasn't set.
                    if let applied {
                        PresetUsageJournal.shared.record(
                            presetID: applied.id, presetName: applied.name,
                            appBundleID: targetBundleID, source: "default")
                    }
                    // Snapshot the dictation the style was applied to — plus
                    // the references and destination label of THIS call — so
                    // undoStyle() can replay plain cleanup of the same
                    // dictation-with-context even after later refine turns
                    // overwrite lastRawTranscript or the user changes the
                    // attached references during review.
                    self?.styledRawTranscript = applied != nil ? asrResult.text : ""
                    self?.styledReferences = applied != nil ? effectiveRefs : []
                    self?.styledPasteDestLabel = applied != nil ? pasteDestLabel : nil
                    // The INTENDED default survives a failed run, so the
                    // model-switch re-run (e.g. after an image-refs-on-
                    // non-vision-model failure) can still apply it.
                    self?.intendedDefaultPreset = defaultPreset
                } else if asRefine, outcome.usedLLMOutput {
                    // A voice refine supersedes the styled provenance, same
                    // rule as a manual chip tap (see runPreset): the text is
                    // no longer just "Styled with X". Clear the stash + chip.
                    // Gated on `asRefine` (not just the `else`) so the
                    // cleanup half of a chained refine — which also lands
                    // here, asRefine=false but wasChainedCleanup=true — does
                    // NOT touch styled state; the refine half owns it.
                    // On refine FAILURE the prior (still-styled) text is kept,
                    // so the chip stays — and its Undo stays faithful, because
                    // undoStyle replays from styledRawTranscript, not the
                    // lastRawTranscript this refine turn overwrote.
                    self?.appliedPreset = nil
                    self?.intendedDefaultPreset = nil
                    self?.styledRawTranscript = ""
                    self?.styledReferences = []
                    self?.styledPasteDestLabel = nil
                    self?.overlay.model.appliedPresetName = nil
                }
                // Skip correction capture + analysis trigger for the
                // cleanup half of a chained refine: the spell-out signal
                // would carry the soon-to-be-superseded pre-refine text,
                // and the refine half records its own (correct) signal.
                if !wasChainedCleanup {
                    let learnEnabled = self?.captureCorrectionSignals(
                        asRefine: asRefine,
                        rawInstruction: asrResult.text,
                        before: priorText,
                        outcome: outcome,
                        // Same condition that set the "Styled with X" chip
                        // above: the transform only shaped outcome.text when
                        // a default resolved AND the LLM output was used.
                        transformApplied: !asRefine && defaultPreset != nil && outcome.usedLLMOutput
                    ) ?? false
                    // Only spawn the off-path analysis trigger when the
                    // feature is on — otherwise we'd allocate a detached
                    // Task on every dictation that immediately no-ops.
                    // Use the cleanup-tier provider (`llm`), not the
                    // per-invocation `resolvedLLM` (which may be the context
                    // or picker-override model) — analysis reuses the
                    // configured cleanup model, matching the idle path.
                    if learnEnabled, let provider = self?.llm {
                        Task { await LearningAnalyzer.shared.runIfDue(provider: provider, threshold: LearningAnalyzer.triggerThreshold) }
                    }
                }
            } catch {
                // Render log-safely: ASRError.badStatus and LLMError can
                // carry response bodies a custom endpoint controls, which
                // must not be persisted to ~/.parleq/app.log.
                let safe: String
                if let asrError = error as? ASRError {
                    safe = asrError.logSafeDescription
                } else if let llmError = error as? LLMError {
                    safe = llmError.logSafeDescription
                } else {
                    safe = String(describing: error)
                }
                self?.log("pipeline failed: \(safe)")
                self?.resetPerDictationOverlayState()
                self?.phase = .idle
                self?.overlay.hide()
            }
        }
    }

    /// Capture the two observable correction signals into the opt-in
    /// CorrectionJournal. Refine -> {instruction, before, after}.
    /// Cleanup -> run the spell-out detector on the raw transcript and
    /// record any assembled candidate term + the cleaned line. No-op
    /// when cleanup failed (a fallback isn't a real correction).
    /// Re-reads the flag per utterance for live toggle. Returns whether
    /// the feature is enabled, so the caller can decide whether to spawn
    /// the off-path analysis trigger (no point allocating a Task when
    /// the feature is off).
    ///
    /// `transformApplied` — true when a per-app default preset's
    /// transform actually shaped `outcome.text`. Spell-out capture is
    /// suppressed then: the styled line ("Translate to Spanish",
    /// "Bulletize", …) may no longer contain the spelled term, or may
    /// carry transform artifacts, either of which would feed the
    /// learning analyzer bad context for dictionary proposals. Refine
    /// records are unaffected (a refine is a faithful capture of that
    /// edit whatever the text's styling, and refine turns never fold
    /// a transform).
    @discardableResult
    private func captureCorrectionSignals(
        asRefine: Bool,
        rawInstruction: String,
        before: String,
        outcome: CleanupOutcome,
        transformApplied: Bool = false
    ) -> Bool {
        let enabled = Config.load().config.learnFromCorrectionsEnabled
        guard enabled else { return false }
        // Feature is on but this cleanup failed — nothing new to capture
        // this turn, but the caller may still flush a prior backlog.
        guard outcome.failureMessage == nil else { return true }
        let journal = CorrectionJournal.shared
        if asRefine {
            let instruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty, !before.isEmpty else { return true }
            journal.record(CorrectionRecord(
                kind: .refine, instruction: instruction, before: before, after: outcome.text
            ), enabled: enabled)
        } else if !transformApplied {
            for term in SpellOutDetector.candidates(in: rawInstruction) {
                journal.record(CorrectionRecord(
                    kind: .spellout, after: outcome.text, term: term
                ), enabled: enabled)
            }
        }
        return true
    }

    private func applyResult(_ text: String, cleanupFailureMessage: String? = nil, reauthable: Bool = false) {
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
        // Chained-refine baseline: this applyResult is the FIRST cleanup
        // completing while a refine is already pending. Update currentText
        // + failure bookkeeping (done above) and hand the FINAL text to
        // the refine via the gate — but do NOT transition to
        // .awaitingAccept or arm auto-accept. The chained refine owns the
        // next terminal transition. The text resolved here is whatever
        // the cleanup produced, including the raw fallback on failure, so
        // the refine always gets a valid baseline. Quick mode can't reach
        // this (the chained path requires the overlay), but the guard
        // keeps quick-mode's direct-paste branch below correct.
        if refineChainedDuringCleanup, !quickMode {
            chainedBaselineGate?.resolve(text)
            log("first cleanup done during chained refine: baseline resolved, terminal transition deferred to refine")
            return
        }
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
            // 0.14.0 PR 4 (#219): quick mode used to bypass
            // TranscriptHistory entirely because accept() was the
            // only writer. With the Stats section (PR 5) reading
            // history for total speaking time + counts, quick-mode
            // dictations need to be recorded too — otherwise the
            // Stats undercount for users who default to quick mode.
            // The same helper used by accept() runs here, before
            // the async paste starts.
            appendTranscriptHistory(
                text: text,
                target: target,
                wasCleanupSuccessful: cleanupFailureMessage == nil
            )
            // Flywheel: quick mode pastes here without an accept() — flush
            // the accumulator as accepted before the async paste starts.
            flushContribution(disposition: .accepted, finalText: text)
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
            cleanupFailureMessage: cleanupFailureMessage,
            cleanupFailureReauthable: reauthable
        )
        // Reset the "attached context during review" flag at the start
        // of each review cycle. The references subscription sets it on
        // any later count increase while .awaitingAccept, which suspends
        // the walk-away auto-accept timer (intent to refine).
        didAttachReferenceDuringReview = false
        // C1: a hasty Enter during .cleaning armed a pending-accept. The full
        // cleaned text is in hand now (currentText set above, review overlay
        // shown), so accept it immediately rather than opening the review for
        // a keypress the user already made. If accept() bails (help overlay
        // open / unresolved image-conflict) it leaves phase == .awaitingAccept
        // — fall through to the normal review + auto-accept timer.
        if pendingAcceptOnCleanupComplete {
            pendingAcceptOnCleanupComplete = false
            overlay.model.pendingAcceptArmed = false
            accept()
            if phase != .awaitingAccept { return }
        }
        startAutoAcceptTimer()
    }

    /// Per-utterance flywheel accumulator. Built during the cleanup
    /// pipeline (created on a fresh, ARMED capture; refine turns append to
    /// it) and flushed once to ContributionRecorder at the terminal state
    /// (accept / quick-mode paste / discard), then cleared. nil whenever
    /// contribution capture isn't armed or no dictation is in flight. All
    /// access is MainActor-isolated (AppState).
    private struct PendingContribution {
        let id: UUID
        let asrModel: String
        let fluidaudioVersion: String
        let llm: String
        var wav: Data?
        var asrTranscript: String = ""
        var cleaned: String?
        var diagnostics: ASRDiagnostics?
        var vocabulary: [String] = []
        var appBundle: String?
        var spelloutTerms: [String] = []
        var referenceWindowsAttached: Bool = false
        var transformApplied: Bool = false
        var refined: Bool = false
        var refineTurns: [ContributionRefineTurn] = []

        func makeRecord(
            disposition: ContributionDisposition,
            finalText: String?,
            cleanupFailed: Bool
        ) -> ContributionRecord {
            ContributionRecord(
                id: id,
                timestamp: Date(),
                disposition: disposition,
                asrTranscript: asrTranscript,
                cleaned: cleaned,
                finalText: finalText,
                cleanupFailed: cleanupFailed,
                diagnostics: diagnostics,
                vocabulary: vocabulary,
                asrModel: asrModel,
                fluidaudioVersion: fluidaudioVersion,
                llm: llm,
                appBundle: appBundle,
                referenceWindowsAttached: referenceWindowsAttached,
                transformApplied: transformApplied,
                refined: refined,
                refineTurns: refineTurns,
                spelloutTerms: spelloutTerms,
                wav: wav
            )
        }
    }

    /// Flush the pending contribution record (if any) to the recorder.
    /// Fail-silent + off the hot path: the disk I/O runs on the
    /// ContributionRecorder actor via a detached task. Guarded so it only
    /// writes an ASR-bearing dictation. Clears the accumulator.
    private func flushContribution(
        disposition: ContributionDisposition,
        finalText: String?
    ) {
        guard let pending = pendingContribution else { return }
        pendingContribution = nil
        guard !pending.asrTranscript.isEmpty else { return }
        let record = pending.makeRecord(
            disposition: disposition,
            finalText: finalText,
            cleanupFailed: lastCleanupFailed
        )
        Task.detached { await ContributionRecorder.shared.capture(record) }
    }

    private func closeAndReset() async {
        // Clear per-dictation overlay state (references, model override,
        // banners) and cancel in-flight reference captures. The accept()
        // and cancel() callers also do this before their async paste, so
        // for them this is a harmless redundant clear — but the quick-
        // mode finalize path (applyResult) reaches closeAndReset WITHOUT
        // a preceding reset, so a reference attached via C during a
        // quick-mode hold would otherwise leak into the next dictation.
        // Centralizing it here makes every teardown path leak-free.
        resetPerDictationOverlayState()
        cancelPendingOverlayShow()
        cancelPendingRefine()
        // Tear down any chained-refine coordination so a cancelled or
        // completed session never leaves the background cleanup task or
        // its baseline gate dangling into the next dictation.
        teardownChainedRefine()
        // Force-hide the help overlay without resuming the recorder —
        // this is a teardown path (cancel / accept / done), so there's
        // nothing to resume into.
        helpVisible = false
        helpPausedRecorder = false
        holdEndedDuringHelp = false
        helpReleaseSpaceWasPressed = false
        helpOverlay.hide()
        currentText = ""
        lastRawTranscript = ""
        lastTurnWasRefine = false
        lastRefinePriorText = ""
        appliedPreset = nil
        intendedDefaultPreset = nil
        styledRawTranscript = ""
        styledReferences = []
        styledPasteDestLabel = nil
        overlay.model.appliedPresetName = nil
        overlay.model.activeTransformName = nil
        lastCleanupFailed = false
        pendingContribution = nil
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
        // Cancel any in-flight async reference-attach Tasks BEFORE
        // clearing the references array. Without this, an async
        // reference-add that started during .capturing / .cleaning
        // (e.g. an NSOpenPanel completion still resolving, an SCK
        // capture still running, a drag-drop callback still
        // processing) can append its result to `overlay.model.
        // references` AFTER this reset clears the array — leaking
        // the reference into the next dictation session. Reported
        // by RoboRev job 4282; surfaced specifically for the
        // submit-then-quickly-restart and cleaning-failure exit
        // paths where the user has moved on to the next dictation
        // before the prior async work resolved. trackCaptureTask's
        // completion-tracker child Task still removes its dictionary
        // entry on .value completion, so the dictionary stays tidy
        // even when we cancel here.
        for (_, task) in pendingCaptureTasks {
            task.cancel()
        }
        pendingCaptureTasks.removeAll()
        // #83: a finished/cancelled session is never still continuously recording.
        continuousRecording = false
        stopTapAwaitingKeyUp = false
        overlay.model.continuousRecording = false
        // #85: clear any in-place edit state so it never leaks into the next session.
        overlay.model.editing = false
        overlay.model.editableText = ""
        editPreEditText = ""
        overlay.model.references = []
        overlay.model.pickedModelOverride = nil
        overlay.model.userDowngradedConflict = false
        // Clear banners (errorMessage from a failed capture,
        // permissionPrompt from a denied TCC check) so they don't
        // persist across dictation sessions. The pick-by-click path
        // already clears them at the top of each capture for the
        // grant-and-retry case (see line ~1825), but that doesn't
        // help when the user starts a wholly new dictation later —
        // the banner from a previous session would still be visible.
        // Clearing on every exit to .idle handles both paths.
        overlay.model.errorMessage = nil
        overlay.model.permissionPrompt = nil
        // Clear the session id so the next fresh dictation mints a
        // new one. Refine turns don't call resetPerDictationOverlayState
        // so the id survives across the full copy → refine → accept
        // sequence within one overlay session.
        currentSessionEntryID = nil
        // C1: a deferred eager-accept must never survive into the next
        // dictation. Cleared here so cancel (Esc), the empty-ASR exit, and
        // the pipeline-failed exit — all of which reset without reaching
        // applyResult's terminal transition — drop the pending accept.
        pendingAcceptOnCleanupComplete = false
        overlay.model.pendingAcceptArmed = false
        // B2: drop any lingering dead-mic warning (only meaningful while
        // capturing; the next capture re-arms its own monitor).
        overlay.model.notHearingMic = false
    }

    // MARK: - Timer

    private func startAutoAcceptTimer() {
        cancelAutoAcceptTimer()
        guard autoAcceptInterval > 0 else { return }
        let gen = autoAcceptGeneration
        autoAcceptTimer = Timer.scheduledTimer(withTimeInterval: autoAcceptInterval, repeats: false) { [weak self] _ in
            // Timer callbacks run on the run loop the timer was
            // scheduled on (main here), but we hop to MainActor
            // explicitly to satisfy Swift 6. Re-check the generation on
            // the MainActor: a fired timer has already queued this task
            // by the time cancelAutoAcceptTimer() invalidates it, so a
            // manual accept/cancel could otherwise lose the race.
            Task { @MainActor in
                guard let self, self.autoAcceptGeneration == gen else { return }
                // Suspend (don't re-arm) if the user attached context
                // during review: that's intent to refine, not walk away,
                // so auto-accept stops until they refine / accept / cancel
                // rather than pasting the un-refined text. The flag is set
                // by the references subscription on any in-review attach
                // (including a remove-then-add replace, which a net-count
                // check would miss).
                if self.didAttachReferenceDuringReview {
                    return
                }
                // Defer (re-arm to re-check) while the user is mid-task:
                // help is open, the window picker is open, click-pick
                // mode is active, or a reference capture is still
                // resolving (e.g. the "Add file…" NSOpenPanel, whose task
                // is tracked before the panel opens). Firing now would
                // paste + tear the session down out from under the user.
                // Once things settle, auto-accept proceeds. This lets the
                // review-time Space/C attach gestures skip explicit timer
                // juggling, closes the pre-existing race where auto-accept
                // could fire while the +-menu picker was open in review,
                // and keeps auto-accept armed across a help-open during
                // .cleaning (the dismiss handlers also re-arm, but the
                // defer here means we don't depend on them to avoid an
                // accept() that bails on `guard !helpVisible` without
                // rescheduling).
                if self.helpVisible
                    || self.windowPickerWindow.isVisible
                    || self.overlay.model.isPickingWindow
                    || !self.pendingCaptureTasks.isEmpty {
                    self.startAutoAcceptTimer()
                    return
                }
                self.accept()
            }
        }
    }

    private func cancelAutoAcceptTimer() {
        autoAcceptTimer?.invalidate()
        autoAcceptTimer = nil
        autoAcceptGeneration &+= 1
    }

    // MARK: - Pending capture tracking

    /// Register a Task running an async reference-attachment so the
    /// submit path can await it before finalizing. The task is kept
    /// in the dictionary until it actually completes (via a
    /// completion-tracker child Task that removes its own entry).
    /// Returns the UUID key so callers can match completion if they
    /// need to — currently nobody does.
    @discardableResult
    private func trackCaptureTask(_ task: Task<Void, Never>) -> UUID {
        let id = UUID()
        pendingCaptureTasks[id] = task
        // Spawn a completion-tracker that auto-removes the entry
        // when the underlying task finishes. Without this the
        // dictionary would grow unbounded as references accumulate
        // across multiple dictation sessions.
        Task { @MainActor [weak self] in
            await task.value
            self?.pendingCaptureTasks.removeValue(forKey: id)
        }
        return id
    }

    /// Await all currently-tracked capture tasks. Called from the
    /// submit path BEFORE finalizeCapture so any references picked
    /// just before the release gesture are guaranteed to be in
    /// overlay.model.references when the ASR/LLM pipeline reads
    /// them.
    ///
    /// Snapshots the values rather than removing them — tasks stay
    /// in pendingCaptureTasks until they complete on their own (via
    /// the trackCaptureTask completion handler). That way a second
    /// submit gesture firing concurrently can't see an empty list
    /// while the first submit is still awaiting.
    ///
    /// Returns immediately when no captures are pending — the
    /// common case for non-latched dictation.
    private func awaitPendingCaptures() async {
        guard !pendingCaptureTasks.isEmpty else { return }
        let pending = Array(pendingCaptureTasks.values)
        for task in pending {
            await task.value
        }
    }

    /// Cancel any in-flight capture tasks. Called from the cancel()
    /// path so a mid-capture abort doesn't leave SCK / Vision work
    /// running uselessly in the background. Each cancelled task's
    /// completion handler will remove its own dictionary entry.
    private func cancelPendingCaptures() {
        for (_, task) in pendingCaptureTasks {
            task.cancel()
        }
        // Drop entries eagerly. The per-task completion handlers in
        // trackCaptureTask will also try to remove their entries when
        // their underlying tasks finish, but the dictionary's
        // removeValue(forKey:) is a no-op on a missing key, so the
        // double-remove is harmless.
        //
        // Eager removal matters because tasks doing synchronous work
        // (file decode, SCK capture) may not honor Task.cancel()
        // promptly — they keep running until the next isCancelled
        // check or until the work completes naturally. Leaving them
        // in pendingCaptureTasks means a fresh dictation session
        // started right after the cancel could call
        // awaitPendingCaptures() and block on those stale workers,
        // delaying or hanging the new submit. Eviction here scopes
        // the dictionary strictly to the CURRENT session's pending
        // work.
        pendingCaptureTasks.removeAll()
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
    /// `hasReferences` — pass an explicit value when the invocation's
    /// references differ from the overlay's CURRENT ones (undoStyle
    /// replays against snapshot references; resolving the tier from the
    /// live overlay there could route saved image parts at the plain
    /// cleanup model after the user removed the references). nil (the
    /// default) reads the live overlay state, the right answer for
    /// every other caller.
    /// `isRefine` — pass true for REFINE-shaped turns (hotkey voice-
    /// refine, quick chips, styled per-app-preset cleanup). It selects
    /// the refine tier (`refineLLM`) per Config.modelForInvocation's
    /// resolution chain (refine → context → cleanup), which lets those
    /// operations reach a cloud provider when cleanup is the on-device
    /// Concord tier. References still win over refine (a reference-aware
    /// turn routes to the context tier even when isRefine is true).
    private func llmForInvocation(
        hasReferences: Bool? = nil,
        isRefine: Bool = false
    ) -> (any LLMProvider)? {
        let config = Config.load().config
        let resolved = config.modelForInvocation(
            hasReferences: hasReferences ?? !overlay.model.references.isEmpty,
            isRefine: isRefine,
            override: overlay.model.pickedModelOverride
        )
        let cleanupId = ModelIdentifier(provider: config.llmProvider, model: config.llmModel)

        // Cleanup tier — most common path.
        if resolved == cleanupId {
            return llm
        }

        // Refine tier — use refineLLM when configured and resolved to it.
        // Degrade to context then cleanup if refineLLM isn't wired (e.g.
        // refine model set in config but provider init failed).
        if let refineModel = config.refineModel, resolved == refineModel {
            return refineLLM ?? contextLLM ?? llm
        }

        // Context tier — use contextLLM when configured.
        if let contextModel = config.contextModel, resolved == contextModel {
            // Degrade gracefully when contextLLM isn't wired (e.g.
            // context model set in config but provider init failed).
            return contextLLM ?? llm
        }

        // Resolved is neither cleanup, refine, nor context — the
        // in-overlay picker produced an identifier no pre-built provider
        // services. This is a latent path today (picker scope is
        // cleanup+context+refine) but we log and fall back rather than
        // silently returning `llm` whose baked-in model is not the
        // intended override.
        log("llmForInvocation: resolved model \(resolved.provider)/\(resolved.model) has no matching pre-built provider; falling back to refine/context/cleanup")
        return refineLLM ?? contextLLM ?? llm
    }

    /// Resolve the *currently intended* paste target by looking at the
    /// live PasteTargetTracker (the same source the overlay's chip
    /// reads from). If the user switched apps after starting the
    /// dictation, this returns the app they're currently focused on
    /// — matching the chip — rather than the app that happened to be
    /// frontmost at hotkey-down.
    /// Restore focus to the user's pre-hotkey frontmost app (the
    /// dictation's `pasteTarget`), used after a reference-window
    /// capture so the user is returned to their original Space
    /// instead of stranded on the captured app's Space.
    ///
    /// The inner restorePriorFrontmost inside ReferenceCapture.
    /// captureWithRetry snapshots NSWorkspace.frontmostApplication
    /// AT RETRY TIME — which is typically Parleq itself, because the
    /// picker UI has already taken visible focus by then. That inner
    /// restore therefore activates Parleq (a no-op for Space-switch)
    /// rather than the user's true origin. This outer helper uses
    /// the pasteTarget captured at hotkey-down (via
    /// Paster.captureFrontmost in startFreshCapture), which is the
    /// authoritative origin app even after the picker has taken
    /// over visible focus. Routes through Paster.activate, which
    /// uses the AppleScript bundle-id `activate` AppleEvent — the
    /// only synthesized-event path that crosses full-screen-Space
    /// boundaries (spike #223 / issue #212).
    @MainActor
    private func restoreFocusToDictationOrigin() {
        guard let origin = pasteTarget else { return }
        // Route through OverlayWindow.performActivationWithSpaceSwitch
        // so the overlay's `.canJoinAllSpaces` collection behavior is
        // temporarily stripped during the activate call. Without that
        // strip, macOS sees the overlay as "still relevant on the
        // current Space" and suppresses the Space-switch animation
        // even though the target app's activate succeeded — paste
        // target ends up correct but the visible Space stays on the
        // captured app's full-screen Space (issue #229).
        //
        // Fire-and-forget: the call sites live inside MainActor.run
        // closures that can't suspend, so we kick off a Task that
        // does the async sleep + restore. The caller continues
        // synchronously; the Space animation completes on its own.
        Task { @MainActor in
            await overlay.performActivationWithSpaceSwitch {
                Paster.activate(bundleID: origin.bundleID, pid: origin.pid)
            }
        }
    }

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
            // If our task was cancelled (e.g. user pressed Esc
            // during the SCK capture), bail without mutating model
            // state — otherwise the reference would leak into the
            // NEXT dictation session after resetPerDictationOverlayState.
            guard !Task.isCancelled else { return }
            overlay.model.references.append(reference)
            // Restore the user's pre-hotkey Space/app — capture may
            // have crossed onto the source app's full-screen Space,
            // and without this the user is stranded there. See
            // restoreFocusToDictationOrigin's docstring.
            restoreFocusToDictationOrigin()
        } catch CaptureError.permissionDenied {
            guard !Task.isCancelled else { return }
            overlay.model.permissionPrompt = "Screen Recording permission denied. Grant in System Settings, then try again."
            restoreFocusToDictationOrigin()
        } catch let captureError as CaptureError {
            guard !Task.isCancelled else { return }
            // See the matching handler in the pick-by-click path above —
            // CaptureError already carries a user-facing description.
            overlay.model.errorMessage = captureError.localizedDescription
            restoreFocusToDictationOrigin()
        } catch {
            guard !Task.isCancelled else { return }
            overlay.model.errorMessage = "Couldn't capture window: \(error.localizedDescription)"
            restoreFocusToDictationOrigin()
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
        // Task #41: after a refine turn, lastRawTranscript is the
        // refine INSTRUCTION — re-cleaning it as a dictation produced
        // garbage ("make it more formal" cleaned up as prose). Re-run
        // the same SHAPE the user last ran: a refine re-runs as a
        // refine (same instruction, same prior text) on the new model.
        let asRefineRerun = lastTurnWasRefine
        let refinePriorText = lastRefinePriorText
        let targetBundleID = pasteTarget?.bundleID
        let recleanConfig = Config.load().config
        let dictionary = recleanConfig.customDictionaryEnabled
            ? recleanConfig.customDictionary
            : []
        // isRefine mirrors the re-run shape: a refine re-run is a refine
        // (routes to the refine tier); a cleanup re-run stays on cleanup.
        let resolvedLLM = llmForInvocation(isRefine: asRefineRerun)
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
        // Use the INTENDED per-app default, not appliedPreset: when the
        // first cleanup fell back (e.g. image refs on a non-vision model
        // — exactly the case the Switch button exists for), appliedPreset
        // was cleared with the fallback render, but the user's configured
        // default should still style the re-run. Re-check the feature
        // gate against the freshly-loaded config: intendedDefaultPreset
        // was resolved when the dictation started, and MDM may have
        // disabled presets since — the in-memory intent must not bypass
        // presetForApp's transformPresetsEnabled guard.
        let intendedPreset = recleanConfig.transformPresetsEnabled
            ? intendedDefaultPreset
            : nil
        // Hoisted so the styled-provenance snapshot below records the
        // SAME label this re-run was made with.
        let pasteDestLabel: String? = overlay.model.pasteTarget.map { dest in
            if let title = dest.windowTitle, !title.isEmpty {
                return "\(dest.appName) — \(title)"
            }
            return dest.appName
        }
        inFlightTask = Task { @MainActor [weak self] in
            let outcome = await streamCleanupOrRefine(
                llm: resolvedLLM,
                overlay: overlay,
                useOverlay: true,
                asRefine: asRefineRerun,
                rawTranscript: rawTranscript,
                priorText: refinePriorText,
                targetBundleID: targetBundleID,
                customDictionary: dictionary,
                references: effectiveRefs,
                pasteDestinationLabel: pasteDestLabel,
                // Refine re-runs never fold a preset (mirrors the main
                // pipeline: the text being refined is already styled).
                transform: asRefineRerun ? nil : intendedPreset?.prompt
            )
            if Task.isCancelled { return }
            // 0.14.0 PR 4 (#219): the model-switch path runs its
            // own cleanup pass — record the NEW pass's latency so
            // accepting after the switch reflects what the user
            // actually accepted, not the original pre-switch run.
            self?.lastLLMLatencyMs = outcome.llmLatencyMs
            self?.applyResult(outcome.text, cleanupFailureMessage: outcome.failureMessage, reauthable: outcome.reauthable)
            if outcome.usedLLMOutput, asRefineRerun {
                // A refine re-run supersedes styled provenance exactly
                // like a voice refine does in the main pipeline: the
                // text is no longer just "Styled with X".
                self?.appliedPreset = nil
                self?.intendedDefaultPreset = nil
                self?.styledRawTranscript = ""
                self?.styledReferences = []
                self?.styledPasteDestLabel = nil
                self?.overlay.model.appliedPresetName = nil
            } else if outcome.usedLLMOutput {
                // Same rule as the primary cleanup path: a successful
                // styled run sets the chip + the snapshots Undo replays
                // from (the transcript/references/label THIS run used).
                // With no intended default everything resolves to
                // nil/empty — clearing any stale claim.
                self?.appliedPreset = intendedPreset
                self?.overlay.model.appliedPresetName = intendedPreset?.name
                self?.styledRawTranscript = intendedPreset != nil ? rawTranscript : ""
                self?.styledReferences = intendedPreset != nil ? effectiveRefs : []
                self?.styledPasteDestLabel = intendedPreset != nil ? pasteDestLabel : nil
            } else {
                // The fallback render isn't styled — don't leave a stale
                // "Styled with X" claim on it. Mirrors the main path: only
                // a successful non-empty LLM output sets usedLLMOutput=true,
                // so every error/empty-stream/no-LLM path clears the chip.
                // intendedDefaultPreset is deliberately KEPT — another
                // switch attempt should still try to style.
                self?.appliedPreset = nil
                self?.styledRawTranscript = ""
                self?.styledReferences = []
                self?.styledPasteDestLabel = nil
                self?.overlay.model.appliedPresetName = nil
            }
        }
    }

    /// Run a transform preset against the current review text — the
    /// preset's stored prompt occupies the same instruction slot a spoken
    /// refine uses, through the same pipeline. Deliberately does NOT call
    /// captureCorrectionSignals: a canned preset instruction is not a
    /// correction signal and would pollute term-learning analysis.
    @MainActor
    func runPreset(id: String) {
        guard phase == .awaitingAccept else { return }
        let (config, _) = Config.load()
        guard config.transformPresetsEnabled,
              let preset = config.transformPresets.first(where: { $0.id == id })
        else { return }
        let current = overlay.model.text
        guard !current.isEmpty else { return }
        let dictionary = config.customDictionaryEnabled ? config.customDictionary : []
        // hasReferences: false — a preset tap is a plain-text refine of
        // the SHOWN text (no reference parts are sent below), so resolve
        // the refine tier even if references are still attached.
        // isRefine: true — a quick chip IS a refine, so it routes to the
        // refine (cloud) tier when configured (and never to Concord,
        // which would no-op it).
        let resolvedLLM = llmForInvocation(hasReferences: false, isRefine: true)
        let targetBundleID = pasteTarget?.bundleID
        // Cancel any lingering auto-accept timer so it doesn't fire
        // mid-re-cleanup.
        cancelAutoAcceptTimer()
        // Surface the transform name while it streams so the overlay's
        // cleaning state reads "Applying <name>…" instead of the
        // anonymous indicator.
        overlay.model.activeTransformName = preset.name
        phase = .cleaning
        // Defensive: the awaitingAccept guard means any prior task has
        // completed, but cancel before reassigning anyway — matching
        // the main capture path — so a dropped reference can never
        // keep streaming.
        inFlightTask?.cancel()
        inFlightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // A manual preset tap is a refine pass on the SHOWN text, so
            // references aren't needed — the text already reflects them.
            let outcome = await streamCleanupOrRefine(
                llm: resolvedLLM,
                overlay: self.overlay,
                useOverlay: true,
                asRefine: true,
                rawTranscript: preset.prompt,
                priorText: current,
                targetBundleID: targetBundleID,
                customDictionary: dictionary
            )
            if Task.isCancelled {
                // Clear the transform name on early-exit so a cancelled
                // run never leaks the label into the next dictation.
                self.overlay.model.activeTransformName = nil
                return
            }
            self.lastLLMLatencyMs = outcome.llmLatencyMs
            // Clear before applyResult so the status line disappears at
            // the same moment the result text appears.
            self.overlay.model.activeTransformName = nil
            self.applyResult(outcome.text, cleanupFailureMessage: outcome.failureMessage, reauthable: outcome.reauthable)
            if outcome.usedLLMOutput {
                // Flywheel: a manual preset application during review is an
                // LLM style transform, not an ASR correction. runPreset has
                // its own task (bypasses runCleanupPipeline), so mark the
                // accumulator here — record the preset as a refine turn so
                // corrector_pair_eligible excludes the styled `final`.
                if self.pendingContribution != nil {
                    self.pendingContribution?.refined = true
                    self.pendingContribution?.refineTurns.append(
                        ContributionRefineTurn(
                            instruction: preset.prompt,
                            before: current,
                            after: outcome.text
                        )
                    )
                }
                // A manual transform supersedes the auto-applied default's
                // provenance — the text is no longer just "Styled with X".
                // On failure the fallback IS the still-styled prior text,
                // so the chip (and its Undo, replayed from the
                // styledRawTranscript snapshot) stays truthful and kept.
                self.appliedPreset = nil
                self.intendedDefaultPreset = nil
                self.styledRawTranscript = ""
                self.styledReferences = []
                self.styledPasteDestLabel = nil
                self.overlay.model.appliedPresetName = nil
                // Task #41 (review finding): a chip tap IS the last LLM
                // turn — record its shape so a model switch re-runs THIS
                // preset refine on the new model, not a stale prior turn.
                self.lastRawTranscript = preset.prompt
                self.lastTurnWasRefine = true
                self.lastRefinePriorText = current
                // Bridge 2: record the successful MANUAL preset use (metadata
                // only — id/name/bundle/timestamp, no dictation text) so the
                // off-hot-path dominance rule can suggest a per-app default.
                PresetUsageJournal.shared.record(
                    presetID: preset.id, presetName: preset.name,
                    appBundleID: targetBundleID, source: "manual")
            }
        }
    }

    /// Apply the transform preset at a 1-based position (digit keys 1–9
    /// in review). Resolves against `config.transformPresets` — the same
    /// ordered source the overlay chips render from — so digit N always
    /// matches the chip numbered N. Returns true iff a preset was applied,
    /// letting the panel consume the keystroke only on a hit. The result
    /// is always consumed (the panel uses it to decide event swallowing),
    /// so it is intentionally not @discardableResult.
    @MainActor
    func runPresetByNumber(_ number: Int) -> Bool {
        guard phase == .awaitingAccept else { return false }
        let (config, _) = Config.load()
        guard config.transformPresetsEnabled,
              let index = presetIndex(forNumber: number,
                                      presetCount: config.transformPresets.count)
        else { return false }
        runPreset(id: config.transformPresets[index].id)
        return true
    }

    /// Tapped the overlay's signed-out notice (enterprise OIDC
    /// fail-closed). Cancel any auto-accept timer so the raw transcript
    /// can't auto-paste while the browser sign-in is open, flip the
    /// notice to "signing in…", run the SAME interactive sign-in the
    /// Settings → Company Account button drives, then reflect the
    /// result. On success we warm the cloud-credential exchanges so the
    /// user's subsequent ↻ tap re-cleans against fresh credentials. We
    /// do NOT auto-re-clean — that's an explicit opt-in via the ↻ tap.
    @MainActor
    func reauthSignIn() {
        guard phase == .awaitingAccept,
              overlay.model.cleanupFailureReauthable,
              overlay.model.reauthState == .signedOut,
              let signIn = oidcInteractiveSignIn else { return }
        // No auto-resume: the overlay simply stays in awaitingAccept.
        cancelAutoAcceptTimer()
        overlay.model.reauthState = .signingIn
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await signIn()
            // The overlay may have been dismissed during the browser
            // round-trip; if so, the sign-in still completed against the
            // shared session (it benefits the next dictation) and there
            // is nothing left to update here.
            guard self.phase == .awaitingAccept,
                  self.overlay.model.cleanupFailureReauthable else { return }
            if ok {
                if let aws = self.oidcAWSExchange { Task { await aws.warm() } }
                if let gcp = self.oidcGCPExchange { Task { await gcp.warm() } }
                self.overlay.model.reauthState = .signedIn
            } else {
                // Cancelled or failed — restore the tappable signed-out
                // notice. The session surfaces its own failure banner in
                // Settings; the overlay just lets the user retry or accept
                // the raw transcript with Enter.
                self.overlay.model.reauthState = .signedOut
            }
        }
    }

    /// Tapped "clean up this dictation" (↻) after a successful re-auth.
    /// Re-runs the cleanup that previously failed closed, with identical
    /// inputs — the provider now pulls fresh federated credentials from
    /// the warmed CachedExchange. Mirrors switchModelAndRecleanup's
    /// faithful re-run (refine-shape awareness, paste-destination label,
    /// image-reference degradation, intended per-app preset) but keeps
    /// the current model — auth, not the model, was the failure.
    @MainActor
    func reauthReclean() {
        guard phase == .awaitingAccept,
              overlay.model.reauthState == .signedIn,
              !lastRawTranscript.isEmpty else { return }
        cancelAutoAcceptTimer()
        phase = .cleaning
        let overlay = self.overlay
        let rawTranscript = lastRawTranscript
        // Task #41: after a refine turn lastRawTranscript holds the
        // refine INSTRUCTION — re-run the same SHAPE the user last ran.
        let asRefineRerun = lastTurnWasRefine
        let refinePriorText = lastRefinePriorText
        let targetBundleID = pasteTarget?.bundleID
        let recleanConfig = Config.load().config
        let dictionary = recleanConfig.customDictionaryEnabled
            ? recleanConfig.customDictionary
            : []
        // A styled reclean carries a transform the on-device tier can't apply, so it must
        // route to the refine tier too — mirror the primary capture path's isRefine
        // (asRefine || preset). Resolve the preset BEFORE provider selection.
        let intendedPreset = recleanConfig.transformPresetsEnabled
            ? intendedDefaultPreset
            : nil
        let resolvedLLM = llmForInvocation(isRefine: asRefineRerun || intendedPreset != nil)
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
        let pasteDestLabel: String? = overlay.model.pasteTarget.map { dest in
            if let title = dest.windowTitle, !title.isEmpty {
                return "\(dest.appName) — \(title)"
            }
            return dest.appName
        }
        inFlightTask?.cancel()
        inFlightTask = Task { @MainActor [weak self] in
            let outcome = await streamCleanupOrRefine(
                llm: resolvedLLM,
                overlay: overlay,
                useOverlay: true,
                asRefine: asRefineRerun,
                rawTranscript: rawTranscript,
                priorText: refinePriorText,
                targetBundleID: targetBundleID,
                customDictionary: dictionary,
                references: effectiveRefs,
                pasteDestinationLabel: pasteDestLabel,
                transform: asRefineRerun ? nil : intendedPreset?.prompt
            )
            if Task.isCancelled { return }
            self?.lastLLMLatencyMs = outcome.llmLatencyMs
            self?.applyResult(outcome.text, cleanupFailureMessage: outcome.failureMessage, reauthable: outcome.reauthable)
            // Restore styled provenance exactly like switchModelAndRecleanup:
            // the original failed-closed cleanup folded the per-app default
            // preset, so a successful re-clean must set the chip + the
            // snapshots Undo replays from (or clear any stale claim on a
            // fallback render).
            if outcome.usedLLMOutput, asRefineRerun {
                self?.appliedPreset = nil
                self?.intendedDefaultPreset = nil
                self?.styledRawTranscript = ""
                self?.styledReferences = []
                self?.styledPasteDestLabel = nil
                self?.overlay.model.appliedPresetName = nil
            } else if outcome.usedLLMOutput {
                self?.appliedPreset = intendedPreset
                self?.overlay.model.appliedPresetName = intendedPreset?.name
                self?.styledRawTranscript = intendedPreset != nil ? rawTranscript : ""
                self?.styledReferences = intendedPreset != nil ? effectiveRefs : []
                self?.styledPasteDestLabel = intendedPreset != nil ? pasteDestLabel : nil
            } else {
                self?.appliedPreset = nil
                self?.styledRawTranscript = ""
                self?.styledReferences = []
                self?.styledPasteDestLabel = nil
                self?.overlay.model.appliedPresetName = nil
            }
        }
    }

    /// Undo a per-app default style: clear the stash + chip immediately,
    /// then re-run PLAIN cleanup (no transform) from the styledRawTranscript
    /// snapshot — the dictation the style was applied to. NOT from
    /// lastRawTranscript: refine turns overwrite that with the refine
    /// utterance, so it can hold the wrong text by the time Undo is
    /// clicked (e.g. after a failed refine, which keeps the chip).
    /// Mirrors switchModelAndRecleanup's reference handling
    /// (same refs, same imageReferenceEnabled degradation, same destination
    /// label) so reference-aware dictations undo faithfully — the result is
    /// the un-styled version of the SAME dictation, not a plain re-run that
    /// drops context.
    @MainActor
    func undoStyle() {
        guard phase == .awaitingAccept, appliedPreset != nil else { return }
        let raw = styledRawTranscript
        // Replay against the SNAPSHOTS from the styled run — not the
        // overlay's current references or target. If the user attached or
        // removed references after the styled result appeared, Undo must
        // still produce the un-styled version of the SAME
        // dictation-with-context, not a re-generation against new context.
        let snapshotRefs = styledReferences
        let snapshotDestLabel = styledPasteDestLabel
        // Re-align lastRawTranscript with the dictation this undo
        // restores: a failed refine may have left it holding the spoken
        // refine instruction, and a later model-switch re-clean reads it.
        lastRawTranscript = raw
        // The undo replay is a fresh-cleanup shape — a model switch
        // after it must re-clean, not re-refine (task #41).
        lastTurnWasRefine = false
        lastRefinePriorText = ""
        appliedPreset = nil
        intendedDefaultPreset = nil
        styledRawTranscript = ""
        styledReferences = []
        styledPasteDestLabel = nil
        overlay.model.appliedPresetName = nil
        guard !raw.isEmpty else { return }
        let (config, _) = Config.load()
        let dictionary = config.customDictionaryEnabled ? config.customDictionary : []
        // Resolve the tier from the SNAPSHOT references, not the live
        // overlay — the user may have removed references before Undo,
        // and the replay still carries the snapshot reference parts.
        let resolvedLLM = llmForInvocation(hasReferences: !snapshotRefs.isEmpty)
        let targetBundleID = pasteTarget?.bundleID
        // The snapshot refs are post-degradation as sent, but re-apply the
        // same image-reference degradation as switchModelAndRecleanup and
        // the primary capture path (idempotent on already-degraded refs).
        // Two conditions force degradation:
        //   1. imageReferenceEnabled is false (global off-switch).
        //   2. userDowngradedConflict is true — the user chose "Downgrade &
        //      send" to acknowledge that image parts would be dropped on their
        //      non-vision model. Undo re-runs cleanup on the SAME model, so it
        //      must reproduce the same text-only treatment (the flag may have
        //      been set AFTER the styled run, e.g. via a model switch).
        let effectiveRefs: [Reference]
        let shouldDegradeImageRefs = !config.imageReferenceEnabled
            || overlay.model.userDowngradedConflict
        if shouldDegradeImageRefs {
            effectiveRefs = snapshotRefs.map { ref in
                guard ref.captureMode == .image else { return ref }
                var degraded = ref
                degraded.captureMode = .text
                return degraded
            }
        } else {
            effectiveRefs = snapshotRefs
        }
        let pasteDestLabel = snapshotDestLabel
        // Cancel any lingering auto-accept timer so it doesn't fire
        // mid-re-cleanup.
        cancelAutoAcceptTimer()
        phase = .cleaning
        // Defensive: cancel before reassigning (matching the main
        // capture path) so a dropped reference can never keep streaming.
        inFlightTask?.cancel()
        inFlightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await streamCleanupOrRefine(
                llm: resolvedLLM,
                overlay: self.overlay,
                useOverlay: true,
                asRefine: false,
                rawTranscript: raw,
                priorText: "",
                targetBundleID: targetBundleID,
                customDictionary: dictionary,
                references: effectiveRefs,
                pasteDestinationLabel: pasteDestLabel
            )
            if Task.isCancelled { return }
            self.lastLLMLatencyMs = outcome.llmLatencyMs
            self.applyResult(outcome.text, cleanupFailureMessage: outcome.failureMessage, reauthable: outcome.reauthable)
        }
    }

    /// Single writer for `TranscriptHistory.shared` used by both
    /// the accept() path and the quick-mode auto-paste path. 0.14.0
    /// PR 4 (#219) extracted this from accept() so quick-mode
    /// dictations also land in history (previously they bypassed
    /// it entirely, which would have undercounted the Stats
    /// section's "total speaking time" + count metrics for users
    /// who default to quick mode).
    ///
    /// Skips empty text — an empty cleaned result isn't a useful
    /// history entry and would only add noise. The timing fields
    /// + reference list are read from the per-dictation instance
    /// state populated by finalizeCapture + the cleanup task.
    @MainActor
    private func appendTranscriptHistory(
        text: String,
        target: PasteTarget?,
        wasCleanupSuccessful: Bool
    ) {
        guard !text.isEmpty else { return }
        let refs = overlay.model.references
        // Use the stable session id so accept() after copy() upserts
        // (updates) the same entry rather than appending a duplicate.
        // Defensive UUID() mint handles any unexpected nil path (should
        // not occur in normal flow because startFreshCapture mints one).
        let entryID = currentSessionEntryID ?? UUID()
        TranscriptHistory.shared.upsert(TranscriptEntry(
            id: entryID,
            text: text,
            targetAppName: target?.name,
            wasCleanupSuccessful: wasCleanupSuccessful,
            referenceCount: refs.count,
            referenceLabels: refs.map(\.label),
            audioDurationMs: lastAudioDurationMs,
            asrLatencyMs: lastASRLatencyMs,
            llmLatencyMs: lastLLMLatencyMs
        ))
    }

    @MainActor
    private func copy() {
        let text = currentText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // Record to history so a copy-then-close sequence leaves an
        // entry in Recent Dictations. Uses the session id so a
        // subsequent refine or accept upserts (updates) this same
        // entry rather than appending a duplicate.
        guard !text.isEmpty else { return }
        let refs = overlay.model.references
        let entryID = currentSessionEntryID ?? UUID()
        TranscriptHistory.shared.upsert(TranscriptEntry(
            id: entryID,
            text: text,
            targetAppName: nil,  // nothing pasted yet; accept() fills this in via upsert
            wasCleanupSuccessful: !lastCleanupFailed,
            referenceCount: refs.count,
            referenceLabels: refs.map(\.label),
            audioDurationMs: lastAudioDurationMs,
            asrLatencyMs: lastASRLatencyMs,
            llmLatencyMs: lastLLMLatencyMs
        ))
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
    /// 0.14.0 PR 4 (#219): total LLM stream latency in
    /// milliseconds. nil when no LLM ran (the no-LLM-configured
    /// branch and the empty-transcript branch — both return the
    /// fallback text without invoking the provider). Threaded
    /// into TranscriptEntry by AppState so the Stats section can
    /// surface latency averages.
    public let llmLatencyMs: Int?
    /// True ONLY when the assembled LLM output was actually used as
    /// the result text (i.e. the stream ran, produced a non-empty
    /// string, and that string is `text`). False at every fallback
    /// return site: no-LLM-configured, empty-transcript, empty-stream,
    /// cancellation, and error. Guards the "Styled with …" chip so an
    /// empty-stream fallback (which still carries llmLatencyMs from the
    /// completed-but-empty stream) does not incorrectly claim styling.
    public let usedLLMOutput: Bool
    /// True when `failureMessage` represents an enterprise OIDC
    /// fail-closed condition recoverable by an interactive org sign-in
    /// (see `LLMProvider.cleanupFailureIsReauthable`). Drives the
    /// overlay's tappable signed-out notice. Always false on success.
    public let reauthable: Bool

    init(text: String, failureMessage: String?, reauthable: Bool = false, llmLatencyMs: Int? = nil, usedLLMOutput: Bool = false) {
        self.text = text
        self.failureMessage = failureMessage
        self.reauthable = reauthable
        self.llmLatencyMs = llmLatencyMs
        self.usedLLMOutput = usedLLMOutput
    }
}

/// Pure decision for whether an in-flight cleanup/refine stream may
/// paint its chunks onto the overlay. Extracted from AppState so the
/// chained-refine render-suppression logic is unit-testable without the
/// full state machine (which needs AppKit windows + the audio engine).
///
/// Every LLM pass (cleanup AND refine) streams under phase == .cleaning
/// — finalizeCapture sets that before spawning the task; `.refining`
/// covers only the audio hold. So a normal cleanup or refine renders
/// (chain flag false). The chain flag is true ONLY for the first cleanup
/// after the user has chained a refine onto it: it keeps accumulating
/// text in the background but must stop painting so it can't clobber the
/// .refining capture / the chained refine's stream. The chained refine
/// clears the flag before it streams, so its own chunks render.
func chainedRefineShouldRender(
    phase: AppState.Phase,
    refineChainedDuringCleanup: Bool
) -> Bool {
    return phase == .cleaning && !refineChainedDuringCleanup
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
    pasteDestinationLabel: String? = nil,
    transform: String? = nil,
    // ASR per-token confidence diagnostics (bundled path only; nil on the HTTP ASR
    // path and on re-clean call sites). Forwarded to the on-device Concord
    // provider's dictionary stage; ignored by every other provider.
    asrDiagnostics: ASRDiagnostics? = nil,
    // Gate for the per-chunk overlay writes. Evaluated on the MainActor
    // before each streamed chunk renders. When it returns false the
    // chunk text still accumulates into `assembled` (so the final
    // CleanupOutcome is correct) but is NOT written to the overlay —
    // this is how a cleanup that the user has already chained a refine
    // onto stops clobbering the .refining view while it finishes in the
    // background. Default always-true preserves the normal raw-first
    // streaming behavior for every other call site.
    shouldRenderToOverlay: @escaping @MainActor @Sendable () -> Bool = { true }
) async -> CleanupOutcome {
    let fallback = asRefine ? priorText : rawTranscript
    guard let llm = llm else {
        // No LLM provider configured at launch (e.g., the user
        // selected provider=none, or every provider's init failed).
        // Render the fallback without any failure decoration —
        // there's no error here, just an intentional no-cleanup
        // posture.
        if useOverlay, shouldRenderToOverlay() {
            overlay.show(state: .cleaning, text: fallback)
        }
        return CleanupOutcome(text: fallback, failureMessage: nil)
    }
    if rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if useOverlay, shouldRenderToOverlay() {
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
        // Reference-aware turns use the reference-specific transform
        // wording — the plain transformHint references "the cleanup
        // rules above", which don't exist in this system prompt.
        let transformAddendum = asRefine ? "" : SystemPrompts.referenceTransformHint(transform)
        var refSystem = PromptBuilder.referenceAwareSystem
        if !dictHint.isEmpty { refSystem += "\n\n" + dictHint }
        if !transformAddendum.isEmpty { refSystem += "\n\n" + transformAddendum }
        systemPrompt = refSystem
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
        systemPrompt = SystemPrompts.cleanup(dictionary: customDictionary, transform: transform)
        messages = [LLMMessage(role: "user", content: "Transcript to clean up:\n\n\(rawTranscript)")]
    }

    // Raw-first display (task #53): instead of blanking the overlay
    // while the LLM warms up, show the fallback text (the raw ASR
    // transcript on fresh turns; the prior text on refines) marked
    // provisional — dimmed, with the footer noting that Enter accepts
    // it as-is. The first streamed chunk replaces it. Skip in quick
    // mode — there's no overlay to update.
    if useOverlay, shouldRenderToOverlay() {
        overlay.showProvisionalCleaning(text: fallback, isRefine: asRefine)
    }

    let assembled = AssembledTextBox()
    let latencyBox = LatencyBox()

    do {
        // TTFT watchdog + retry (task #53): if no first token arrives
        // within the deadline, cancel the attempt and retry once with a
        // longer leash — a fresh request often lands on a faster serving
        // path. A second stall throws to the failure path below; the
        // raw-first text is already on screen and acceptable, so the
        // user is never stuck staring at nothing. The watchdog covers
        // TIME-TO-FIRST-TOKEN only; once tokens flow, mid-stream stalls
        // remain covered by the providers' 60s idle timeouts. Stall
        // detection keys off assembled.value (chunks land there before
        // the overlay hop), so a retry can only happen while the stream
        // has produced nothing — no duplicate text risk.
        // Thinking-class models (Gemini Pro, reasoning families) get one
        // generous deadline instead of the fast retry ladder — see
        // ModelCapability.expectsExtendedTTFT.
        // #55: the watchdog ladders are configurable via llm.tuning
        // (ttft_deadline_seconds / ttft_deadline_thinking_seconds).
        let ttftDeadlines: [TimeInterval] =
            ModelCapability.expectsExtendedTTFT(provider: llm.providerName, model: llm.model)
            ? LLMTuning.current.ttftDeadlineThinkingSeconds
            : LLMTuning.current.ttftDeadlineSeconds
        let streamOnce: @Sendable (LLMStreamEvent) -> Void = { event in
            // The streaming callback fires on URLSession's queue, not
            // MainActor. Hop to the main actor for any overlay
            // mutation.
            switch event {
            case .chunk(let text):
                let wasFirst = assembled.appendReturningWasFirst(text)
                if useOverlay {
                    Task { @MainActor in
                        // Drop the overlay write if the caller has moved
                        // on (e.g. a chained refine switched the overlay
                        // to .refining). The chunk already landed in
                        // `assembled`, so the final outcome stays correct
                        // — we just don't paint a stale cleanup stream
                        // over the refine view.
                        guard shouldRenderToOverlay() else { return }
                        if wasFirst {
                            // Replace the provisional raw-first text
                            // (show() clears the provisional flag).
                            overlay.show(state: .cleaning, text: text)
                        } else {
                            overlay.appendText(text)
                        }
                    }
                }
            case .done(let summary):
                let kind = asRefine ? "refine" : "cleanup"
                let ttftMs = Int(summary.ttft * 1000)
                let totalMs = Int(summary.totalLatency * 1000)
                latencyBox.set(totalMs)
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

        // Cleanup-only on-device tier: set Concord's per-utterance side-channels
        // here so EVERY call site (main capture, preset re-run, model-switch /
        // reauth re-clean) is covered uniformly. Concord reads the bare transcript
        // + isRefine; on a refine turn it returns priorText unchanged and never runs
        // cleanup on the instruction scaffolding. Set once before the attempt loop —
        // Concord is instant and never retries, so the consume-and-clear is safe.
        if let concord = llm as? ConcordCleanupProvider {
            concord.setUtteranceContext(diagnostics: asrDiagnostics)
            concord.setUtteranceDictionary(customDictionary)
            concord.setUtteranceCall(transcript: rawTranscript, isRefine: asRefine, priorText: priorText)
        }

        for (attemptIndex, deadline) in ttftDeadlines.enumerated() {
            do {
                try await withThrowingTaskGroup(of: Bool.self) { group in
                    // true = the stream task; false = the watchdog.
                    group.addTask {
                        try await llm.generateStreaming(
                            systemPrompt: systemPrompt,
                            messages: messages,
                            onEvent: streamOnce
                        )
                        return true
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                        if assembled.value.isEmpty { throw TTFTStallError() }
                        return false
                    }
                    while let isStream = try await group.next() {
                        if isStream {
                            // Stream finished — don't keep the watchdog
                            // sleeping out its deadline.
                            group.cancelAll()
                            break
                        }
                        // Watchdog returned benignly (token already
                        // arrived) — keep waiting for the stream.
                    }
                }
                break // attempt succeeded
            } catch is TTFTStallError {
                let attempt = attemptIndex + 1
                FileHandle.standardError.write(
                    "[parleq] \(asRefine ? "refine" : "cleanup") ttft watchdog: attempt \(attempt) produced no token in \(deadline)s\(attempt < ttftDeadlines.count ? " — retrying" : " — falling back")\n"
                        .data(using: .utf8) ?? Data())
                if attemptIndex == ttftDeadlines.count - 1 {
                    throw LLMError.requestFailed(TTFTTimeoutError(attempts: ttftDeadlines.count))
                }
                // loop to retry
            }
        }
        let final = assembled.value
        if final.isEmpty {
            // Stream produced nothing visible — paste the fallback
            // instead of leaving the overlay empty. This is treated
            // as a non-failure (no decorations) because some LLMs
            // legitimately return empty for unusable input, and we
            // don't want to flag that as an auth / provider error.
            //
            // Skip the re-show when the outer task was cancelled —
            // cancel() has queued closeAndReset to hide the overlay
            // and re-showing here races against it, leaving the
            // overlay stuck in a fake "processing" state that only
            // the user pressing the hotkey can dismiss.
            if useOverlay, !Task.isCancelled, shouldRenderToOverlay() {
                overlay.show(state: .cleaning, text: fallback)
            }
            return CleanupOutcome(text: fallback, failureMessage: nil, llmLatencyMs: latencyBox.value)
        }
        return CleanupOutcome(text: final, failureMessage: nil, llmLatencyMs: latencyBox.value, usedLLMOutput: true)
    } catch {
        // Short-circuit on cancellation. The outer Task sees
        // Task.isCancelled === true and skips applyResult, but
        // before that check fires the catch block here would
        // otherwise re-show the overlay with the fallback text and
        // race against cancel()'s closeAndReset → hide(). Returning
        // an empty outcome here keeps the overlay hidden and lets
        // the outer guard handle the rest.
        if error is CancellationError || Task.isCancelled {
            return CleanupOutcome(text: fallback, failureMessage: nil)
        }
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
        if useOverlay, shouldRenderToOverlay() {
            overlay.show(state: .cleaning, text: fallback)
        }
        let reauthable = (error as? LLMError).map { llm.cleanupFailureIsReauthable(for: $0) } ?? false
        return CleanupOutcome(text: fallback, failureMessage: failureMessage, reauthable: reauthable)
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
/// Surfaces past the retry loop when EVERY attempt stalled — wrapped in
/// LLMError.requestFailed so the existing failure path renders it.
private struct TTFTTimeoutError: Error, CustomStringConvertible {
    let attempts: Int
    var description: String {
        "cleanup produced no response after \(attempts) attempts — the provider may be slow or unreachable"
    }
}

/// Thrown by the TTFT watchdog when an LLM stream produced no first
/// token within its deadline (task #53) — caught by the retry loop in
/// streamCleanupOrRefine, never surfaces past it.
private struct TTFTStallError: Error {}

private final class AssembledTextBox: @unchecked Sendable {
    // NSLock guard (review finding): historically single-queue
    // (URLSession delivery wrote, post-stream code read after
    // completion), but the TTFT watchdog now reads `value` from a
    // concurrent task WHILE the stream may be writing — an actual
    // data race without synchronization. Lock is per-chunk and cheap.
    private let lock = NSLock()
    private var _value: String = ""
    func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        _value.append(chunk)
    }
    /// Appends and reports whether this was the FIRST content for the
    /// stream — the raw-first display uses it to replace the
    /// provisional text instead of appending to it (task #53).
    func appendReturningWasFirst(_ chunk: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasFirst = _value.isEmpty
        _value.append(chunk)
        return wasFirst
    }
    var value: String {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}

/// Reference-typed holder for the LLM stream's total latency in
/// milliseconds. Populated in the `.done(let summary)` case of the
/// streaming callback (which runs sequentially on URLSession's
/// stream-handling queue) and read once after the stream
/// completes. 0.14.0 PR 4 (#219) wires this into the
/// TranscriptEntry written at accept() time for the Stats section.
/// Same serial-access pattern as AssembledTextBox.
private final class LatencyBox: @unchecked Sendable {
    private var _value: Int?
    func set(_ ms: Int) { _value = ms }
    var value: Int? { _value }
}
