import XCTest
@testable import ParleqAppCore

final class VoiceEnrollmentConsentConfigTests: XCTestCase {

    func test_voiceEnrollmentConsented_defaults_to_false() {
        XCTAssertFalse(Config.default.voiceEnrollmentConsented,
                       "Voice enrollment records biometric-derived voiceprints — must be opt-in (off by default)")
    }

    func test_voiceEnrollmentConsented_absent_key_decodes_false() {
        // A config written before this feature existed (no features key at all).
        let c = Config.parse(fromDictionary: [:])
        XCTAssertFalse(c.voiceEnrollmentConsented)
    }

    func test_voiceEnrollmentConsented_parses_true() {
        let c = Config.parse(fromDictionary: ["features": ["voice_enrollment_consented": true]])
        XCTAssertTrue(c.voiceEnrollmentConsented)
    }

    func test_voiceEnrollmentConsented_round_trips_through_serialize() {
        var c = Config.default
        c.voiceEnrollmentConsented = true
        let dict = Config.serializeToDictionary(c)
        let features = dict["features"] as? [String: Any]
        XCTAssertEqual(features?["voice_enrollment_consented"] as? Bool, true)
        // And parses back.
        let reparsed = Config.parse(fromDictionary: dict)
        XCTAssertTrue(reparsed.voiceEnrollmentConsented)
    }
}
