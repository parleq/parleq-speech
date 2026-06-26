// LocalASR — in-process FluidAudio batch ASR (Parakeet TDT v3 on the
// Apple Neural Engine) plus optional CTC vocabulary rescoring.
//
// Replaces the bundled HTTP sidecar that previously fronted these
// same FluidAudio APIs over `http://127.0.0.1:8767/inference`. The
// motivation for the in-process consolidation:
//   - No local listening socket → no compliance-review surface for a
//     bound port and no need for a bearer-token negotiation between
//     two halves of the same install.
//   - App and ASR share fate. A FluidAudio crash takes the menu-bar
//     process down (visible failure) instead of leaving it alive with
//     a black-hole sidecar. Likewise the user never sees a stale
//     supervisor + orphan-sidecar mismatch after a hard crash.
//   - One codesigning target, one Hardened Runtime configuration, no
//     second SwiftPM build step inside `scripts/make-app.sh`.
//
// Trade-off: model RAM (~1.5 GB resident after first inference) lives
// in the main process for the app's lifetime. `reset()` unloads and
// reloads when the user invokes the Settings → Advanced → "Reset
// speech model" button (moved from the menu bar in 0.13.0, #214) —
// same recovery UX the old "Restart Sidecar" item provided.
//
// Lifecycle:
//   1. `start()` kicks off model download + load in a background
//      Task. Returns immediately; the load takes 30-60s on first run
//      (downloading ~150 MB) and 1-2s on subsequent launches.
//   2. `isReady` flips to true once the TDT model finishes loading.
//      `onReadyChanged` fires on transitions (wired to AppState gating
//      and the menu-bar status icon).
//   3. `transcribe(wav:vocabulary:)` accepts the same WAV bytes the
//      old HTTP sidecar did (scans for RIFF, decodes to Float32
//      samples) and returns the transcript. Vocabulary entries
//      trigger an extra CTC keyword-spotting + rescoring pass.
//   4. `reset()` drops the models, flips `isReady` to false, and
//      reloads. Useful when FluidAudio gets into a degraded state
//      (the long-running-session symptom the retired sidecar's
//      "Restart Sidecar" menu item recovered from).
//
// External-endpoint coexistence: when the user has configured a
// custom `asr.endpoint` (Sherpa-ONNX, faster-whisper, etc.),
// `LocalASR` is never constructed — `ASRClient` falls through to its
// HTTP code path and the FluidAudio models are never loaded, saving
// the ~1.5 GB resident cost.

@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Parleq-side snapshot of the in-progress FluidAudio model load.
/// Mirrors `DownloadUtils.DownloadProgress` but kept as our own
/// type so UI code (the overlay, future menu-bar tooltip work)
/// doesn't have to import the FluidAudio module just to read a
/// fraction-complete value. `Equatable` so `LocalASR.downloadProgress`
/// can suppress redundant didSet callbacks when FluidAudio re-emits
/// the same snapshot (which it does — the progress stream isn't
/// strictly monotonic, especially around phase transitions).
public struct ASRDownloadProgress: Sendable, Equatable {
    /// Overall completion fraction in [0, 1]. May regress at phase
    /// transitions (FluidAudio resets the fraction when moving from
    /// listing → downloading → compiling). The overlay clamps it for
    /// display.
    public let fraction: Double
    /// Human-readable label for the current phase. Already includes
    /// any per-phase detail FluidAudio carries (e.g. "Downloading
    /// speech model (3 of 7)…" or "Compiling joint-decoder.mlmodelc…")
    /// so the UI can render it as-is without further branching.
    public let phaseLabel: String
}

@MainActor
public final class LocalASR {
    public init() {}

    /// True once the TDT model has finished loading. Hotkey presses
    /// while false surface the "Initializing…" overlay instead of
    /// starting a capture against an unloaded model. Flips back to
    /// false during `reset()`.
    public private(set) var isReady = false {
        didSet {
            if oldValue != isReady { onReadyChanged?(isReady) }
        }
    }

    /// Set to true when the model load failed for a non-transient
    /// reason (network down at first run, disk full, sandbox denial,
    /// upstream Hugging Face 5xx, etc.) and a single auto-retry also
    /// failed. The menu bar surfaces this via tooltip so the user
    /// knows to open Settings → Advanced → "Reset speech model" to
    /// retry — without this signal the menu bar would sit at
    /// "Initializing speech model…" forever.
    public private(set) var loadFailed = false {
        didSet {
            if oldValue != loadFailed { onLoadFailedChanged?(loadFailed) }
        }
    }

    /// Fires on every `isReady` transition. The menu bar uses this
    /// to swap between the "Initializing…" glyph and the brand bars;
    /// AppState uses it to dismiss any stale init overlay.
    public var onReadyChanged: (@MainActor (Bool) -> Void)?

    /// Fires when `loadFailed` flips in either direction. The menu
    /// bar uses this to surface a load-failure tooltip / error glyph
    /// distinct from the (transient) "Initializing…" state.
    public var onLoadFailedChanged: (@MainActor (Bool) -> Void)?

    /// Latest progress snapshot from the in-flight TDT model
    /// download / compile. `nil` when no load is running (idle, or
    /// already-loaded steady state). Set by the FluidAudio progress
    /// handler that `start()` plumbs through to
    /// `AsrModels.downloadAndLoad(progressHandler:)`. The overlay
    /// reads the latest snapshot when surfacing the
    /// "Initializing speech model…" UI in response to a hotkey
    /// press during model load.
    public private(set) var downloadProgress: ASRDownloadProgress? {
        didSet {
            if oldValue != downloadProgress {
                onProgressChanged?(downloadProgress)
            }
        }
    }

    /// Fires on every `downloadProgress` change. The overlay listens
    /// for this so the progress bar shown during a "user pressed
    /// hotkey before init finished" event re-renders as new bytes
    /// arrive, rather than freezing at whatever fraction it captured
    /// at first show.
    public var onProgressChanged: (@MainActor (ASRDownloadProgress?) -> Void)?

    /// When true, the CTC vocabulary-boosting models are downloaded
    /// and loaded eagerly alongside the TDT model so the first
    /// dictation with custom dictionary entries doesn't pay the
    /// ~97 MB CTC download / load latency. Wired from
    /// `config.customDictionary.isEmpty == false` at app launch.
    public var preloadVocab = false

    private let asr = AsrBox()
    private let vocab = VocabBox()

    /// Kick off model download + load. Idempotent — repeat calls
    /// while already loaded are no-ops; while loading, calls dedupe
    /// to the in-flight task.
    public func start() {
        guard !isReady, loadTask == nil else { return }
        loadFailed = false
        downloadProgress = nil
        let preload = preloadVocab
        // Capture the generation at task launch. `reset()` bumps the
        // generation synchronously before its async unload Task is
        // scheduled, so any prior load task's queued MainActor
        // continuation that runs after reset() will see a mismatch
        // and skip its mutations. Tasks are value types so we can't
        // use `===` for identity — a monotonic counter is simpler
        // than boxing the Task.
        let myGeneration = loadGeneration
        // Forward progress updates from FluidAudio's `progressHandler`
        // (called on an unspecified queue) to MainActor. The
        // generation check inside the MainActor hop is the same
        // guard the success/failure paths use — a late-completing
        // cancelled load shouldn't shove stale progress at the UI.
        let progressSink: @Sendable @MainActor (ASRDownloadProgress) -> Void = { [weak self] snapshot in
            guard let self, self.loadGeneration == myGeneration else { return }
            self.downloadProgress = snapshot
        }
        loadTask = Task { [asr, vocab, weak self] in
            do {
                try await asr.loadModels(progress: progressSink)
            } catch {
                if Task.isCancelled { return }
                logStderr("[parleq] LocalASR: model load failed: \(error)")
                // One-shot auto-retry ~10s after a first-load
                // failure. Approximates what the retired
                // SidecarSupervisor's exponential-backoff gave us
                // for the load-failure case specifically: transient
                // network blips at first run usually clear within a
                // few seconds, and the user shouldn't have to dig
                // into Settings to discover the recovery button for
                // those.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                do {
                    try await asr.loadModels(progress: progressSink)
                } catch {
                    if Task.isCancelled { return }
                    logStderr("[parleq] LocalASR: model load retry failed: \(error). Open Settings → Advanced and click “Reset speech model” to try again once the underlying issue is resolved.")
                    await MainActor.run {
                        guard let self, self.loadGeneration == myGeneration else { return }
                        self.loadFailed = true
                        self.loadTask = nil
                        self.downloadProgress = nil
                    }
                    return
                }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.loadGeneration == myGeneration else { return }
                self.isReady = true
                self.loadTask = nil
                self.downloadProgress = nil
            }
            if preload {
                // Detached so the TDT-ready signal isn't gated on the
                // CTC download. Vocabulary requests will block on
                // this if it hasn't finished yet; plain requests
                // never touch it.
                Task.detached {
                    do {
                        try await vocab.ensureLoaded()
                    } catch {
                        logStderr("[parleq] LocalASR: CTC pre-load failed: \(error). Vocabulary boosting will load lazily on first request.")
                    }
                }
            }
        }
    }

    /// Drop the loaded models and reload them. Replaces the retired
    /// "Restart Sidecar" recovery path. UI gates capture on
    /// `isReady`, which flips off here and back on after reload.
    ///
    /// Safe to call mid-load. We bump `loadGeneration` synchronously
    /// here — not inside the spawned unload task — so any MainActor
    /// continuation already queued by the in-flight load task sees a
    /// mismatched generation when it runs. The MainActor's FIFO
    /// continuation order means a late-completing load that passed
    /// its `if Task.isCancelled` check before reset() ran will still
    /// have its `MainActor.run { ... }` block sandwiched between
    /// `loadGeneration &+= 1` and the spawned unload Task — the
    /// generation check inside that block then no-ops correctly,
    /// avoiding the `isReady=true` over `manager=nil` race the prior
    /// commit (e87b6da) didn't fully close.
    public func reset() {
        guard isReady || loadFailed || loadTask != nil else { return }
        loadGeneration &+= 1
        isReady = false
        loadFailed = false
        downloadProgress = nil
        loadTask?.cancel()
        loadTask = nil
        Task { [asr, vocab, weak self] in
            await asr.unload()
            await vocab.unload()
            await MainActor.run { self?.start() }
        }
    }

    /// Same wire contract as the retired sidecar's `/inference`:
    /// accepts a 16 kHz mono 16-bit WAV buffer (the format
    /// `AudioRecorder` emits), scans for the RIFF header, decodes
    /// to Float32 samples, runs Parakeet TDT v3, and optionally
    /// rescores against the user's custom dictionary.
    ///
    /// Throws `ASRError.notReady` if called before `isReady` flips
    /// true; callers should gate via `AppState.isSystemReady` so
    /// this path is never exercised from real dictation flow.
    public func transcribe(
        wav data: Data,
        vocabulary: [VocabularyEntry]
    ) async throws -> (text: String, diagnostics: ASRDiagnostics) {
        guard let wavStart = Self.findRIFFOffset(in: data) else {
            throw ASRError.malformedAudio
        }
        // WAV total length = 8 + chunkSize (chunkSize at offset 4-8).
        guard wavStart + 12 <= data.count else {
            throw ASRError.malformedAudio
        }
        // WAV chunk size is little-endian by spec. Apple Silicon
        // and Intel macOS happen to also be little-endian so a raw
        // `load(as: UInt32.self)` would produce the right number,
        // but the explicit `littleEndian:` initializer documents the
        // intent and makes any future port safe.
        let chunkSize = data
            .subdata(in: (wavStart + 4)..<(wavStart + 8))
            .withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        let wavEnd = min(wavStart + 8 + Int(chunkSize), data.count)
        let wavBytes = data.subdata(in: wavStart..<wavEnd)
        guard let samples = Self.wavToFloatSamples(wavBytes) else {
            throw ASRError.malformedAudio
        }

        let asrResult = try await asr.transcribeFull(samples: samples)
        var finalText = asrResult.text
        // Rescorer replacements (considered + applied), captured for the
        // armed flywheel corpus only — see makeDiagnostics. Empty unless a
        // vocab-bearing rescore ran and returned a result.
        var vocabReplacements: [VocabReplacement] = []

        if !vocabulary.isEmpty,
           let timings = asrResult.tokenTimings,
           !timings.isEmpty {
            do {
                let rescored = try await vocab.rescore(
                    samples: samples,
                    transcript: asrResult.text,
                    tokenTimings: timings,
                    entries: vocabulary
                )
                if let rescored {
                    if rescored.wasModified {
                        finalText = rescored.text
                        let applied = rescored.replacements.filter { $0.shouldReplace }
                        // Compliance #17: count-only by default — the per-
                        // replacement detail contains user-utterance fragments
                        // (the original word that got replaced) and is gated
                        // behind PARLEQ_VOCAB_TRACE=1 for development. The
                        // retired sidecar exposed the same env var; mirror
                        // the contract so dev workflows continue to work.
                        let traceVocab = ProcessInfo.processInfo.environment["PARLEQ_VOCAB_TRACE"] == "1"
                        if traceVocab {
                            for r in applied {
                                let to = r.replacementWord ?? "<nil>"
                                logStderr("[parleq] LocalASR vocab replaced '\(r.originalWord)' → '\(to)' [\(r.reason)]")
                            }
                        } else {
                            logStderr("[parleq] LocalASR vocab applied \(applied.count) replacement(s)")
                        }
                    }
                    // Capture ALL rescorer replacements (considered + applied)
                    // for the flywheel corpus. This is NOT logged — the
                    // count-only contract above is unchanged; the detail goes
                    // solely into the armed-mode contribution record on disk.
                    vocabReplacements = rescored.replacements.map {
                        VocabReplacement(
                            original: $0.originalWord,
                            replacement: $0.replacementWord,
                            reason: $0.reason,
                            applied: $0.shouldReplace
                        )
                    }
                }
            } catch {
                // Vocabulary boosting is best-effort. A CTC load failure
                // or rescoring error must NOT lose the user's
                // transcription — log and fall through with unrescored
                // text.
                logStderr("[parleq] LocalASR vocab rescore failed (returning unrescored text): \(error)")
            }
        }

        let diagnostics = ASRDiagnostics(
            confidence: asrResult.confidence,
            durationSec: asrResult.duration,
            processingSec: asrResult.processingTime,
            tokenTimings: (asrResult.tokenTimings ?? []).map {
                ASRTokenTiming(
                    token: $0.token,
                    tokenId: $0.tokenId,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    confidence: $0.confidence
                )
            },
            replacements: vocabReplacements,
            // nil unless the voiceprint demo armed encoder-feature capture
            // (PARLEQ_VOICEPRINT_DEMO=1). Excluded from Codable, so it never
            // reaches the on-disk flywheel record.
            encoderFeatures: asrResult.encoderFeatures
        )
        return (finalText, diagnostics)
    }

    /// Voice-enrollment demo only (PARLEQ_VOICEPRINT_DEMO=1): transcribe a raw
    /// 16 kHz mono 16-bit WAV buffer and return FluidAudio's full `ASRResult`,
    /// including `encoderFeatures` (capture is armed at model-load time when the
    /// demo env var is set). Bypasses the CTC vocab rescorer — enrollment needs
    /// only the token timings + encoder features, not the cleaned transcript.
    /// Returns nil for a malformed WAV. Not used on the normal dictation path.
    public func transcribeRawForVoiceprint(wav data: Data) async throws -> ASRResult? {
        guard let wavStart = Self.findRIFFOffset(in: data),
              wavStart + 12 <= data.count else {
            return nil
        }
        let chunkSize = data
            .subdata(in: (wavStart + 4)..<(wavStart + 8))
            .withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        let wavEnd = min(wavStart + 8 + Int(chunkSize), data.count)
        let wavBytes = data.subdata(in: wavStart..<wavEnd)
        guard let samples = Self.wavToFloatSamples(wavBytes) else { return nil }
        return try await asr.transcribeFull(samples: samples)
    }

    /// In-flight model-load task. Nil when no load is running. Used
    /// so a `reset()` mid-load can cancel the prior task cleanly
    /// before kicking off a replacement.
    private var loadTask: Task<Void, Never>?

    /// Monotonically-increasing generation tag. Each `start()` bumps
    /// it; the in-flight task captures the value at launch and
    /// compares before mutating state on the MainActor. A `reset()`
    /// → `start()` cycle while the original load is mid-flight bumps
    /// the generation; the original task's late completion sees the
    /// mismatch and skips its mutations, avoiding the
    /// `isReady=true` over `manager=nil` race the code review
    /// flagged. `&+=` is wrap-on-overflow which is fine here — we
    /// only ever check equality with the captured value.
    private var loadGeneration: UInt64 = 0

    // MARK: - WAV decoding

    /// Read a 16-bit mono 16 kHz WAV body and return Float32 samples
    /// in [-1.0, 1.0]. Strips the 44-byte WAV header. WAV samples
    /// are little-endian by spec; we decode via `Int16(littleEndian:)`
    /// rather than a raw `load` so the byte-order intent is explicit
    /// (same reasoning as the chunkSize decode in `transcribe`).
    public static func wavToFloatSamples(_ data: Data) -> [Float]? {
        guard data.count > 44 else { return nil }
        let pcm = data.dropFirst(44)
        let count = pcm.count / 2
        var samples = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let ints = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                samples[i] = Float(Int16(littleEndian: ints[i])) / 32768.0
            }
        }
        return samples
    }

    /// Locate the "RIFF" + "WAVE" magic. Lifted from the retired
    /// sidecar — `AudioRecorder` always emits a RIFF-prefixed buffer
    /// today, but the scan keeps us robust to any future multipart
    /// wrapping a third-party endpoint might require.
    public static func findRIFFOffset(in data: Data) -> Int? {
        let needle: [UInt8] = [0x52, 0x49, 0x46, 0x46] // "RIFF"
        if data.count < 12 { return nil }
        for i in 0..<(data.count - 11) {
            if data[i] == needle[0]
                && data[i + 1] == needle[1]
                && data[i + 2] == needle[2]
                && data[i + 3] == needle[3] {
                // Verify "WAVE" at offset 8.
                if data[i + 8] == 0x57
                    && data[i + 9] == 0x41
                    && data[i + 10] == 0x56
                    && data[i + 11] == 0x45 {
                    return i
                }
            }
        }
        return nil
    }
}

// MARK: - Actor boxes for the FluidAudio managers

/// Owns the Parakeet TDT v3 batch transcription pipeline. Lives in
/// an `actor` so concurrent transcribe calls (a rare overlap during
/// rapid hotkey-tap retries) serialize cleanly without explicit
/// locking — FluidAudio's `AsrManager.transcribe` is not safe to
/// call concurrently with the same decoder state.
actor AsrBox {
    private var manager: AsrManager?

    /// Idempotent. First call downloads + loads Parakeet TDT v3
    /// (~150 MB cached afterwards). Subsequent calls return
    /// immediately.
    ///
    /// The optional `progress` callback receives per-phase snapshots
    /// from FluidAudio's `DownloadUtils.ProgressHandler` — listing
    /// files, downloading them, and compiling the CoreML models. The
    /// callback is required to be MainActor-isolated; FluidAudio
    /// invokes its handler on an unspecified queue, and we hop to
    /// MainActor inside the adapter so callers see ordered updates.
    public func loadModels(
        progress: @MainActor @Sendable @escaping (ASRDownloadProgress) -> Void
    ) async throws {
        if manager != nil { return }
        let handler: DownloadUtils.ProgressHandler = { snapshot in
            let adapted = ASRDownloadProgress(
                fraction: snapshot.fractionCompleted,
                phaseLabel: Self.phaseLabel(for: snapshot.phase)
            )
            // FluidAudio invokes the handler synchronously on
            // whatever queue is doing the download work. We need to
            // get onto MainActor, and we need ordered delivery —
            // an `Task { @MainActor in … }` per callback creates
            // sibling unstructured tasks whose execution order
            // against each other is not FIFO, so a later snapshot
            // could land first and the UI would briefly regress its
            // fraction. `DispatchQueue.main.async` is FIFO from a
            // single producer thread, which is what FluidAudio gives
            // us, so progress snapshots arrive on MainActor in the
            // same order they were emitted.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { progress(adapted) }
            }
        }
        let models = try await AsrModels.downloadAndLoad(
            version: .v3,
            progressHandler: handler
        )
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        // Voice-enrollment acoustic disambiguation. Ask FluidAudio to copy the
        // Parakeet encoder's acoustic features out of each transcribe call so a
        // pooled per-word embedding can be derived — needed by the enrollment
        // wizard and the live acoustic gate. The retained sequence is transient
        // (~0.8 MB, freed at end of utterance) and excluded from any on-disk
        // record. Armed always in the Concord build (the only one with the
        // enrollment feature); in the public build it stays behind the demo flag.
        #if Concord
        await m.setCaptureEncoderFeatures(true)
        #else
        if VoiceprintDemo.isEnabled {
            await m.setCaptureEncoderFeatures(true)
        }
        #endif
        self.manager = m
    }

    /// Human-readable label for the current FluidAudio phase,
    /// suitable for surfacing directly to the user in the
    /// initialization overlay.
    private static func phaseLabel(for phase: DownloadUtils.DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "Listing model files…"
        case .downloading(let completed, let total):
            // FluidAudio reports per-file granularity (not per-byte).
            // Showing "3 of 7" gives the user a meaningful sense of
            // progress without falsely implying we have a byte-level
            // counter. Guard total > 0 against the brief window
            // before counts settle, where FluidAudio can emit
            // `.downloading(0, 0)` — "Downloading speech model
            // (0 of 0)…" reads as a bug to the user.
            if total > 0 {
                return "Downloading speech model (\(completed) of \(total))…"
            }
            return "Downloading speech model…"
        case .compiling(let modelName):
            return "Compiling \(modelName)…"
        }
    }

    /// Drop the manager so the next `loadModels()` call rebuilds
    /// from disk. Used by `LocalASR.reset()` when the user wants to
    /// recover from a degraded state.
    public func unload() async {
        manager = nil
    }

    /// One-shot batch transcription. Fresh decoder state per call —
    /// state doesn't carry across batch utterances.
    public func transcribeFull(samples: [Float]) async throws -> ASRResult {
        guard let manager else { throw ASRError.notReady }
        var state = try TdtDecoderState()
        return try await manager.transcribe(samples, decoderState: &state)
    }
}

// MARK: - File-private logging

/// Mirrors the per-file-private `logStderr` pattern used in
/// `AudioRecorder.swift`, `ParleqApp.swift`, and `Permissions.swift`.
/// Same `[parleq]` prefix for grep parity across the combined log.
private func logStderr(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

/// Tuning knobs for the CTC vocabulary rescorer. Lifted verbatim
/// from the retired sidecar so behavior is identical post-cutover.
///
/// FluidAudio's defaults are tuned for the dictation-with-known-
/// terminology shape (medical, legal, brand names) where vocabulary
/// terms are distinctive and false positives on common English are
/// rare. Parleq's audience often has shorter, English-rhyming terms
/// in their dictionary (e.g. "ultrathink" rhymes with "everything"
/// at the /θɪŋk/ tail; default 0.50 similarity floor + 3.0 CBW boost
/// is enough to flip "everything" → "ultrathink"). These tighter
/// values reject low-similarity candidates earlier and require
/// stronger acoustic evidence to override the original transcript.
///
/// If you find legit corrections being missed, lower minSimilarity
/// toward 0.65. If you find new false positives, lower cbw toward
/// 1.5 or raise minSimilarity toward 0.80.
///
/// 0.75 chosen from an ROC sweep over a 566-clip corpus of real FluidAudio
/// output: vs the old 0.65 it cuts vocab over-fires ~3x (the class where a
/// short, common English word wrongly snaps to a dictionary term) for only a
/// small recovery cost — min-similarity is the dominant knob (cbw/margin
/// barely move the ratio). Re-validated on the current rescorer (over-fires
/// 36->12 at the same recovery). Measured single-speaker.
enum VocabTuning {
    public static let minSimilarity: Float = 0.75
    public static let cbw: Float = 2.0
}

/// Identifiers for the bundled ASR engine, stamped into flywheel
/// contribution records so a later re-run knows the baseline it is
/// comparing against. KEEP `fluidAudioVersion` IN SYNC with the
/// FluidAudio pin in `Package.swift` (see the dependency-upgrade policy
/// in CLAUDE.md and the parleq-fluidaudio pin notes) on every bump.
public enum BundledASREngine {
    public static let model = "parakeet-tdt-v3"
    // Matches the FluidAudio pin in Package.swift (the encoder-features fork tag).
    // ALSO the model-version stamp on voiceprint templates — a change here
    // invalidates persisted voiceprints (they're pruned on load + re-enrolled),
    // which is correct: the encoder that produced their embeddings changed.
    public static let fluidAudioVersion = "0.15.4-encoder.1"
}

/// Holds the optional CTC vocabulary-boosting models and rescorer.
/// Lazy-loaded on first vocab-bearing request (or eagerly preloaded
/// via `LocalASR.preloadVocab = true`). Caches the rescorer per
/// dictionary content so repeat dictations with the same vocabulary
/// don't re-tokenize on every call.
actor VocabBox {
    private var ctcModels: CtcModels?
    private var spotter: CtcKeywordSpotter?
    private var ctcTokenizer: CtcTokenizer?
    private var ctcModelDirectory: URL?

    private var cachedTermsKey: String?
    private var cachedVocabulary: CustomVocabularyContext?
    private var cachedRescorer: VocabularyRescorer?

    /// Make sure the CTC encoder, tokenizer, and spotter are loaded.
    /// First call downloads ~97 MB of model weight (cached on disk
    /// afterwards). Subsequent calls are no-ops.
    public func ensureLoaded() async throws {
        if spotter != nil { return }
        let variant: CtcModelVariant = .ctc110m
        let models = try await CtcModels.downloadAndLoad(variant: variant)
        let tokenizer = try await CtcTokenizer.load(
            from: CtcModels.defaultCacheDirectory(for: variant)
        )
        self.ctcModels = models
        self.ctcTokenizer = tokenizer
        self.ctcModelDirectory = CtcModels.defaultCacheDirectory(for: variant)
        self.spotter = CtcKeywordSpotter(
            models: models,
            blankId: ContextBiasingConstants.defaultBlankId
        )
    }

    /// Drop the loaded CTC models. Used by `LocalASR.reset()`.
    public func unload() async {
        ctcModels = nil
        spotter = nil
        ctcTokenizer = nil
        ctcModelDirectory = nil
        cachedTermsKey = nil
        cachedVocabulary = nil
        cachedRescorer = nil
    }

    /// Run the spot + rescore passes for this audio against the
    /// given vocabulary entries. Aliases are forwarded to
    /// `CustomVocabularyTerm.aliases` so the rescorer emits the
    /// canonical text when an alias matches the audio. Returns nil
    /// when there's nothing to do (no terms after tokenization).
    public func rescore(
        samples: [Float],
        transcript: String,
        tokenTimings: [TokenTiming],
        entries: [VocabularyEntry]
    ) async throws -> VocabularyRescorer.RescoreOutput? {
        try await ensureLoaded()
        guard let spotter, let ctcTokenizer else { return nil }

        let cleanedEntries: [VocabularyEntry] = entries.compactMap { entry in
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            let aliases = entry.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return VocabularyEntry(term: term, aliases: aliases)
        }
        guard !cleanedEntries.isEmpty else { return nil }

        // Cache key includes aliases so toggling aliases for an
        // existing term forces a rebuild of the rescorer.
        let key = cleanedEntries
            .map { "\($0.term)\u{1F}\($0.aliases.joined(separator: "\u{1E}"))" }
            .joined(separator: "\n")
        let vocabulary: CustomVocabularyContext
        let rescorer: VocabularyRescorer
        if key == cachedTermsKey,
           let cachedVocabulary,
           let cachedRescorer {
            vocabulary = cachedVocabulary
            rescorer = cachedRescorer
        } else {
            let tokenized: [CustomVocabularyTerm] = cleanedEntries.compactMap { entry in
                let ids = ctcTokenizer.encode(entry.term)
                guard !ids.isEmpty else { return nil }
                let aliases: [String]? = entry.aliases.isEmpty ? nil : entry.aliases
                return CustomVocabularyTerm(
                    text: entry.term,
                    weight: nil,
                    aliases: aliases,
                    tokenIds: nil,
                    ctcTokenIds: ids
                )
            }
            guard !tokenized.isEmpty else { return nil }
            vocabulary = CustomVocabularyContext(
                terms: tokenized,
                minSimilarity: VocabTuning.minSimilarity
            )
            rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: vocabulary,
                // FluidAudio 0.15.x reintroduced the #634 spotter-anchored acoustic rescue
                // (default on), which over-fires on short keywords (#702). Disable it to
                // reproduce the pre-#634 / 0.14.5 over-fire behavior we validated and pinned
                // (parleq-fluidaudio-0.14.5-pin). minSimilarity (0.75) remains the recall knob.
                config: VocabularyRescorer.Config(spotterRescueEnabled: false),
                ctcModelDirectory: ctcModelDirectory
            )
            cachedTermsKey = key
            cachedVocabulary = vocabulary
            cachedRescorer = rescorer
        }

        let spotted = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: samples,
            customVocabulary: vocabulary
        )
        guard !spotted.logProbs.isEmpty else { return nil }
        return rescorer.ctcTokenRescore(
            transcript: transcript,
            tokenTimings: tokenTimings,
            logProbs: spotted.logProbs,
            frameDuration: spotted.frameDuration,
            cbw: VocabTuning.cbw,
            minSimilarity: VocabTuning.minSimilarity
        )
    }
}
