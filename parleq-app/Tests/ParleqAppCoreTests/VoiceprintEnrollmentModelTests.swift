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
}
#endif
