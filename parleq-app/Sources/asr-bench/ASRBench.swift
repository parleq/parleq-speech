// asr-bench — a standalone benchmark CLI that runs Parleq's on-device
// ASR (FluidAudio Parakeet) over a fixture corpus and emits per-clip
// transcripts + latency, for offline WER/latency comparison.
//
// This is DEV TOOLING. It is a separate SwiftPM product (`asr-bench`),
// never bundled into the app, and depends ONLY on FluidAudio (not
// ParleqAppCore) so a build doesn't drag in MLX/Soto — keeping the
// build fast across the version-bump cycles this benchmark needs.
//
// The batch path mirrors `ParleqAppCore/LocalASR.swift` (AsrModels v3
// → AsrManager → transcribe with a fresh TdtDecoderState per clip);
// the WAV→samples step uses AVFoundation instead of LocalASR's hand-
// rolled 44-byte-header reader because the fixtures come from macOS
// `say`, whose WAVE writes a non-standard data offset.
//
// Streaming paths (eou / nemotron) and the vocab-biasing arm are added
// in Phase 3 once the FluidAudio 0.15.x streaming API is in tree.

import AVFoundation
import CoreML
import FluidAudio
import Foundation

// MARK: - Manifest / result models

struct Manifest: Decodable {
    let clips: [Clip]
}

struct Clip: Decodable {
    let id: String
    let reference_transcript: String
    let file: String
    let terms: [String]?
}

struct ResultRow: Encodable {
    let id: String
    let path: String
    let ref: String
    let hyp: String
    var latency_ms: Double?
    var post_release_ms: Double?
    var first_partial_ms: Double?
    var biasing: Bool
}

// One row per APPLIED replacement (research instrument, --dump-replacements).
// `replacementScore` is the BOOSTED vocab CTC score (vocabCtcScore +
// adaptiveCbw); `originalScore` is the raw original-word CTC score. The
// gate that fired is `replacementScore > originalScore`. The raw
// competitor margin a competitor-relative gate (A1) would use is
// `replacementScore - cbw - originalScore` (exact for short terms where
// adaptiveCbw == flat cbw; an approximation for terms longer than the
// adaptive reference token count). Emitted as JSONL.
struct DumpRow: Encodable {
    let id: String
    let originalWord: String
    let originalScore: Float
    let replacementWord: String?
    let replacementScore: Float?
    let reason: String
    let cbw: Float
}

// MARK: - Arg parsing (tiny; no ArgumentParser dep)

struct Args {
    var manifest = "bench/fixtures/manifest.json"
    var wavDir = "bench/fixtures"
    var paths = ["batch"]
    var dictionary: String?
    var pacing = "realtime"
    var out = "bench/results/results.json"
    // Vocab-rescorer tuning (biasing arm). Defaults mirror ParleqAppCore's
    // VocabTuning (minSimilarity 0.65, cbw 2.0); margin defaults to the
    // FluidAudio library default for the linked version when not set.
    // Overridable so the over-fire/recall ROC can be swept without rebuilding.
    var minSimilarity: Float = 0.65
    var cbw: Float = 2.0
    var margin: Double = -1   // <0 ⇒ use library default (don't pass)
    // Research instrument: when set, write one JSONL row per applied
    // replacement (per-match CTC scores) to this path. Off by default.
    var dumpReplacements: String?
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func next() -> String? { it.next() }
    while let flag = next() {
        switch flag {
        case "--manifest": a.manifest = next() ?? a.manifest
        case "--wav-dir": a.wavDir = next() ?? a.wavDir
        case "--paths": a.paths = (next() ?? "batch").split(separator: ",").map { String($0) }
        case "--dictionary": a.dictionary = next()
        case "--pacing": a.pacing = next() ?? a.pacing
        case "--out": a.out = next() ?? a.out
        case "--min-similarity": a.minSimilarity = Float(next() ?? "") ?? a.minSimilarity
        case "--cbw": a.cbw = Float(next() ?? "") ?? a.cbw
        case "--margin": a.margin = Double(next() ?? "") ?? a.margin
        case "--dump-replacements": a.dumpReplacements = next()
        default:
            FileHandle.standardError.write("warning: unknown flag \(flag)\n".data(using: .utf8)!)
        }
    }
    return a
}

func err(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// MARK: - WAV loading

/// Load a WAV as 16 kHz mono Float32 samples in [-1, 1]. The fixtures
/// are already 16 kHz mono (macOS `say` LEI16@16000), so the common
/// path returns the float channel directly; anything else is an error
/// the operator should fix at fixture-generation time rather than have
/// the bench silently resample.
func loadSamples16kMono(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let fmt = file.processingFormat
    guard fmt.sampleRate == 16000, fmt.channelCount == 1 else {
        throw NSError(domain: "asr-bench", code: 1, userInfo: [
            NSLocalizedDescriptionKey:
                "\(url.lastPathComponent): expected 16 kHz mono, got \(Int(fmt.sampleRate)) Hz / \(fmt.channelCount) ch"
        ])
    }
    let frames = AVAudioFrameCount(file.length)
    guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else {
        return []
    }
    try file.read(into: buf)
    guard let ch = buf.floatChannelData else { return [] }
    return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
}

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0 }

/// Thread-safe "did this phase label change?" tracker, so the
/// FluidAudio progress handler (a `@Sendable` closure invoked on an
/// arbitrary queue) can dedupe log lines without capturing a mutable
/// var.
final class PhaseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""
    func noteIfChanged(_ s: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if s == last { return false }
        last = s
        return true
    }
}

// MARK: - Batch engine (mirrors LocalASR.AsrBox)

actor BatchEngine {
    private var manager: AsrManager?

    func load() async throws {
        if manager != nil { return }
        let tracker = PhaseTracker()
        let handler: DownloadUtils.ProgressHandler = { snapshot in
            let label = "\(snapshot.phase)"
            if tracker.noteIfChanged(label) {
                FileHandle.standardError.write("  [model] \(label)\n".data(using: .utf8)!)
            }
        }
        let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: handler)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
    }

    /// Returns (transcript, tokenTimings, latencyMs). Fresh decoder
    /// state per clip. Token timings are needed by the CTC vocab
    /// rescorer (the biasing arm).
    func transcribe(_ samples: [Float]) async throws -> (String, [TokenTiming]?, Double) {
        guard let manager else { throw NSError(domain: "asr-bench", code: 2) }
        var state = try TdtDecoderState()
        let t0 = nowMs()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return (result.text, result.tokenTimings, nowMs() - t0)
    }
}

// MARK: - Vocab biasing engine (ports LocalASR.VocabBox)

struct DictFile: Decodable { let terms: [DictTerm] }
struct DictTerm: Decodable { let term: String; let aliases: [String]? }

/// CTC keyword-spotting + rescoring, ported verbatim from
/// ParleqAppCore/LocalASR.swift's VocabBox so the biasing arm reflects
/// exactly what the app does. Same tuning constants.
actor VocabEngine {
    let minSimilarity: Float
    let cbw: Float
    let margin: Double   // <0 ⇒ use library default

    init(minSimilarity: Float = 0.65, cbw: Float = 2.0, margin: Double = -1) {
        self.minSimilarity = minSimilarity
        self.cbw = cbw
        self.margin = margin
    }

    private var spotter: CtcKeywordSpotter?
    private var tokenizer: CtcTokenizer?
    private var modelDir: URL?
    private var rescorer: VocabularyRescorer?
    private var vocabulary: CustomVocabularyContext?

    func load(terms: [DictTerm]) async throws {
        let variant: CtcModelVariant = .ctc110m
        let models = try await CtcModels.downloadAndLoad(variant: variant)
        let dir = CtcModels.defaultCacheDirectory(for: variant)
        let tok = try await CtcTokenizer.load(from: dir)
        let spot = CtcKeywordSpotter(models: models, blankId: ContextBiasingConstants.defaultBlankId)

        let tokenized: [CustomVocabularyTerm] = terms.compactMap { entry in
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            let ids = tok.encode(term)
            guard !ids.isEmpty else { return nil }
            let aliases = (entry.aliases ?? []).filter { !$0.isEmpty }
            return CustomVocabularyTerm(
                text: term, weight: nil,
                aliases: aliases.isEmpty ? nil : aliases,
                tokenIds: nil, ctcTokenIds: ids
            )
        }
        let vocab = CustomVocabularyContext(terms: tokenized, minSimilarity: minSimilarity)
        let resc = try await VocabularyRescorer.create(
            spotter: spot, vocabulary: vocab, config: .default, ctcModelDirectory: dir
        )
        self.spotter = spot
        self.tokenizer = tok
        self.modelDir = dir
        self.vocabulary = vocab
        self.rescorer = resc
    }

    /// Rescore one transcript against the loaded vocabulary. Returns the
    /// (possibly) corrected text plus the per-match replacement records
    /// (for the --dump-replacements instrument). Best-effort: returns the
    /// input text and no replacements on any miss, matching LocalASR's
    /// fall-through behavior.
    func rescore(
        samples: [Float], transcript: String, timings: [TokenTiming]?
    ) async -> (text: String, replacements: [VocabularyRescorer.RescoringResult]) {
        guard let spotter, let rescorer, let vocabulary,
              let timings, !timings.isEmpty else { return (transcript, []) }
        do {
            let spotted = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples, customVocabulary: vocabulary
            )
            guard !spotted.logProbs.isEmpty else { return (transcript, []) }
            let out: VocabularyRescorer.RescoreOutput
            if margin >= 0 {
                out = rescorer.ctcTokenRescore(
                    transcript: transcript, tokenTimings: timings,
                    logProbs: spotted.logProbs, frameDuration: spotted.frameDuration,
                    cbw: cbw, marginSeconds: margin, minSimilarity: minSimilarity
                )
            } else {
                out = rescorer.ctcTokenRescore(
                    transcript: transcript, tokenTimings: timings,
                    logProbs: spotted.logProbs, frameDuration: spotted.frameDuration,
                    cbw: cbw, minSimilarity: minSimilarity
                )
            }
            return (out.wasModified ? out.text : transcript, out.replacements)
        } catch {
            return (transcript, [])
        }
    }
}

// MARK: - Streaming engines (StreamingEouAsrManager / StreamingNemotronAsrManager)

/// Records the latency to the first partial ("ghost text") callback,
/// relative to a start mark. Thread-safe — the managers invoke the
/// partial callback on their own executor.
final class FirstPartialTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var startMs = 0.0
    private var firstMs: Double?
    func start() { lock.lock(); startMs = nowMs(); firstMs = nil; lock.unlock() }
    func note() { lock.lock(); if firstMs == nil { firstMs = nowMs() - startMs }; lock.unlock() }
    func value() -> Double? { lock.lock(); defer { lock.unlock() }; return firstMs }
}

/// Minimal common surface over the two streaming managers so the run
/// loop isn't duplicated. Both are public actors in FluidAudio with
/// matching signatures; we conform them retroactively.
protocol StreamingASR: Actor {
    func reset() async
    func process(audioBuffer: AVAudioPCMBuffer) async throws -> String
    func finish() async throws -> String
    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void)
}

extension StreamingEouAsrManager: StreamingASR {}
extension StreamingNemotronAsrManager: StreamingASR {}

let mono16k = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
)!

/// Build a 16 kHz mono Float32 buffer from a slice of samples.
func makeBuffer(_ slice: ArraySlice<Float>) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: mono16k, frameCapacity: AVAudioFrameCount(slice.count))!
    buf.frameLength = AVAudioFrameCount(slice.count)
    let dst = buf.floatChannelData![0]
    var i = 0
    for v in slice { dst[i] = v; i += 1 }
    return buf
}

/// Run a streaming manager over the corpus. Feeds each clip in
/// model-chunk-sized slices at max speed (the manager's RTFx >> 1 on
/// Apple silicon, so prior chunks are fully processed before the next
/// arrives — the same end state realtime feeding reaches). The
/// post-release latency is measured as the final slice's
/// process()+finish() time: the work that, in real use, still has to
/// happen after the user stops speaking. `latency_ms` is the full
/// process+finish wall-clock (for RTFx).
func runStreaming(
    label: String,
    manager: StreamingASR,
    chunkSamples: Int,
    clips: [Clip],
    wavDir: String
) async -> [ResultRow] {
    var rows: [ResultRow] = []
    let timer = FirstPartialTimer()
    await manager.setPartialCallback { _ in timer.note() }

    var i = 0
    for clip in clips {
        i += 1
        let url = URL(fileURLWithPath: wavDir).appendingPathComponent(clip.file)
        do {
            let samples = try loadSamples16kMono(url)
            await manager.reset()

            // Slice into model-chunk-sized buffers.
            var chunks: [ArraySlice<Float>] = []
            var start = 0
            while start < samples.count {
                let end = min(start + chunkSamples, samples.count)
                chunks.append(samples[start..<end])
                start = end
            }
            if chunks.isEmpty { chunks = [samples[0..<0]] }

            timer.start()
            let tTotal = nowMs()
            var transcript = ""
            // Feed all but the last chunk (these overlap "during speech").
            for c in chunks.dropLast() {
                transcript += try await manager.process(audioBuffer: makeBuffer(c))
            }
            // The post-release tail: last chunk + flush.
            let tRelease = nowMs()
            transcript += try await manager.process(audioBuffer: makeBuffer(chunks.last!))
            transcript += try await manager.finish()
            let post = nowMs() - tRelease
            let total = nowMs() - tTotal

            rows.append(ResultRow(
                id: clip.id, path: label, ref: clip.reference_transcript,
                hyp: transcript, latency_ms: total, post_release_ms: post,
                first_partial_ms: timer.value(), biasing: false
            ))
            if i % 20 == 0 { err("  \(label) \(i)/\(clips.count)") }
        } catch {
            err("  clip \(clip.id) failed (\(label)): \(error)")
            rows.append(ResultRow(
                id: clip.id, path: label, ref: clip.reference_transcript,
                hyp: "", latency_ms: nil, post_release_ms: nil,
                first_partial_ms: nil, biasing: false
            ))
        }
    }
    return rows
}

// MARK: - Streaming model loading (mirrors FluidAudioCLI helpers)

func eouModelsDirectory(_ chunkSize: StreamingChunkSize) -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport
        .appendingPathComponent("FluidAudio/Models/parakeet-eou-streaming", isDirectory: true)
        .appendingPathComponent(chunkSize.modelSubdirectory, isDirectory: true)
}

func loadEouManager(_ chunkSize: StreamingChunkSize) async throws -> StreamingEouAsrManager {
    let modelsUrl = eouModelsDirectory(chunkSize)
    if !FileManager.default.fileExists(atPath: modelsUrl.path) {
        let repo: Repo
        switch chunkSize {
        case .ms160: repo = .parakeetEou160
        case .ms320: repo = .parakeetEou320
        case .ms1280: repo = .parakeetEou1280
        }
        let dest = modelsUrl.deletingLastPathComponent().deletingLastPathComponent()
        err("  [eou] downloading \(chunkSize.modelSubdirectory) models…")
        try await DownloadUtils.downloadRepo(repo, to: dest)
    }
    let manager = StreamingEouAsrManager(
        configuration: MLModelConfiguration(), chunkSize: chunkSize, eouDebounceMs: 1280
    )
    try await manager.loadModels(from: modelsUrl)
    return manager
}

func loadNemotronManager(_ chunkSize: NemotronChunkSize) async throws -> StreamingNemotronAsrManager {
    let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/fluidaudio/models")
    let cacheDir = base.appendingPathComponent(chunkSize.repo.folderName)
    let encoder = cacheDir.appendingPathComponent("encoder/encoder_int8.mlmodelc")
    if !FileManager.default.fileExists(atPath: encoder.path) {
        err("  [nemotron] downloading \(chunkSize.rawValue)ms models…")
        try await DownloadUtils.downloadRepo(chunkSize.repo, to: base)
    }
    let manager = StreamingNemotronAsrManager()
    try await manager.loadModels(from: cacheDir)
    return manager
}

// MARK: - Main

@main
struct ASRBench {
    static func main() async {
        let args = parseArgs()

        let manifestURL = URL(fileURLWithPath: args.manifest)
        guard let mdata = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: mdata) else {
            err("failed to read manifest at \(args.manifest)")
            exit(1)
        }
        err("loaded \(manifest.clips.count) clips from \(args.manifest)")
        err("paths: \(args.paths.joined(separator: ", "))")

        var rows: [ResultRow] = []
        var dumpRows: [DumpRow] = []

        if args.paths.contains("batch") {
            let engine = BatchEngine()
            do {
                err("loading Parakeet TDT v3 (first run downloads ~150 MB)…")
                try await engine.load()
                err("model ready; transcribing (batch)…")
            } catch {
                err("model load failed: \(error)")
                exit(1)
            }

            // Optional CTC vocab-boosting arm (the biasing comparison).
            var vocab: VocabEngine?
            if let dictPath = args.dictionary {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: dictPath))
                    let dict = try JSONDecoder().decode(DictFile.self, from: data)
                    err("loading CTC vocab boosting (\(dict.terms.count) terms; minSim=\(args.minSimilarity) cbw=\(args.cbw) margin=\(args.margin < 0 ? "lib-default" : String(args.margin)); first run downloads ~97 MB)…")
                    let v = VocabEngine(minSimilarity: args.minSimilarity, cbw: args.cbw, margin: args.margin)
                    try await v.load(terms: dict.terms)
                    vocab = v
                    err("vocab ready; will emit biasing=true rows too")
                } catch {
                    err("dictionary load failed (\(error)); skipping biasing arm")
                }
            }

            var i = 0
            for clip in manifest.clips {
                i += 1
                let wav = URL(fileURLWithPath: args.wavDir).appendingPathComponent(clip.file)
                do {
                    let samples = try loadSamples16kMono(wav)
                    let (text, timings, ms) = try await engine.transcribe(samples)
                    rows.append(ResultRow(
                        id: clip.id, path: "batch", ref: clip.reference_transcript,
                        hyp: text, latency_ms: ms, post_release_ms: nil,
                        first_partial_ms: nil, biasing: false
                    ))
                    if let vocab {
                        let t0 = nowMs()
                        let (boosted, replacements) = await vocab.rescore(
                            samples: samples, transcript: text, timings: timings
                        )
                        rows.append(ResultRow(
                            id: clip.id, path: "batch", ref: clip.reference_transcript,
                            hyp: boosted, latency_ms: ms + (nowMs() - t0),
                            post_release_ms: nil, first_partial_ms: nil, biasing: true
                        ))
                        if args.dumpReplacements != nil {
                            for r in replacements {
                                dumpRows.append(DumpRow(
                                    id: clip.id,
                                    originalWord: r.originalWord, originalScore: r.originalScore,
                                    replacementWord: r.replacementWord, replacementScore: r.replacementScore,
                                    reason: r.reason, cbw: args.cbw
                                ))
                            }
                        }
                    }
                    if i % 20 == 0 { err("  batch \(i)/\(manifest.clips.count)") }
                } catch {
                    err("  clip \(clip.id) failed: \(error)")
                    rows.append(ResultRow(
                        id: clip.id, path: "batch", ref: clip.reference_transcript,
                        hyp: "", latency_ms: nil, post_release_ms: nil,
                        first_partial_ms: nil, biasing: false
                    ))
                }
            }
        }

        if args.paths.contains("eou") {
            do {
                let cs: StreamingChunkSize = .ms160
                err("loading EOU streaming models (160ms)…")
                let m = try await loadEouManager(cs)
                err("EOU ready; transcribing (streaming)…")
                rows += await runStreaming(
                    label: "eou", manager: m, chunkSamples: cs.chunkSamples,
                    clips: manifest.clips, wavDir: args.wavDir
                )
            } catch { err("eou path failed: \(error)") }
        }

        // eou-whole: feed each clip to the EOU manager in a single
        // process() call (the FluidAudio CLI's pattern) to separate EOU
        // model quality from incremental-chunk-feeding artifacts. Not a
        // realistic streaming mode (no post-release win) — diagnostic only.
        if args.paths.contains("eou-whole") {
            do {
                let cs: StreamingChunkSize = .ms160
                err("loading EOU streaming models (160ms) for whole-buffer diagnostic…")
                let m = try await loadEouManager(cs)
                err("EOU ready; transcribing (whole-buffer)…")
                rows += await runStreaming(
                    label: "eou-whole", manager: m, chunkSamples: Int.max,
                    clips: manifest.clips, wavDir: args.wavDir
                )
            } catch { err("eou-whole path failed: \(error)") }
        }

        if args.paths.contains("nemotron") {
            do {
                let cs: NemotronChunkSize = .ms560
                err("loading Nemotron streaming models (560ms)…")
                let m = try await loadNemotronManager(cs)
                err("Nemotron ready; transcribing (streaming)…")
                rows += await runStreaming(
                    label: "nemotron", manager: m, chunkSamples: cs.rawValue * 16,
                    clips: manifest.clips, wavDir: args.wavDir
                )
            } catch { err("nemotron path failed: \(error)") }
        }

        let known: Set<String> = ["batch", "eou", "eou-whole", "nemotron"]
        let unsupported = args.paths.filter { !known.contains($0) }
        if !unsupported.isEmpty {
            err("note: unknown paths ignored: \(unsupported.joined(separator: ", "))")
        }

        // Write results.
        let outURL = URL(fileURLWithPath: args.out)
        try? FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(rows).write(to: outURL)
            err("wrote \(rows.count) rows -> \(args.out)")
        } catch {
            err("failed to write results: \(error)")
            exit(1)
        }

        // Write the per-match replacement dump (JSONL) if requested.
        if let dumpPath = args.dumpReplacements {
            let dumpURL = URL(fileURLWithPath: dumpPath)
            try? FileManager.default.createDirectory(
                at: dumpURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let lineEnc = JSONEncoder()
            lineEnc.outputFormatting = [.sortedKeys]
            let lines = dumpRows.compactMap { row -> String? in
                guard let data = try? lineEnc.encode(row) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            do {
                try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
                    .write(to: dumpURL, atomically: true, encoding: .utf8)
                err("wrote \(dumpRows.count) replacement rows -> \(dumpPath)")
            } catch {
                err("failed to write replacement dump: \(error)")
            }
        }
    }
}
