// VoiceprintSelfTestHarnessTests — CONFLICT-FREE verification of the
// voice-enrollment vertical slice.
//
// Goal: prove the in-app Swift Parakeet encoder (FluidAudio fork, encoder
// features exposed) + Concord's `VoiceprintGate` reproduce the research
// result — "Keavi" accepted, "kiwi" rejected — WITHOUT launching the full
// menu-bar app. The maintainer's installed Parleq is running; a second app
// instance would fight over the hotkey, microphone, and ASR models. This runs
// the exact same model-loading path (`LocalASR.start()` → wait-for-ready) and
// the exact same enrollment/gate logic (`VoiceprintCoordinator`), but as a
// unit test that loads the cached CoreML models offline and never binds a
// hotkey, opens the mic, or paints an overlay.
//
// The whole body is `#if Concord` — the public (trait-off) build compiles it
// out, matching the gating of `VoiceprintCoordinator` itself.
//
// The test self-skips (passes vacuously) when the flywheel corpus or the
// cached Parakeet models are absent, so it doesn't hard-fail in CI. On the
// maintainer's machine both are present and it runs for real.

import XCTest
@testable import ParleqAppCore

#if Concord
import FluidAudio

@MainActor
final class VoiceprintSelfTestHarnessTests: XCTestCase {

    /// The cached, compiled Parakeet TDT v3 models the installed app loads
    /// offline. If this directory's compiled encoder is missing we skip rather
    /// than trigger a multi-hundred-MB download inside a unit test.
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

    /// Load the real TDT models through the app's own loading path, run the
    /// startup enrollment + held-out self-check, and assert the research
    /// result: Keavi held-out accepted, kiwi held-out NEVER false-accepted.
    func test_voiceprint_selftest_reproduces_research_result() async throws {
        // The demo arms encoder-feature capture at model-load time only when
        // PARLEQ_VOICEPRINT_DEMO=1 (read inside AsrBox.loadModels via
        // VoiceprintDemo.isEnabled). Set it BEFORE LocalASR.start() so the
        // capture flag is armed when the AsrManager is constructed.
        setenv("PARLEQ_VOICEPRINT_DEMO", "1", 1)
        XCTAssertTrue(VoiceprintDemo.isEnabled,
                      "PARLEQ_VOICEPRINT_DEMO must be observed as enabled before loading models")

        guard Self.flywheelPresent else {
            throw XCTSkip("No flywheel manifest at ~/.parleq/flywheel/manifest.jsonl — skipping.")
        }
        guard Self.modelsCached else {
            throw XCTSkip("Parakeet TDT v3 models not cached locally — skipping (avoids a download).")
        }

        // Reuse the app's real model-loading path: LocalASR.start() kicks off
        // AsrModels.downloadAndLoad(.v3) (a no-op load from the cached compiled
        // models, offline) + AsrManager.loadModels, and arms encoder-feature
        // capture because the env var is set. We poll isReady to wait for the
        // background load to finish. No hotkey, no mic, no overlay — this is the
        // ASR engine only.
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

        // Run the exact coordinator logic, supplying the real transcription
        // closure over the encoder-feature-capturing path.
        let coordinator = VoiceprintCoordinator()
        let result = await coordinator.runStartupEnrollment(transcribe: { wav in
            try await asr.transcribeRawForVoiceprint(wav: wav)
        })

        guard let result else {
            XCTFail("runStartupEnrollment returned nil — enrollment did not complete "
                    + "(no manifest, too few clips, or no usable Keavi embeddings)")
            return
        }

        // Print the full numbers so they're visible in test output.
        print("""
        [voiceprint-selftest-harness] \
        enrolledClips=\(result.enrolledClips) \
        negativeClips=\(result.negativeClips) \
        survivingMeanSelfSim=\(String(format: "%.3f", result.survivingMeanSelfSim)) \
        lowQuality=\(result.lowQuality) \
        Keavi-heldout-accept=\(result.keaviHeldoutAccepted)/\(result.keaviHeldoutTotal) \
        kiwi-heldout-false-accept=\(result.kiwiHeldoutFalseAccepted)/\(result.kiwiHeldoutTotal)
        """)

        // Enrollment succeeded with a good-quality template.
        XCTAssertGreaterThanOrEqual(result.enrolledClips, 3,
                                    "expected >= 3 usable Keavi enrollment clips")
        XCTAssertFalse(result.lowQuality, "enrolled Keavi template was flagged low-quality")

        // The research result:
        //  - Keavi held-out clips are ACCEPTED (at least one; ideally all).
        XCTAssertGreaterThan(result.keaviHeldoutTotal, 0,
                             "no held-out Keavi clips produced an embedding")
        XCTAssertGreaterThanOrEqual(result.keaviHeldoutAccepted, 1,
                                    "expected at least one held-out Keavi clip to be ACCEPTED")
        //  - kiwi held-out clips are NEVER false-accepted (zero-harm veto).
        XCTAssertEqual(result.kiwiHeldoutFalseAccepted, 0,
                       "kiwi held-out clip was FALSE-ACCEPTED as Keavi — the gate must reject it")

        try await assertEnforceEndToEnd(asr: asr, coordinator: coordinator)
    }

    /// ENFORCE end-to-end: build the acoustic gate from a real held-out clip's encoder features and
    /// drive the REAL `ConcordCleanupProvider` text output. With the bad-apple `kiwi`→`Keavi` alias
    /// present, plain Concord swaps EVERY "kiwi"; the acoustic gate must keep the fruit (no "Keavi")
    /// and still recover the company on at least one Keavi clip. Exercises the full production
    /// wiring (provider side-channels + gate factory + engine veto), not a stub.
    private func assertEnforceEndToEnd(asr: LocalASR, coordinator: VoiceprintCoordinator) async throws {
        setenv("PARLEQ_VOICEPRINT_ENFORCE", "1", 1)
        XCTAssertTrue(VoiceprintDemo.isEnforcing, "ENFORCE must be observed before building the gate")

        let factory = coordinator.enforcementGateFactory()
        let dict = [DictionaryEntry(term: "Keavi", aliases: ["kiwi"])]

        // Re-load the SAME held-out clips the coordinator held out (last 2 per window).
        struct Row: Decodable { let id: String; let audio: String; let ts: String }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let flywheel = home.appendingPathComponent(".parleq/flywheel", isDirectory: true)
        let raw = try String(contentsOf: flywheel.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
        let keaviWin = ("2026-06-25T11:15:28Z", "2026-06-25T11:16:35Z")
        let kiwiWin = ("2026-06-25T11:12:45Z", "2026-06-25T11:14:05Z")
        var keaviRows: [Row] = [], kiwiRows: [Row] = []
        let dec = JSONDecoder()
        for line in raw.split(separator: "\n") {
            guard let r = try? dec.decode(Row.self, from: Data(line.utf8)) else { continue }
            if r.ts >= keaviWin.0 && r.ts <= keaviWin.1 { keaviRows.append(r) }
            else if r.ts >= kiwiWin.0 && r.ts <= kiwiWin.1 { kiwiRows.append(r) }
        }
        keaviRows.sort { $0.ts < $1.ts }; kiwiRows.sort { $0.ts < $1.ts }

        final class Box: @unchecked Sendable { var text = "" }

        func cleanedText(_ row: Row) async throws -> String? {
            let wavURL = flywheel.appendingPathComponent(row.audio)
            guard let data = try? Data(contentsOf: wavURL),
                  let asrResult = try await asr.transcribeRawForVoiceprint(wav: data) else { return nil }
            let diagnostics = ASRDiagnostics(
                confidence: asrResult.confidence,
                durationSec: asrResult.duration,
                processingSec: asrResult.processingTime,
                tokenTimings: (asrResult.tokenTimings ?? []).map {
                    ASRTokenTiming(token: $0.token, tokenId: $0.tokenId,
                                   startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence)
                },
                replacements: [],
                encoderFeatures: asrResult.encoderFeatures)
            let provider = ConcordCleanupProvider()
            provider.setEnrollmentGateFactory(factory)
            provider.setUtteranceContext(diagnostics: diagnostics)
            provider.setUtteranceDictionary(dict)
            provider.setUtteranceCall(transcript: asrResult.text, isRefine: false, priorText: nil)
            let box = Box()
            try await provider.generateStreaming(systemPrompt: "", messages: []) { ev in
                if case .chunk(let t) = ev { box.text = t }
            }
            return box.text
        }

        // Fruit clips must NOT be over-corrected to Keavi under enforce.
        for row in kiwiRows.suffix(2) {
            if let t = try await cleanedText(row) {
                XCTAssertFalse(t.contains("Keavi"),
                               "fruit 'kiwi' clip \(row.id) was over-corrected to Keavi under enforce: \(t.count) chars")
            }
        }
        // The company is still recovered on at least one Keavi clip.
        var recovered = 0, total = 0
        for row in keaviRows.suffix(2) {
            if let t = try await cleanedText(row) { total += 1; if t.contains("Keavi") { recovered += 1 } }
        }
        XCTAssertGreaterThan(total, 0, "no held-out Keavi clip produced text")
        XCTAssertGreaterThanOrEqual(recovered, 1,
                                    "at least one held-out Keavi clip should recover to Keavi under the enforce gate")
        print("[voiceprint-enforce-e2e] fruit kept (no Keavi); Keavi-heldout recovered \(recovered)/\(total)")
    }
}
#endif
