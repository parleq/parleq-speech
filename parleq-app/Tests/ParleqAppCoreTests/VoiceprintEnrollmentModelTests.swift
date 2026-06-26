import XCTest
@testable import ParleqAppCore

#if Concord
import FluidAudio

@MainActor
final class VoiceprintEnrollmentModelTests: XCTestCase {

    private final class Flags { var consent = false; var enrolled: (String, [String])? }

    private func makeServices() -> VoiceprintServices {
        VoiceprintServices(
            coordinator: VoiceprintCoordinator(),
            makeRecorder: { AudioRecorder() },          // not exercised here
            transcribe: { _ in nil },                    // no audio in these tests
            llmText: nil)                                // → carrier templates
    }

    private func makeModel(consented: Bool, flags: Flags) -> VoiceprintEnrollmentModel {
        VoiceprintEnrollmentModel(
            term: "Keavi", services: makeServices(), consented: consented,
            onConsentGranted: { flags.consent = true },
            onEnrolled: { flags.enrolled = ($0, $1) })
    }

    /// A transcribe stub returning a fabricated ASR result that pools a usable
    /// "Keavi" embedding at WHATEVER slot the carrier places the term, so
    /// `analyze()` builds a real draft template without live audio. Eight
    /// "keavi"-token groups (all == the term key → no harvested confusable, so
    /// the model routes straight to `.review`) over one feature window.
    private func fakeKeaviTranscribe() -> @Sendable (Data) async throws -> ASRResult? {
        // 8 word-groups, each token "keavi" starting a new word (leading space
        // after the first), spanning [i*0.5, i*0.5+0.4]s.
        var timings: [TokenTiming] = []
        for i in 0..<8 {
            timings.append(TokenTiming(token: i == 0 ? "keavi" : " keavi", tokenId: 1,
                                       startTime: Double(i) * 0.5, endTime: Double(i) * 0.5 + 0.4,
                                       confidence: 1.0))
        }
        // One feature window covering 0..4.0s (40 frames @ 0.1s), 4-dim frames.
        let window = EncoderFeatureSequence.Window(
            frames: Array(repeating: [Float](repeating: 0.5, count: 4), count: 40),
            globalFrameOffset: 0)
        let features = EncoderFeatureSequence(windows: [window], hiddenSize: 4, secondsPerFrame: 0.1)
        let result = ASRResult(text: "keavi", confidence: 1.0, duration: 4.0, processingTime: 0.1,
                               tokenTimings: timings, encoderFeatures: features)
        return { _ in result }
    }

    private func makeAudioModel(coordinator: VoiceprintCoordinator, flags: Flags) -> VoiceprintEnrollmentModel {
        let services = VoiceprintServices(
            coordinator: coordinator,
            makeRecorder: { AudioRecorder() },
            transcribe: fakeKeaviTranscribe(),
            llmText: nil)
        return VoiceprintEnrollmentModel(
            term: "Keavi", services: services, consented: true,
            onConsentGranted: { flags.consent = true },
            onEnrolled: { flags.enrolled = ($0, $1) })
    }

    func test_start_unconsented_goes_to_intro_then_consent() async {
        let flags = Flags()
        let model = makeModel(consented: false, flags: flags)
        await model.start()
        XCTAssertEqual(model.phase, .intro)
        XCTAssertEqual(model.carriers.count, VoiceprintEnrollmentModel.carrierCount)
        XCTAssertTrue(model.carriers.allSatisfy { $0.contains("Keavi") })

        model.consent()
        XCTAssertTrue(flags.consent, "consent callback fired")
        XCTAssertEqual(model.phase, .carriers)
    }

    func test_start_consented_goes_straight_to_carriers() async {
        let model = makeModel(consented: true, flags: Flags())
        await model.start()
        XCTAssertEqual(model.phase, .carriers)
        XCTAssertEqual(model.recordings.count, model.carriers.count)
        XCTAssertFalse(model.carriersReady, "no recordings yet")
    }

    func test_realword_confusable_routes_to_confusable_step() async {
        let model = makeModel(consented: true, flags: Flags())
        await model.start()
        await model.decidePhaseAfterHarvest(aliases: ["kiwi", "kaevy"])
        XCTAssertEqual(model.harvestedConfusables, ["kiwi"], "kiwi is a real word; kaevy is not")
        XCTAssertEqual(model.negativeLabel, "kiwi")
        XCTAssertEqual(model.negativeCarriers.count, VoiceprintEnrollmentModel.negativeCarrierCount)
        XCTAssertTrue(model.negativeCarriers.allSatisfy { $0.contains("kiwi") })
        XCTAssertEqual(model.phase, .confusable)
    }

    func test_nonword_mishear_skips_to_review() async {
        let model = makeModel(consented: true, flags: Flags())
        await model.start()
        await model.decidePhaseAfterHarvest(aliases: ["kaevy", "qux"])
        XCTAssertEqual(model.harvestedConfusables, [])
        XCTAssertEqual(model.phase, .review)
    }

    func test_skip_and_save() async {
        let flags = Flags()
        let model = makeModel(consented: true, flags: flags)
        await model.start()
        model.skipConfusable()
        XCTAssertEqual(model.phase, .review)
        model.save()
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(flags.enrolled?.0, "Keavi", "onEnrolled fired with the term")
    }

    // MARK: storage is deferred to Save (the lifecycle fix)

    /// analyze() builds a draft but must NOT commit it — the store stays empty;
    /// cancel() then discards the draft, still leaving nothing stored.
    func test_analyze_then_cancel_stores_nothing() async {
        let coordinator = VoiceprintCoordinator()
        let model = makeAudioModel(coordinator: coordinator, flags: Flags())
        await model.start()
        model.recordings = Array(repeating: Data([1]), count: model.carriers.count)
        await model.analyze()
        XCTAssertEqual(model.phase, .review, "no real-word confusable → straight to review")
        XCTAssertNotNil(model.outcome, "a draft was built")
        XCTAssertFalse(coordinator.hasVoiceprint("Keavi"), "analyze must NOT commit to the store")

        model.cancel()
        XCTAssertFalse(coordinator.hasVoiceprint("Keavi"), "cancel leaves the store untouched")
    }

    /// Only save() commits the draft to the coordinator's store.
    func test_save_commits_the_draft() async {
        let coordinator = VoiceprintCoordinator()
        let flags = Flags()
        let model = makeAudioModel(coordinator: coordinator, flags: flags)
        await model.start()
        model.recordings = Array(repeating: Data([1]), count: model.carriers.count)
        await model.analyze()
        XCTAssertFalse(coordinator.hasVoiceprint("Keavi"), "not committed before Save")
        model.save()
        XCTAssertEqual(model.phase, .done)
        XCTAssertTrue(coordinator.hasVoiceprint("Keavi"), "Save commits the draft voiceprint")
        XCTAssertEqual(flags.enrolled?.0, "Keavi")
    }
}
#endif
