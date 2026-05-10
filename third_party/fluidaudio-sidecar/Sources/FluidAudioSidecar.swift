// fluidaudio-sidecar — minimal HTTP server that wraps FluidAudio's
// Parakeet TDT v3 ASR for Parleq.app's bundled local ASR path.
//
// On startup: downloads (first run only) and loads Parakeet TDT v3.
// The previous build also loaded Parakeet EOU 120M streaming and
// Nemotron 0.6B streaming, but those models were unsuitable for
// free-form dictation (end-of-utterance truncation) and Parleq
// committed to batch /inference. Trimming to a single model cut
// resident memory from ~5 GB to ~1.5 GB.
//
//   GET /health
//     → {"status": "ok"} once the model is loaded.
//
//   POST /inference
//     Body: a 16-bit mono 16 kHz WAV file. Either as a multipart-form
//     "file" field (what the Go benchmark harness sends) or as the
//     raw WAV bytes (what Parleq.app's Swift ASRClient sends — the
//     server scans the body for the "RIFF" header and accepts either
//     framing).
//     → {"text": "..."}
//
// Default port 8767 (set via FLUIDAUDIO_PORT env var).

@preconcurrency import AVFoundation
import Foundation
import FluidAudio
import HTTPTypes
import Hummingbird
import HummingbirdCore

// Read the WAV body and return Float samples at 16 kHz mono. FluidAudio
// expects Float32 samples; we strip the 44-byte WAV header and convert
// from int16 to Float in [-1.0, 1.0].
func wavToFloatSamples(_ data: Data) -> [Float]? {
    guard data.count > 44 else { return nil }
    let pcm = data.dropFirst(44)
    let count = pcm.count / 2
    var samples = [Float](repeating: 0, count: count)
    pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let ints = raw.bindMemory(to: Int16.self)
        for i in 0..<count {
            samples[i] = Float(ints[i]) / 32768.0
        }
    }
    return samples
}

@main
struct FluidAudioSidecar {
    static func main() async throws {
        // Watch the supervisor process (Parleq.app) for unexpected
        // exit. If Parleq crashes without going through its
        // applicationWillTerminate clean-up, the supervised sidecar
        // would otherwise stay alive holding port 8767 — and on
        // the next Parleq launch a *new* supervisor would mint a
        // fresh bearer token while the orphan still holds the
        // socket bound, leading to a confusing ASR 401 mismatch
        // (new token vs. old sidecar). The watcher self-terminates
        // this process when the parent exits for any reason
        // (clean quit, SIGKILL, SIGTRAP, etc.) so the next launch
        // gets a clean port.
        if let pidStr = ProcessInfo.processInfo.environment["PARLEQ_SUPERVISOR_PID"],
           let pid = pid_t(pidStr) {
            startParentExitWatcher(parentPID: pid)
        }
        // Slim build: load ONLY Parakeet TDT v3 (the model Parleq.app
        // actually uses). Earlier builds also loaded Parakeet EOU 120M
        // streaming and Nemotron 0.6B streaming for spike-time
        // experiments. Both proved unsuitable for free-form dictation
        // (end-of-utterance truncation), and Parleq committed to
        // batch /inference via Parakeet TDT v3 + post-pass LLM
        // cleanup. Dropping the unused loads cuts resident memory
        // from ~5 GB to roughly 1.5 GB — meaningful on 8 GB Macs and
        // good for cloud serving too.
        FileHandle.standardError.write("Loading Parakeet TDT v3 (batch)...\n".data(using: .utf8)!)
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asrManager = AsrManager(config: .default)
        try await asrManager.loadModels(models)

        FileHandle.standardError.write("Models loaded.\n".data(using: .utf8)!)

        let asrBox = ASRBox(manager: asrManager)
        let vocabBox = VocabBox()

        // Optional eager pre-load of the CTC vocabulary-boosting
        // models. The supervisor sets PARLEQ_VOCAB_PRELOAD=1 when the
        // user has dictionary entries configured, so first-dictation
        // latency doesn't pay the ~97 MB CTC encoder download/load on
        // demand. Run in the background so the HTTP server starts
        // listening immediately — vocab requests block on this load if
        // it hasn't finished, plain requests don't touch it at all.
        if ProcessInfo.processInfo.environment["PARLEQ_VOCAB_PRELOAD"] == "1" {
            Task.detached {
                FileHandle.standardError.write("Pre-loading CTC vocabulary models...\n".data(using: .utf8)!)
                do {
                    try await vocabBox.ensureLoaded()
                    FileHandle.standardError.write("CTC vocabulary models ready.\n".data(using: .utf8)!)
                } catch {
                    let msg = "WARNING: CTC pre-load failed: \(error). Vocabulary boosting will load lazily on first request.\n"
                    FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
                }
            }
        }

        let port = Int(ProcessInfo.processInfo.environment["FLUIDAUDIO_PORT"] ?? "8767") ?? 8767

        // Bearer-token shared secret with the parent Parleq process.
        // SidecarSupervisor generates a 256-bit random token on app
        // launch and passes it in via this env var; we then require
        // every /inference request to carry it. When unset (e.g.
        // someone running `swift run fluidaudio-sidecar` manually
        // for development), auth is disabled — the localhost
        // endpoint is fully open in dev mode, which is fine for
        // local benchmarking but documented as such. /health stays
        // unauthenticated regardless: it's used by readiness
        // probes that may run before any token negotiation, and it
        // returns no sensitive state.
        let expectedAuth: String? = ProcessInfo.processInfo.environment["PARLEQ_SIDECAR_TOKEN"]
            .flatMap { $0.isEmpty ? nil : "Bearer \($0)" }
        if expectedAuth != nil {
            FileHandle.standardError.write("/inference auth: required (PARLEQ_SIDECAR_TOKEN set)\n".data(using: .utf8)!)
        } else {
            FileHandle.standardError.write("/inference auth: DISABLED (PARLEQ_SIDECAR_TOKEN not set; localhost open)\n".data(using: .utf8)!)
        }
        let authHeaderName = HTTPField.Name("Authorization")!

        let router = Router()
        router.get("/health") { _, _ in
            return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(string: #"{"status":"ok"}"#)))
        }
        router.post("/inference") { request, context -> Response in
            // Bearer-token gate. Sent by ASRClient and by the
            // supervisor's warmup probe; missing or wrong → 401.
            // Skip the check entirely when no expected token is
            // configured (dev mode).
            if let expectedAuth {
                let provided = request.headers[values: authHeaderName].first
                guard provided == expectedAuth else {
                    return Response(
                        status: .unauthorized,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: .init(string: #"{"error":"unauthorized"}"#))
                    )
                }
            }
            // Read entire request body (it's multipart but small — corpus clips
            // are <2 MB each so we collect the whole thing and then locate
            // the WAV bytes by scanning for "RIFF").
            let body = try await request.body.collect(upTo: 50_000_000)
            guard let bytes = body.getBytes(at: 0, length: body.readableBytes) else {
                return Response(status: .badRequest, body: .init(byteBuffer: .init(string: #"{"error":"empty body"}"#)))
            }
            let data = Data(bytes)
            guard let wavStart = findRIFFOffset(in: data) else {
                return Response(status: .badRequest, body: .init(byteBuffer: .init(string: #"{"error":"no WAV body found"}"#)))
            }
            // Find end of WAV by reading chunkSize from header. WAV total
            // length = 8 + chunkSize. chunkSize lives at offset 4-8.
            guard wavStart + 12 <= data.count else {
                return Response(status: .badRequest, body: .init(byteBuffer: .init(string: #"{"error":"truncated WAV"}"#)))
            }
            let chunkSize = data.subdata(in: (wavStart+4)..<(wavStart+8)).withUnsafeBytes { $0.load(as: UInt32.self) }
            let wavEnd = min(wavStart + 8 + Int(chunkSize), data.count)
            let wavBytes = data.subdata(in: wavStart..<wavEnd)

            guard let samples = wavToFloatSamples(wavBytes) else {
                return Response(status: .badRequest, body: .init(byteBuffer: .init(string: #"{"error":"wav parse failed"}"#)))
            }

            // Optional per-request vocabulary biasing. The X-Parleq-Vocabulary
            // header carries a base64-encoded JSON array of `{term, aliases}`
            // entries — when present, we run an extra CTC keyword-spotting +
            // rescoring pass after TDT transcription. Aliases are forwarded
            // to FluidAudio's CustomVocabularyTerm so the rescorer emits the
            // canonical term whenever an alias matches. Empty/missing header
            // skips all of this and the request runs identically to the
            // no-vocab path.
            let vocabHeaderName = HTTPField.Name("X-Parleq-Vocabulary")!
            let vocabularyEntries = parseVocabularyHeader(request.headers[values: vocabHeaderName])

            do {
                let asrResult = try await asrBox.transcribeFull(samples: samples)
                var finalText = asrResult.text

                if !vocabularyEntries.isEmpty,
                   let tokenTimings = asrResult.tokenTimings,
                   !tokenTimings.isEmpty {
                    do {
                        let rescored = try await vocabBox.rescore(
                            samples: samples,
                            transcript: asrResult.text,
                            tokenTimings: tokenTimings,
                            entries: vocabularyEntries
                        )
                        if let rescored, rescored.wasModified {
                            finalText = rescored.text
                            let applied = rescored.replacements.filter { $0.shouldReplace }
                            // Compliance #17: by default emit a
                            // count-only line — the per-replacement
                            // detail contains user-utterance fragments
                            // (the original word that got replaced)
                            // and falls under the "no input data on
                            // disk / in logs" rule for Bedrock-using
                            // apps. Local development can opt back in
                            // via PARLEQ_VOCAB_TRACE=1 to see the
                            // exact CTC-vs-CTC score comparisons that
                            // drove each replacement, useful for
                            // threshold tuning.
                            let traceVocab = ProcessInfo.processInfo.environment["PARLEQ_VOCAB_TRACE"] == "1"
                            if traceVocab {
                                for r in applied {
                                    let to = r.replacementWord ?? "<nil>"
                                    let line = "[vocab] replaced '\(r.originalWord)' → '\(to)' [\(r.reason)]\n"
                                    FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
                                }
                            } else {
                                let line = "[vocab] applied \(applied.count) replacement(s)\n"
                                FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
                            }
                        }
                    } catch {
                        // Vocabulary boosting is best-effort: a CTC load
                        // failure or rescoring error must NOT lose the
                        // user's transcription. Log the error and fall
                        // through with the unrescored text.
                        let msg = "[vocab] rescore failed (returning unrescored text): \(error)\n"
                        FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
                    }
                }

                let payload: [String: Any] = ["text": finalText]
                let json = try JSONSerialization.data(withJSONObject: payload)
                return Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(bytes: [UInt8](json))))
            } catch {
                let msg = "transcribe error: \(error)"
                let payload: [String: String] = ["error": msg]
                let json = try JSONSerialization.data(withJSONObject: payload)
                return Response(status: .internalServerError, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(bytes: [UInt8](json))))
            }
        }

        // Earlier builds also exposed /stream (Parakeet EOU 120M
        // streaming), /stream-nemo (Nemotron 0.6B streaming, SSE
        // partials), and /stream-batch (diagnostic). All three were
        // removed in the slim-down: they relied on streaming models
        // we no longer ship in the bundle, and Parleq's wire format
        // is /inference (batch) for both the bundled-FluidAudio path
        // and the cloud-mode Sherpa-ONNX path. See
        // docs/ARCHITECTURE.md for the current ASR architecture.

        FileHandle.standardError.write("Listening on http://127.0.0.1:\(port)\n".data(using: .utf8)!)
        let app = Application(
            router: router,
            configuration: ApplicationConfiguration(address: .hostname("127.0.0.1", port: port))
        )
        try await app.runService()
    }
}

// Wraps AsrManager so we can pass it through actor-isolated boundaries.
actor ASRBox {
    let manager: AsrManager
    init(manager: AsrManager) { self.manager = manager }
    func transcribe(samples: [Float]) async throws -> String {
        // Fresh decoder state per call — we're doing batch (one-shot) transcription
        // per request, not streaming. State doesn't carry across calls.
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return result.text
    }

    /// Same as `transcribe(samples:)` but returns the full `ASRResult`
    /// so callers can access tokenTimings (used by the vocabulary
    /// rescoring path).
    func transcribeFull(samples: [Float]) async throws -> ASRResult {
        var state = try TdtDecoderState()
        return try await manager.transcribe(samples, decoderState: &state)
    }
}

/// Tuning knobs for the CTC vocabulary rescorer. FluidAudio's
/// defaults are tuned for the dictation-with-known-terminology shape
/// (medical, legal, brand names) where vocabulary terms are
/// distinctive and false positives on common English are rare.
/// Parleq's audience often has shorter, English-rhyming terms in
/// their dictionary (e.g. "ultrathink" rhymes with "everything"
/// at the /θɪŋk/ tail; default 0.50 similarity floor + 3.0 CBW boost
/// is enough to flip "everything" → "ultrathink"). These tighter
/// values reject low-similarity candidates earlier and require
/// stronger acoustic evidence to override the original transcript.
///
/// If you find legit corrections being missed, lower minSimilarity
/// toward 0.55. If you find new false positives, lower cbw toward
/// 1.5 or raise minSimilarity toward 0.70.
enum VocabTuning {
    /// Minimum string similarity (canonical Levenshtein, 1 - dist/maxLen)
    /// before a candidate is even considered for acoustic scoring.
    /// FluidAudio default is 0.50 / 0.52; we use 0.65 to filter out
    /// rhyming-tail matches like everything ↔ ultrathink (sim=0.50).
    static let minSimilarity: Float = 0.65
    /// Context-biasing weight added to the vocabulary candidate's CTC
    /// score before comparing to the original. FluidAudio default is
    /// 3.0; we use 2.0 so the boost can't single-handedly override a
    /// well-recognized common word with a partial-match vocab term.
    static let cbw: Float = 2.0
}

/// Holds the optional CTC vocabulary-boosting models and rescorer.
/// Lazy-loaded on first vocab-bearing request (or eagerly preloaded
/// via PARLEQ_VOCAB_PRELOAD=1). The rescorer is cached per
/// vocabulary content so repeated requests with the same dictionary
/// don't re-tokenize on every call.
actor VocabBox {
    private var ctcModels: CtcModels?
    private var spotter: CtcKeywordSpotter?
    private var ctcTokenizer: CtcTokenizer?
    private var ctcModelDirectory: URL?

    /// Cache of the most recent (terms-key, vocabulary, rescorer)
    /// triple. We rebuild the rescorer when the user changes their
    /// dictionary, but skip the rebuild for repeated requests with
    /// the same terms.
    private var cachedTermsKey: String?
    private var cachedVocabulary: CustomVocabularyContext?
    private var cachedRescorer: VocabularyRescorer?

    /// Make sure the CTC encoder, tokenizer, and spotter are loaded.
    /// First call downloads ~97 MB of model weight on first launch
    /// (cached afterwards). Subsequent calls are no-ops.
    func ensureLoaded() async throws {
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

    /// Run the spot + rescore passes for this audio against the given
    /// vocabulary entries. Each entry carries a canonical term plus
    /// optional aliases — aliases are passed through to FluidAudio's
    /// `CustomVocabularyTerm.aliases` so the rescorer emits the
    /// canonical text when an alias matches the audio. Returns nil
    /// when there's nothing to do (no terms after tokenization).
    /// Caches the rescorer for repeat calls with the same vocabulary.
    func rescore(
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
            // Tokenize each user term with the CTC tokenizer; terms
            // that produce no tokens (e.g. all-symbol input) are
            // dropped silently. Aliases are forwarded as plain
            // strings — FluidAudio uses them for canonical-form
            // emission and normalized similarity matching, both of
            // which operate on the string form, not the CTC token
            // ids.
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
                config: .default,
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

/// One vocabulary entry as carried over the wire. Mirrors the
/// app-side struct of the same name; kept here as a private DTO so
/// the sidecar can decode the header without a shared dependency.
struct VocabularyEntry: Codable, Sendable {
    let term: String
    let aliases: [String]
}

/// Parse the `X-Parleq-Vocabulary` header value(s) into a list of
/// `{term, aliases}` entries. Wire format: base64-encoded JSON array
/// of `{"term": "...", "aliases": [...]}`. Multiple header instances
/// are concatenated. Returns an empty array when nothing is present
/// or decoding fails (the request then runs as if no vocabulary was
/// supplied — best-effort, never blocks the user's transcription).
func parseVocabularyHeader(_ values: [String]) -> [VocabularyEntry] {
    var out: [VocabularyEntry] = []
    for value in values {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { continue }
        guard let data = Data(base64Encoded: raw) else { continue }
        guard let decoded = try? JSONDecoder().decode([VocabularyEntry].self, from: data) else { continue }
        out.append(contentsOf: decoded)
    }
    return out
}

// Locate the start of the WAV body within a multipart-encoded request body.
// The file part begins with "RIFF" + 4 bytes + "WAVE".
func findRIFFOffset(in data: Data) -> Int? {
    let needle: [UInt8] = [0x52, 0x49, 0x46, 0x46] // "RIFF"
    if data.count < 12 { return nil }
    for i in 0..<(data.count - 11) {
        if data[i] == needle[0] && data[i+1] == needle[1] && data[i+2] == needle[2] && data[i+3] == needle[3] {
            // Verify "WAVE" at offset 8
            if data[i+8] == 0x57 && data[i+9] == 0x41 && data[i+10] == 0x56 && data[i+11] == 0x45 {
                return i
            }
        }
    }
    return nil
}

// MARK: - Parent-process exit watcher

/// Spawn a detached background task that uses BSD kqueue's
/// EVFILT_PROC + NOTE_EXIT to wait for the supervisor process
/// (Parleq.app) to die, then self-terminates this sidecar.
///
/// kqueue is the right primitive here because:
///   - It works regardless of how the parent dies (clean exit,
///     SIGKILL, SIGTRAP from a crash, OOM kill, anything). Pipe-
///     EOF approaches only fire if the parent owns a pipe to us
///     and the kernel closes it on death; that's true for stdio
///     pipes, but kqueue doesn't depend on the FD inheritance
///     working correctly across whatever supervisor changes might
///     come later.
///   - It doesn't require us to hold any FD or other resource
///     long-term — we just register interest with the kernel and
///     block on a single 1-element kevent buffer.
///   - It's level-triggered against process state, not signal-
///     based, so we don't have to worry about signal masks or
///     re-entrancy.
///
/// Edge case: if the parent already died before we got here (race
/// during launch), kevent() returns the EXIT event immediately on
/// the first call. We handle that the same as any later exit.
///
/// We deliberately call _exit(0) instead of exit(0) to skip
/// atexit / Swift teardown / Hummingbird's graceful-shutdown
/// machinery. The whole point is that the parent is gone and
/// holding the port one millisecond longer than necessary causes
/// the next-launch 401 mismatch we're trying to prevent.
private func startParentExitWatcher(parentPID: pid_t) {
    let task = Task.detached(priority: .background) {
        let kq = kqueue()
        guard kq >= 0 else {
            FileHandle.standardError.write(
                "[parleq-sidecar] kqueue() failed; parent-exit watcher disabled\n"
                    .data(using: .utf8) ?? Data()
            )
            return
        }
        var change = kevent(
            ident: UInt(parentPID),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: NOTE_EXIT,
            data: 0,
            udata: nil
        )
        var event = kevent()
        // Block until the kernel reports the parent has exited.
        // n == 1 → exit observed; n == 0 → spurious wake (should not
        // happen with EV_ONESHOT but loop just in case); n < 0 → ESRCH
        // typically meaning the parent is already gone, in which case
        // we're done either way.
        while true {
            let n = withUnsafePointer(to: &change) { changePtr in
                withUnsafeMutablePointer(to: &event) { eventPtr in
                    kevent(kq, changePtr, 1, eventPtr, 1, nil)
                }
            }
            if n != 0 { break }
        }
        FileHandle.standardError.write(
            "[parleq-sidecar] supervisor pid \(parentPID) exited; self-terminating\n"
                .data(using: .utf8) ?? Data()
        )
        // _exit (not exit) — skip atexit + Swift / Hummingbird
        // teardown. Holding the port 8767 socket bound for any
        // longer than necessary is exactly the failure mode we
        // exist to prevent.
        _exit(0)
    }
    // The task runs forever (until _exit kills the process); we
    // intentionally don't store it anywhere. Suppress the unused-
    // warning by binding to _.
    _ = task
}
