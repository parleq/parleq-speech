// EnrollmentClipCaptureTests — Task 5: capture enrollment clips on save (consent+enabled gated).
//
// Test seam: the full model path is exercisable because VoiceprintEnrollmentModel
// accepts an injected transcribe closure and VoiceprintServices accepts an injected
// clipStoragePolicy. We don't need FluidAudio's live encoder — fakeKeaviTranscribe()
// returns a deterministic ASRResult backed by an EncoderFeatureSequence built from
// scratch, which is sufficient for buildPositive to produce a draft template and for
// save() to collect positive clips.
//
// Role/label correctness (positives nil label, negatives label) is verified at the
// coordinator level via storeEnrollmentClips directly — the enrollment model flow with
// fakeKeaviTranscribe produces all-"keavi" tokens (no harvested confusable), so negatives
// are not generated through that path; the coordinator-level test covers them explicitly.
//
// Delete wiring tests verify that removeVoiceprint and removeAll forward to the audio store.

import XCTest
@testable import ParleqAppCore

#if Concord
import FluidAudio

/// Records all audio-store calls; load always returns the empty map.
private final class StubAudioPersistence: EnrollmentAudioPersistence, @unchecked Sendable {
    private(set) var savedMaps: [[String: [StoredEnrollmentClip]]] = []
    private(set) var removedTermIDs: [String] = []
    private(set) var deleteAllCount = 0

    func load() throws -> [String: [StoredEnrollmentClip]] { [:] }
    func save(_ byTerm: [String: [StoredEnrollmentClip]]) throws { savedMaps.append(byTerm) }
    func remove(termID: String) throws { removedTermIDs.append(termID) }
    func deleteAll() throws { deleteAllCount += 1 }
}

private struct DecodeFailure: Error {}

/// load() THROWS (simulating an undecodable existing blob), so storeEnrollmentClips
/// must NOT save (it would otherwise clobber every other term's clips). Records saves.
private final class ThrowingLoadAudioPersistence: EnrollmentAudioPersistence, @unchecked Sendable {
    private(set) var saveCount = 0
    func load() throws -> [String: [StoredEnrollmentClip]] { throw DecodeFailure() }
    func save(_ byTerm: [String: [StoredEnrollmentClip]]) throws { saveCount += 1 }
    func remove(termID: String) throws {}
    func deleteAll() throws {}
}

@MainActor
final class EnrollmentClipCaptureTests: XCTestCase {

    // MARK: - Helpers

    /// Deterministic transcribe stub: 8 "keavi" word-groups spanning 0–4 s, backed by a
    /// tiny EncoderFeatureSequence (40 frames, 4-dim). buildPositive harvests no
    /// confusables → model routes straight to .review.
    private func fakeKeaviTranscribe() -> @Sendable (Data) async throws -> ASRResult? {
        var timings: [TokenTiming] = []
        for i in 0..<8 {
            timings.append(TokenTiming(
                token: i == 0 ? "keavi" : " keavi", tokenId: 1,
                startTime: Double(i) * 0.5, endTime: Double(i) * 0.5 + 0.4,
                confidence: 1.0))
        }
        let window = EncoderFeatureSequence.Window(
            frames: Array(repeating: [Float](repeating: 0.5, count: 4), count: 40),
            globalFrameOffset: 0)
        let features = EncoderFeatureSequence(windows: [window], hiddenSize: 4, secondsPerFrame: 0.1)
        let result = ASRResult(
            text: "keavi", confidence: 1.0, duration: 4.0, processingTime: 0.1,
            tokenTimings: timings, encoderFeatures: features)
        return { _ in result }
    }

    private func makeCoordinator(audioStub: StubAudioPersistence) -> VoiceprintCoordinator {
        let c = VoiceprintCoordinator()
        c.audioPersistence = audioStub
        return c
    }

    private func makeServices(
        coordinator: VoiceprintCoordinator,
        enabled: Bool,
        consented: Bool
    ) -> VoiceprintServices {
        VoiceprintServices(
            coordinator: coordinator,
            makeRecorder: { AudioRecorder() },
            transcribe: fakeKeaviTranscribe(),
            llmText: nil,
            clipStoragePolicy: { (enabled: enabled, consented: consented) })
    }

    private func makeModel(
        services: VoiceprintServices
    ) -> VoiceprintEnrollmentModel {
        VoiceprintEnrollmentModel(
            term: "Keavi",
            services: services,
            consented: true,
            onConsentGranted: {},
            onEnrolled: { _, _ in })
    }

    // MARK: - storeEnrollmentClips (coordinator level)

    /// storeEnrollmentClips writes the term's clips into the audio persistence map,
    /// preserving positive/negative roles and the negative label.
    func test_storeEnrollmentClips_saves_map_with_correct_roles() {
        let stub = StubAudioPersistence()
        let c = makeCoordinator(audioStub: stub)

        let posClip = StoredEnrollmentClip(
            wav: Data([0x01]), carrierText: "I use Keavi every day",
            role: .positive, negativeLabel: nil)
        let negClip = StoredEnrollmentClip(
            wav: Data([0x02]), carrierText: "I had a kiwi for lunch",
            role: .negative, negativeLabel: "kiwi")

        c.storeEnrollmentClips(termID: "Keavi", [posClip, negClip])

        XCTAssertEqual(stub.savedMaps.count, 1, "exactly one save call")
        let stored = stub.savedMaps[0]["Keavi"] ?? []
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored[0].role, .positive)
        XCTAssertNil(stored[0].negativeLabel, "positive clip must have nil negativeLabel")
        XCTAssertEqual(stored[1].role, .negative)
        XCTAssertEqual(stored[1].negativeLabel, "kiwi")
    }

    /// storeEnrollmentClips is a no-op at the I/O level when audioPersistence is nil.
    func test_storeEnrollmentClips_no_persistence_no_crash() {
        let c = VoiceprintCoordinator()
        // audioPersistence is nil — must not throw or crash
        c.storeEnrollmentClips(termID: "Keavi", [
            StoredEnrollmentClip(wav: Data([1]), carrierText: "x", role: .positive, negativeLabel: nil)
        ])
        // If we get here, the nil-guard worked.
    }

    /// 7031: when the existing store fails to DECODE (load throws), storeEnrollmentClips
    /// must SKIP the save — otherwise it would persist a map holding ONLY this term,
    /// clobbering every other term's stored clips. (A legit missing file returns [:],
    /// which is fine to merge into; only a throw is the dangerous case.)
    func test_storeEnrollmentClips_skips_save_when_existing_store_undecodable() {
        let stub = ThrowingLoadAudioPersistence()
        let c = VoiceprintCoordinator()
        c.audioPersistence = stub

        c.storeEnrollmentClips(termID: "Keavi", [
            StoredEnrollmentClip(wav: Data([1]), carrierText: "x", role: .positive, negativeLabel: nil)
        ])

        XCTAssertEqual(stub.saveCount, 0,
            "a decode/throw on load must skip the save so other terms' clips aren't clobbered")
    }

    // MARK: - Policy gate via VoiceprintEnrollmentModel.save()

    /// (enabled: true, consented: true) → clips stored with .positive role and nil label.
    func test_save_enabled_consented_stores_positive_clips() async {
        let stub = StubAudioPersistence()
        let coordinator = makeCoordinator(audioStub: stub)
        let services = makeServices(coordinator: coordinator, enabled: true, consented: true)
        let model = makeModel(services: services)

        await model.start()
        model.recordings = Array(repeating: Data([0xAA]), count: model.carriers.count)
        await model.analyze()
        // fakeKeaviTranscribe produces no confusables → straight to .review
        XCTAssertEqual(model.phase, .review)

        model.save()

        XCTAssertFalse(stub.savedMaps.isEmpty, "clips must be stored when enabled+consented")
        let clips = stub.savedMaps.first?["Keavi"] ?? []
        XCTAssertFalse(clips.isEmpty, "positive clips must be collected from non-nil recordings")
        XCTAssertTrue(clips.allSatisfy { $0.role == .positive }, "all clips are positive")
        XCTAssertTrue(clips.allSatisfy { $0.negativeLabel == nil }, "no negative label on positive clips")
    }

    /// (enabled: false, consented: true) → SI-3: nothing stored.
    func test_save_disabled_stores_nothing() async {
        let stub = StubAudioPersistence()
        let coordinator = makeCoordinator(audioStub: stub)
        let services = makeServices(coordinator: coordinator, enabled: false, consented: true)
        let model = makeModel(services: services)

        await model.start()
        model.recordings = Array(repeating: Data([0xBB]), count: model.carriers.count)
        await model.analyze()
        model.save()

        XCTAssertTrue(stub.savedMaps.isEmpty, "clips must NOT be stored when feature disabled")
    }

    /// (enabled: true, consented: false) → SI-3: nothing stored.
    func test_save_not_consented_stores_nothing() async {
        let stub = StubAudioPersistence()
        let coordinator = makeCoordinator(audioStub: stub)
        let services = makeServices(coordinator: coordinator, enabled: true, consented: false)
        let model = makeModel(services: services)

        await model.start()
        model.recordings = Array(repeating: Data([0xCC]), count: model.carriers.count)
        await model.analyze()
        model.save()

        XCTAssertTrue(stub.savedMaps.isEmpty, "clips must NOT be stored without consent")
    }

    /// cancel() must never store anything (it doesn't commit and doesn't call save).
    func test_cancel_stores_nothing() async {
        let stub = StubAudioPersistence()
        let coordinator = makeCoordinator(audioStub: stub)
        let services = makeServices(coordinator: coordinator, enabled: true, consented: true)
        let model = makeModel(services: services)

        await model.start()
        model.recordings = Array(repeating: Data([0xDD]), count: model.carriers.count)
        await model.analyze()
        model.cancel()

        XCTAssertTrue(stub.savedMaps.isEmpty, "cancel must store nothing")
    }

    // MARK: - Delete wiring

    /// removeVoiceprint(termID:) must forward to the audio store's remove(termID:).
    func test_removeVoiceprint_calls_audio_remove() {
        let stub = StubAudioPersistence()
        let c = makeCoordinator(audioStub: stub)
        c.removeVoiceprint(termID: "Keavi")
        XCTAssertEqual(stub.removedTermIDs, ["Keavi"])
    }

    /// removeAll() must forward to the audio store's deleteAll().
    func test_removeAll_calls_audio_deleteAll() {
        let stub = StubAudioPersistence()
        let c = makeCoordinator(audioStub: stub)
        c.removeAll()
        XCTAssertEqual(stub.deleteAllCount, 1)
    }

    /// removeVoiceprint with no audioPersistence set must not crash.
    func test_removeVoiceprint_no_persistence_no_crash() {
        let c = VoiceprintCoordinator()
        c.removeVoiceprint(termID: "Keavi")
    }

    /// removeAll with no audioPersistence set must not crash.
    func test_removeAll_no_persistence_no_crash() {
        let c = VoiceprintCoordinator()
        c.removeAll()
    }
}
#endif
