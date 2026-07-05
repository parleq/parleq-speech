// VoiceprintContextContaminationTests — regression guard for the whole-utterance
// context-contamination bug in the voiceprint acoustic gate.
//
// PROVEN BUG (validated on real audio, see `VoiceprintReencodeValidationTests` +
// `VoiceprintReencoder`'s header): pooling a candidate word's embedding from
// whole-utterance Parakeet encoder frames is context-contaminated — global
// self-attention and whole-clip CMVN mean the SAME word (e.g. "Keavi") embeds
// differently depending on what else is in the clip. A real dictation with a
// company "Keavi" and a fruit "kiwi" in the SAME utterance ("...ship Keavi along
// with a kiwi") flipped every "Keavi" occurrence to REJECT — a company term the
// user correctly dictated three times got silently reverted to nothing, purely
// because a trailing "kiwi" happened to be in the same recording.
//
// FIX under test: `VoiceprintDemo.buildGate` re-encodes store-relevant candidate
// spans in a fixed canonical context (`VoiceprintReencoder`) instead of pooling
// them from the whole-utterance encoder pass, and `VoiceprintCoordinator.
// localizedSpan` builds enrollment the same way — so enrolled voiceprints and
// served candidates live in the same, context-free embedding space.
//
// Same self-skip / harness discipline as `VoiceprintSelfTestHarnessTests` +
// `CorrectorRegressionHarnessTests`: whole body is `#if Concord`; XCTSkip when
// the cached Parakeet models or the two labeled flywheel clips aren't present
// locally, so this never hard-fails in CI.

import XCTest
@testable import ParleqAppCore

#if Concord
import FluidAudio

@MainActor
final class VoiceprintContextContaminationTests: XCTestCase {

    /// The cached, compiled Parakeet TDT v3 models the installed app loads offline.
    private static var modelsCached: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let encoder = home.appendingPathComponent(
            "Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/Encoder.mlmodelc",
            isDirectory: true)
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    /// The maintainer's flywheel corpus the demo enrolls from.
    private static var flywheelPresent: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let manifest = home.appendingPathComponent(".parleq/flywheel/manifest.jsonl")
        return FileManager.default.fileExists(atPath: manifest.path)
    }

    /// Control clip: "I need to work on Keavi improve Keavi then ship Keavi" — 3 pure
    /// company occurrences, no fruit "kiwi" anywhere in the clip.
    private static var controlURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parleq/flywheel/audio/4ABEDDCC-714F-46BC-9230-D02A25DFA6E6.wav")
    }

    /// Test clip: the SAME sentence plus a trailing fruit "along with a kiwi" — the
    /// exact context-contamination shape the fix targets. Pre-fix, all 3 company
    /// "Keavi" occurrences were reverted to nothing (0 "Keavi" in the output).
    private static var testURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parleq/flywheel/audio/15FAEF53-D02E-4706-B2D0-BB205795DE9C.wav")
    }

    private static let testDict = [DictionaryEntry(term: "Keavi", aliases: ["kiwi"])]

    func test_combined_utterance_keeps_all_three_company_occurrences() async throws {
        // Arm BOTH env flags before any static read observes them (mirrors
        // VoiceprintSelfTestHarnessTests / CorrectorRegressionHarnessTests).
        setenv("PARLEQ_VOICEPRINT_DEMO", "1", 1)
        setenv("PARLEQ_VOICEPRINT_ENFORCE", "1", 1)
        XCTAssertTrue(VoiceprintDemo.isEnabled,
                      "PARLEQ_VOICEPRINT_DEMO must be observed as enabled before loading models")
        XCTAssertTrue(VoiceprintDemo.isEnforcing,
                      "PARLEQ_VOICEPRINT_ENFORCE must be observed as enabled before building the gate")

        guard Self.flywheelPresent else {
            throw XCTSkip("No flywheel manifest at ~/.parleq/flywheel/manifest.jsonl — skipping.")
        }
        guard Self.modelsCached else {
            throw XCTSkip("Parakeet TDT v3 models not cached locally — skipping (avoids a download).")
        }
        guard FileManager.default.fileExists(atPath: Self.controlURL.path) else {
            throw XCTSkip("control clip missing: \(Self.controlURL.path)")
        }
        guard FileManager.default.fileExists(atPath: Self.testURL.path) else {
            throw XCTSkip("test clip missing: \(Self.testURL.path)")
        }

        // Real model-loading path — same as VoiceprintSelfTestHarnessTests.
        let asr = LocalASR()
        asr.start()
        let loadDeadline = Date().addingTimeInterval(180)
        while !asr.isReady && !asr.loadFailed && Date() < loadDeadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard !asr.loadFailed else { throw XCTSkip("ASR model load failed") }
        guard asr.isReady else {
            XCTFail("ASR models did not become ready within the deadline")
            return
        }

        // Enroll fresh via the coordinator's debug flywheel path, and wire the
        // SAME LocalASR instance's samples-based transcribe handle for the
        // context-free re-encode — exactly how main.swift wires production.
        let coordinator = VoiceprintCoordinator()
        coordinator.transcribe = { [weak asr] samples in
            try? await asr?.transcribeSamplesForVoiceprint(samples: samples)
        }
        let enrollResult = await coordinator.runStartupEnrollment(transcribe: { wav in
            try await asr.transcribeRawForVoiceprint(wav: wav)
        })
        guard let enrollResult else {
            XCTFail("runStartupEnrollment returned nil — enrollment did not complete "
                    + "(no manifest, too few clips, or no usable Keavi embeddings)")
            return
        }
        XCTAssertFalse(enrollResult.lowQuality, "enrolled Keavi template was flagged low-quality")

        // Build the (now async) gate factory.
        let factory = coordinator.enforcementGateFactory()
        let enrolled = Set(coordinator.enrolledTermIDs.map { $0.lowercased() })

        final class Box: @unchecked Sendable { var text = "" }

        /// Decode + transcribe `url`, build its diagnostics (with `utteranceSamples`
        /// populated, mirroring LocalASR's production diagnostics), and drive the
        /// real `ConcordCleanupProvider` end to end — same wiring as
        /// CorrectorRegressionHarnessTests / VoiceprintSelfTestHarnessTests.
        func cleanedText(for url: URL) async throws -> String? {
            guard let data = try? Data(contentsOf: url),
                  let asrResult = try await asr.transcribeRawForVoiceprint(wav: data),
                  let samples = LocalASR.decodeWavSamples(data)
            else { return nil }

            let diagnostics = ASRDiagnostics(
                confidence: asrResult.confidence,
                durationSec: asrResult.duration,
                processingSec: asrResult.processingTime,
                tokenTimings: (asrResult.tokenTimings ?? []).map {
                    ASRTokenTiming(token: $0.token, tokenId: $0.tokenId,
                                   startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence)
                },
                replacements: [],
                encoderFeatures: asrResult.encoderFeatures,
                utteranceSamples: samples)

            let provider = ConcordCleanupProvider()
            provider.setEnrollmentGateFactory(factory)
            provider.setUtteranceContext(diagnostics: diagnostics)
            provider.setUtteranceDictionary(Self.testDict)
            provider.setUtterancePolicies(CorrectionPolicyClassifier.classify(Self.testDict, enrolled: enrolled))
            provider.setUtteranceCall(transcript: asrResult.text, isRefine: false, priorText: nil)

            let box = Box()
            try await provider.generateStreaming(systemPrompt: "", messages: []) { ev in
                if case .chunk(let t) = ev { box.text = t }
            }
            return box.text
        }

        // Control: 3 pure "Keavi" occurrences, no contamination risk — must still
        // recover all 3 (no regression from the fix).
        guard let controlText = try await cleanedText(for: Self.controlURL) else {
            XCTFail("control clip produced no cleaned text")
            return
        }
        let controlKeaviCount = controlText.components(separatedBy: "Keavi").count - 1
        print("[voiceprint-context-contamination] control text=\"\(controlText)\" Keavi-count=\(controlKeaviCount)")
        XCTAssertEqual(controlKeaviCount, 3, "control clip should keep all 3 'Keavi' occurrences")

        // Test: the SAME 3 "Keavi" occurrences plus a trailing fruit "kiwi" in ONE
        // recording — the exact context-contamination shape. Pre-fix this recovered
        // 0 "Keavi" (all 3 incorrectly reverted). Post-fix all 3 must be kept AND
        // the trailing fruit "kiwi" must still revert (zero new harm).
        guard let testText = try await cleanedText(for: Self.testURL) else {
            XCTFail("test clip produced no cleaned text")
            return
        }
        let testKeaviCount = testText.components(separatedBy: "Keavi").count - 1
        print("[voiceprint-context-contamination] test text=\"\(testText)\" Keavi-count=\(testKeaviCount)")
        XCTAssertEqual(testKeaviCount, 3,
                       "context-contamination fix: all 3 company 'Keavi' occurrences must be kept "
                       + "even with a trailing fruit 'kiwi' in the same utterance (pre-fix: 0)")
        XCTAssertTrue(testText.lowercased().contains("kiwi"),
                     "the trailing fruit occurrence must still revert to 'kiwi' (zero new harm)")
    }
}
#endif
