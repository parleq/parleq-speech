// ContributionRecorder — durable, opt-in "flywheel" capture.
//
// When armed (Config.contributionCaptureArmed; see Config.swift and
// docs/SECURITY_REVIEW.md), this is the ONE component in the app that
// writes dictation-derived audio + transcript content to disk. It is a
// DOCUMENTED CARVE-OUT to hard invariants #1 (audio memory-only), #2
// (no transcript to disk), and #7 (correction signals never to disk):
// those promises hold literally for every user who has NOT hand-edited
// the exact acknowledgment phrase into ~/.parleq/config.json.
//
// The corpus is purely local. This file contains NO network code — the
// app never transmits the captured data; "contributing" it to the
// project is a separate, manual act the contributor performs by hand.
//
// Storage (unbounded; the contributor prunes by hand):
//   ~/.parleq/flywheel/
//   ├── manifest.jsonl     one JSON object per dictation, append-only
//   └── audio/<uuid>.wav   16 kHz mono int16, verbatim AudioRecorder output
//
// Off the hot path, fail-silent: a write failure (disk full, perms) is
// swallowed and logged COUNT-ONLY — never surfaces to the user, never
// blocks or breaks a paste. The recorder is a passive observer.

import Foundation

/// Terminal disposition of a captured dictation.
public enum ContributionDisposition: String, Sendable, Codable {
    case accepted
    case discarded
}

/// One refine/command turn applied to a dictation (instruction + the
/// edit's before/after text). Bundled into the dictation's single record.
public struct ContributionRefineTurn: Sendable, Codable {
    public let instruction: String
    public let before: String
    public let after: String

    public init(instruction: String, before: String, after: String) {
        self.instruction = instruction
        self.before = before
        self.after = after
    }
}

/// A fully-assembled contribution record, handed to the recorder at a
/// dictation's terminal state. `wav` is the raw 16 kHz mono WAV bytes
/// (nil if unavailable). Sendable so it can cross to the recorder actor.
public struct ContributionRecord: Sendable {
    public let id: UUID
    public let timestamp: Date
    public let disposition: ContributionDisposition
    /// The ASR-stage transcript: FluidAudio/Parakeet output AFTER the
    /// CTC vocab rescorer (i.e. exactly what the product emits, before
    /// LLM cleanup). NOT the pre-rescore base text — that is recoverable
    /// from `diagnostics.replacements` + the retained audio. Named
    /// `asr_transcript` (not `raw_asr`) so a training script can't mistake
    /// it for the unbiased baseline.
    public let asrTranscript: String
    public let cleaned: String?
    public let finalText: String?
    public let cleanupFailed: Bool
    public let diagnostics: ASRDiagnostics?
    public let vocabulary: [String]
    public let asrModel: String
    public let fluidaudioVersion: String
    public let llm: String
    public let appBundle: String?
    public let referenceWindowsAttached: Bool
    public let transformApplied: Bool
    public let refined: Bool
    public let refineTurns: [ContributionRefineTurn]
    public let spelloutTerms: [String]
    public let wav: Data?

    public init(
        id: UUID,
        timestamp: Date,
        disposition: ContributionDisposition,
        asrTranscript: String,
        cleaned: String?,
        finalText: String?,
        cleanupFailed: Bool,
        diagnostics: ASRDiagnostics?,
        vocabulary: [String],
        asrModel: String,
        fluidaudioVersion: String,
        llm: String,
        appBundle: String?,
        referenceWindowsAttached: Bool,
        transformApplied: Bool,
        refined: Bool,
        refineTurns: [ContributionRefineTurn],
        spelloutTerms: [String],
        wav: Data?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.disposition = disposition
        self.asrTranscript = asrTranscript
        self.cleaned = cleaned
        self.finalText = finalText
        self.cleanupFailed = cleanupFailed
        self.diagnostics = diagnostics
        self.vocabulary = vocabulary
        self.asrModel = asrModel
        self.fluidaudioVersion = fluidaudioVersion
        self.llm = llm
        self.appBundle = appBundle
        self.referenceWindowsAttached = referenceWindowsAttached
        self.transformApplied = transformApplied
        self.refined = refined
        self.refineTurns = refineTurns
        self.spelloutTerms = spelloutTerms
        self.wav = wav
    }

    /// Whether `(asrTranscript → finalText)` is a clean corrector training
    /// pair. DERIVED, conservative — false negatives (a usable pair not
    /// auto-tagged) are safer than false positives (a degenerate pair
    /// polluting training). Requires:
    ///   - an accepted `finalText` (discarded → no final);
    ///   - a real LLM cleanup output (`cleaned != nil`) — this is the
    ///     direct sentinel that an LLM correction was produced AND used,
    ///     covering BOTH the failure path and `provider = none` (skip
    ///     cleanup, paste raw), where `final == asrTranscript` would be a
    ///     degenerate identity pair teaching copy-verbatim;
    ///   - no LLM transformation (reference context, preset/app-default
    ///     styling, or any refine command — LLM-driven, not ASR-corrected).
    /// `cleanupFailed` is implied by `cleaned == nil` but kept explicit
    /// for readability. Recomputable from the recorded fields if revised.
    public var correctorPairEligible: Bool {
        finalText != nil
            && cleaned != nil
            && !cleanupFailed
            && !referenceWindowsAttached
            && !transformApplied
            && !refined
    }
}

public actor ContributionRecorder {
    public static let shared = ContributionRecorder()

    private let flywheelDir: URL
    private let audioDir: URL
    private let manifestURL: URL

    /// Running total of on-disk corpus bytes, seeded lazily by scanning
    /// the dir on first capture (-1 = not yet seeded). A best-effort
    /// eyeball metric stamped into each record's `corpus_bytes`.
    private var cumulativeBytes: Int64 = -1

    /// `baseDirectory` defaults to `~/.parleq/flywheel`. Tests inject a
    /// temp directory for hermetic coverage of the write paths.
    init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? URL(
            fileURLWithPath: (NSHomeDirectory() as NSString)
                .appendingPathComponent(".parleq/flywheel")
        )
        self.flywheelDir = base
        self.audioDir = base.appendingPathComponent("audio", isDirectory: true)
        self.manifestURL = base.appendingPathComponent("manifest.jsonl")
    }

    /// On-disk encoding of one dictation. snake_case keys via the
    /// encoder's key strategy; `corrector_pair_eligible` is DERIVED here
    /// from the recorded provenance facts (recomputable later if the rule
    /// changes). `corpus_bytes` is the on-disk total at write time,
    /// excluding this very manifest line.
    private struct ManifestLine: Encodable {
        let id: String
        let ts: Date
        let disposition: String
        let audio: String?
        let asrTranscript: String
        let cleaned: String?
        let `final`: String?
        let cleanupFailed: Bool
        let asr: ASRDiagnostics?
        let vocabulary: [String]
        let asrModel: String
        let fluidaudioVersion: String
        let llm: String
        let appBundle: String?
        let referenceWindowsAttached: Bool
        let transformApplied: Bool
        let refined: Bool
        let correctorPairEligible: Bool
        let refineTurns: [ContributionRefineTurn]
        let spelloutTerms: [String]
        let corpusBytes: Int64
    }

    /// Persist one dictation. Fire-and-forget via `Task.detached` at the
    /// call site; all I/O is wrapped fail-silent.
    public func capture(_ record: ContributionRecord) async {
        // Tracked across the do/catch so a manifest-write failure can
        // remove the already-written WAV instead of orphaning it (an
        // orphan has no manifest line yet inflates later directorySize).
        var writtenAudioURL: URL?
        do {
            try FileManager.default.createDirectory(
                at: audioDir, withIntermediateDirectories: true
            )

            if cumulativeBytes < 0 {
                cumulativeBytes = Self.directorySize(flywheelDir)
            }

            // Write audio first so corpus_bytes reflects it.
            var audioRel: String?
            if let wav = record.wav, !wav.isEmpty {
                let audioURL = audioDir.appendingPathComponent("\(record.id.uuidString).wav")
                try wav.write(to: audioURL, options: .atomic)
                writtenAudioURL = audioURL
                audioRel = "audio/\(record.id.uuidString).wav"
                cumulativeBytes += Int64(wav.count)
            }

            let line = ManifestLine(
                id: record.id.uuidString,
                ts: record.timestamp,
                disposition: record.disposition.rawValue,
                audio: audioRel,
                asrTranscript: record.asrTranscript,
                cleaned: record.cleaned,
                final: record.finalText,
                cleanupFailed: record.cleanupFailed,
                asr: record.diagnostics,
                vocabulary: record.vocabulary,
                asrModel: record.asrModel,
                fluidaudioVersion: record.fluidaudioVersion,
                llm: record.llm,
                appBundle: record.appBundle,
                referenceWindowsAttached: record.referenceWindowsAttached,
                transformApplied: record.transformApplied,
                refined: record.refined,
                // DERIVED on the record (see ContributionRecord). False-
                // tagged records are still fully captured; a consumer
                // wanting e.g. hand-edited-after-failure pairs recomputes
                // from cleanup_failed / final / asr_transcript.
                correctorPairEligible: record.correctorPairEligible,
                refineTurns: record.refineTurns,
                spelloutTerms: record.spelloutTerms,
                corpusBytes: cumulativeBytes
            )

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(line)
            data.append(0x0A)  // newline → JSONL

            if FileManager.default.fileExists(atPath: manifestURL.path) {
                let handle = try FileHandle(forWritingTo: manifestURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: manifestURL, options: .atomic)
            }
            cumulativeBytes += Int64(data.count)

            // Count-only: NO transcript/audio content. disposition is
            // metadata, not user content.
            logStderr("[parleq] contribution captured (disposition=\(record.disposition.rawValue))")
        } catch {
            // Fail-silent: the dictation/paste path is already done and
            // nothing useful happens in response to a write failure.
            // If we reach catch with writtenAudioURL set, the WAV was
            // written but the manifest line did not commit (the encode +
            // file-append throwing ops run after the WAV write and before
            // the manifest is durable), so remove the orphaned file rather
            // than leave it unreferenced. Re-seed so a partial increment
            // doesn't drift.
            if let orphan = writtenAudioURL {
                try? FileManager.default.removeItem(at: orphan)
            }
            cumulativeBytes = -1
            logStderr("[parleq] contribution capture failed (write error)")
        }
    }

    /// Sum the byte sizes of every regular file under `dir`. Best-effort;
    /// returns 0 if the dir doesn't exist yet or can't be enumerated.
    private static func directorySize(_ dir: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - File-private logging

/// Mirrors the per-file-private `logStderr` pattern used across the
/// codebase. Same `[parleq]` prefix for grep parity. NEVER pass
/// transcript/audio content here — count/metadata only.
private func logStderr(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
