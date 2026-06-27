import XCTest
@testable import ParleqAppCore

#if Concord

/// 7033: voiceEnrollmentEnabled must gate the enrollment surface. The gate is a
/// pure, config-driven function (`VoiceprintServices.enrollmentOffered`) consulted
/// by both the app-shell wiring (main.swift — skips setVoiceprintServices when off)
/// and the Settings enroll entry point (hides the hero + guards startEnroll).
final class VoiceEnrollmentGateTests: XCTestCase {

    func test_enrollment_offered_when_enabled() {
        var c = Config.default
        c.voiceEnrollmentEnabled = true
        XCTAssertTrue(VoiceprintServices.enrollmentOffered(c))
    }

    func test_enrollment_not_offered_when_disabled() {
        var c = Config.default
        c.voiceEnrollmentEnabled = false
        XCTAssertFalse(VoiceprintServices.enrollmentOffered(c),
                       "master switch off → enrollment surface must be suppressed")
    }

    /// Default config offers enrollment (the field defaults true).
    func test_default_config_offers_enrollment() {
        XCTAssertTrue(VoiceprintServices.enrollmentOffered(Config.default))
    }

    /// An MDM-disabled flag (parsed from a managed dict) also closes the gate.
    func test_mdm_disabled_closes_gate() {
        let c = Config.parse(fromDictionary: ["features": ["voice_enrollment_enabled": false]])
        XCTAssertFalse(VoiceprintServices.enrollmentOffered(c))
    }
}

#endif
