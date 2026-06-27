// CorrectorRegressionHarnessTests — real-audio regression gate for the
// Concord corrector pipeline (dictionary + voiceprint + phonetic stages).
//
// For each labeled clip in Fixtures/corrector-labels.jsonl this harness:
//   1. Transcribes the WAV via LocalASR (the same in-process Parakeet path
//      as production).
//   2. Runs the result through a fresh ConcordCleanupProvider wired with
//      the test dictionary and the voiceprint enforcement gate.
//   3. Records a CorrectorMetrics.Outcome per clip (recovered / overFired).
//   4. Asserts the per-intent tally is within tolerance of the committed
//      baseline (Fixtures/corrector-baseline.json). When the baseline is
//      absent the harness prints the tally and skips rather than failing,
//      so the first run on a fresh checkout is safe.
//
// The whole body is #if Concord — the public (trait-off) build compiles
// it out. The test self-skips when the Parakeet models or the flywheel
// audio files are absent, so it does not hard-fail in CI.

import XCTest
@testable import ParleqAppCore

#if Concord
import FluidAudio

@MainActor
final class CorrectorRegressionHarnessTests: XCTestCase {

    // MARK: - Fixed test dictionary (labeled corpus is anchored to these terms)

    private static let testDict: [DictionaryEntry] = [
        DictionaryEntry(term: "Keavi", aliases: ["kiwi"]),
        DictionaryEntry(term: "RoboRev", aliases: []),
    ]

    /// Term intents: which canonical term must appear in the cleaned output.
    private static let intentTerm: [String: String] = [
        "keavi":    "Keavi",
        "robo-rev": "RoboRev",
    ]

    /// Non-term intents: the cleaned output must NOT contain ANY testDict term.
    private static let nonTermIntents: Set<String> = ["fruit", "bird", "control"]

    // MARK: - Skip guards (mirror VoiceprintSelfTestHarnessTests)

    private static var modelsCached: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let encoder = home.appendingPathComponent(
            "Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/Encoder.mlmodelc",
            isDirectory: true)
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    private static var flywheelPresent: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let manifest = home.appendingPathComponent(".parleq/flywheel/manifest.jsonl")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    // MARK: - Label row

    private struct LabelRow: Decodable {
        let audio: String   // already contains "audio/" prefix
        let intent: String
    }

    // MARK: - Harness

    func test_corrector_regression() async throws {
        // Arm encoder-feature capture BEFORE LocalASR.start() — same requirement
        // as the voiceprint harness (the flag is read at model-load time).
        setenv("PARLEQ_VOICEPRINT_DEMO", "1", 1)
        setenv("PARLEQ_VOICEPRINT_ENFORCE", "1", 1)
        XCTAssertTrue(VoiceprintDemo.isEnabled,
                      "PARLEQ_VOICEPRINT_DEMO must be observed as enabled before loading models")
        XCTAssertTrue(VoiceprintDemo.isEnforcing,
                      "PARLEQ_VOICEPRINT_ENFORCE must be observed before building the gate")

        guard Self.flywheelPresent else {
            throw XCTSkip("No flywheel manifest at ~/.parleq/flywheel/manifest.jsonl — skipping.")
        }
        guard Self.modelsCached else {
            throw XCTSkip("Parakeet TDT v3 models not cached locally — skipping (avoids a download).")
        }

        // Load label rows from the fixture file located next to this source file.
        let labelsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/corrector-labels.jsonl")
        guard FileManager.default.fileExists(atPath: labelsURL.path) else {
            throw XCTSkip("Fixtures/corrector-labels.jsonl not found — skipping.")
        }
        let labelsRaw = try String(contentsOf: labelsURL, encoding: .utf8)
        let dec = JSONDecoder()
        var labels: [LabelRow] = []
        for line in labelsRaw.split(separator: "\n") {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let row = try? dec.decode(LabelRow.self, from: Data(line.utf8)) else { continue }
            labels.append(row)
        }
        guard !labels.isEmpty else {
            XCTFail("corrector-labels.jsonl is empty or could not be decoded")
            return
        }

        // Start LocalASR and wait until ready (same 180s poll loop as reference harness).
        let asr = LocalASR()
        asr.start()

        let loadDeadline = Date().addingTimeInterval(180)
        while !asr.isReady && !asr.loadFailed && Date() < loadDeadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertFalse(asr.loadFailed, "ASR model load failed")
        guard asr.isReady else {
            XCTFail("ASR models did not become ready within the deadline")
            return
        }

        // Enroll once using the flywheel demo path (VoiceprintCoordinator).
        let coordinator = VoiceprintCoordinator()
        let enrollResult = await coordinator.runStartupEnrollment(transcribe: { wav in
            try await asr.transcribeRawForVoiceprint(wav: wav)
        })
        guard enrollResult != nil else {
            XCTFail("runStartupEnrollment returned nil — enrollment did not complete "
                    + "(no manifest, too few clips, or no usable Keavi embeddings)")
            return
        }
        let factory = coordinator.enforcementGateFactory()

        // Per-clip helper — mirrors assertEnforceEndToEnd in the reference harness.
        final class Box: @unchecked Sendable { var text = "" }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let flywheelRoot = home.appendingPathComponent(".parleq/flywheel", isDirectory: true)

        func cleanedText(for row: LabelRow) async throws -> String? {
            // audio already has the "audio/" prefix — join directly.
            let wavURL = flywheelRoot.appendingPathComponent(row.audio)
            guard let data = try? Data(contentsOf: wavURL),
                  let asrResult = try await asr.transcribeRawForVoiceprint(wav: data)
            else { return nil }

            let diagnostics = ASRDiagnostics(
                confidence: asrResult.confidence,
                durationSec: asrResult.duration,
                processingSec: asrResult.processingTime,
                tokenTimings: (asrResult.tokenTimings ?? []).map {
                    ASRTokenTiming(token: $0.token, tokenId: $0.tokenId,
                                   startTime: $0.startTime, endTime: $0.endTime,
                                   confidence: $0.confidence)
                },
                replacements: [],
                encoderFeatures: asrResult.encoderFeatures)

            let provider = ConcordCleanupProvider()
            provider.setEnrollmentGateFactory(factory)
            provider.setUtteranceContext(diagnostics: diagnostics)
            provider.setUtteranceDictionary(Self.testDict)
            provider.setUtteranceCall(transcript: asrResult.text, isRefine: false, priorText: nil)

            let box = Box()
            try await provider.generateStreaming(systemPrompt: "", messages: []) { ev in
                if case .chunk(let t) = ev { box.text = t }
            }
            return box.text.isEmpty ? nil : box.text
        }

        // Run all labeled clips and collect outcomes.
        var outcomes: [CorrectorMetrics.Outcome] = []
        for row in labels {
            guard let cleaned = try await cleanedText(for: row) else {
                // If transcription or cleanup fails for a clip, treat it as
                // neither recovered nor over-fired (safe: doesn't inflate either metric).
                outcomes.append(CorrectorMetrics.Outcome(intent: row.intent,
                                                          recovered: false,
                                                          overFired: false))
                continue
            }

            let outcome: CorrectorMetrics.Outcome
            if let targetTerm = Self.intentTerm[row.intent] {
                // Term intent: recovered iff the cleaned text contains the canonical term.
                outcome = CorrectorMetrics.Outcome(intent: row.intent,
                                                    recovered: cleaned.contains(targetTerm),
                                                    overFired: false)
            } else {
                // Non-term intent: over-fired iff the cleaned text contains ANY testDict term.
                let overFired = Self.testDict.contains { cleaned.contains($0.term) }
                outcome = CorrectorMetrics.Outcome(intent: row.intent,
                                                    recovered: false,
                                                    overFired: overFired)
            }
            outcomes.append(outcome)
        }

        // Tally outcomes.
        let tally = CorrectorMetrics.tally(outcomes)

        // Always print the full tally so numbers are visible in test output.
        print("[corrector-regression] per-intent tally:")
        for (intent, t) in tally.sorted(by: { $0.key < $1.key }) {
            print("  \(intent): recovered=\(t.recovered)/\(t.total)  overFired=\(t.overFired)/\(t.total)")
        }

        // Load the baseline if present; skip (not fail) if absent.
        let baselineURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/corrector-baseline.json")

        if !FileManager.default.fileExists(atPath: baselineURL.path) {
            print("[corrector-regression] baseline not yet minted — printing tally above and skipping.")
            throw XCTSkip("baseline not yet minted")
        }

        let baselineData = try Data(contentsOf: baselineURL)
        let baseline = try JSONDecoder().decode([String: CorrectorMetrics.Tally].self,
                                               from: baselineData)
        let (ok, regressions) = CorrectorMetrics.withinBaseline(tally, baseline: baseline, tolerance: 1)
        if !ok {
            print("[corrector-regression] REGRESSIONS: \(regressions.joined(separator: ", "))")
        }
        XCTAssertTrue(ok, "Corrector regression detected in intents: \(regressions.joined(separator: ", "))")
    }
}
#endif
