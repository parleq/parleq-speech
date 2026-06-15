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

// MARK: - Arg parsing (tiny; no ArgumentParser dep)

struct Args {
    var manifest = "bench/fixtures/manifest.json"
    var wavDir = "bench/fixtures"
    var paths = ["batch"]
    var dictionary: String?
    var pacing = "realtime"
    var out = "bench/results/results.json"
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

    /// Returns (transcript, latencyMs). Fresh decoder state per clip.
    func transcribe(_ samples: [Float]) async throws -> (String, Double) {
        guard let manager else { throw NSError(domain: "asr-bench", code: 2) }
        var state = try TdtDecoderState()
        let t0 = nowMs()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return (result.text, nowMs() - t0)
    }
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
            var i = 0
            for clip in manifest.clips {
                i += 1
                let wav = URL(fileURLWithPath: args.wavDir).appendingPathComponent(clip.file)
                do {
                    let samples = try loadSamples16kMono(wav)
                    let (text, ms) = try await engine.transcribe(samples)
                    rows.append(ResultRow(
                        id: clip.id, path: "batch", ref: clip.reference_transcript,
                        hyp: text, latency_ms: ms, post_release_ms: nil,
                        first_partial_ms: nil, biasing: false
                    ))
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

        let unsupported = args.paths.filter { $0 != "batch" }
        if !unsupported.isEmpty {
            err("note: paths \(unsupported.joined(separator: ", ")) not implemented in this build (Phase 3)")
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
    }
}
