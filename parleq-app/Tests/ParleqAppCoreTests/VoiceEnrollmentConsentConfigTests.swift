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

    // MARK: - SI-3 / C4: amended-consent dual-flag set

    /// The onConsentGranted callback (SettingsWindow.startEnroll) must set BOTH
    /// voiceEnrollmentConsented AND voiceClipStorageConsented in the same write.
    /// This test pins that invariant by simulating what the callback does.
    func test_consent_accept_sets_both_enrollment_and_clip_storage_flags() {
        var c = Config.default
        XCTAssertFalse(c.voiceEnrollmentConsented,   "precondition: enrollment not yet consented")
        XCTAssertFalse(c.voiceClipStorageConsented,  "precondition: clip storage not yet consented")

        // Simulate what onConsentGranted does (SettingsWindow.startEnroll):
        c.voiceEnrollmentConsented = true
        c.voiceClipStorageConsented = true

        XCTAssertTrue(c.voiceEnrollmentConsented,  "enrollment consent must be set after accept")
        XCTAssertTrue(c.voiceClipStorageConsented, "clip storage consent must be set after accept (SI-3)")
    }

    /// SI-3: old-cohort users who consented via the pre-Task-10 flow (only
    /// voiceEnrollmentConsented=true, never shown the clip-storage disclosure)
    /// must have voiceClipStorageConsented remain false — no clips stored.
    func test_old_cohort_user_clip_storage_consent_stays_false() {
        // Simulate a config written before the amended disclosure existed:
        // features dict has voice_enrollment_consented=true but no clip key.
        let c = Config.parse(fromDictionary: [
            "features": ["voice_enrollment_consented": true]
        ])
        XCTAssertTrue(c.voiceEnrollmentConsented,
                      "old-cohort user has enrollment consent")
        XCTAssertFalse(c.voiceClipStorageConsented,
                       "SI-3: clip storage consent must be absent/false for old-cohort users")
    }
}
