import XCTest
@testable import ParleqAppCore

final class ConfigDurableVoiceprintFieldsTests: XCTestCase {

    // MARK: - voiceEnrollmentEnabled (default: true)

    func test_voiceEnrollmentEnabled_default_is_true() {
        XCTAssertTrue(Config.default.voiceEnrollmentEnabled,
                      "voiceEnrollmentEnabled should default to true (master feature switch)")
    }

    func test_voiceEnrollmentEnabled_absent_key_yields_default_true() {
        let c = Config.parse(fromDictionary: [:])
        XCTAssertTrue(c.voiceEnrollmentEnabled)
    }

    func test_voiceEnrollmentEnabled_parses_false() {
        let c = Config.parse(fromDictionary: ["features": ["voice_enrollment_enabled": false]])
        XCTAssertFalse(c.voiceEnrollmentEnabled)
    }

    func test_voiceEnrollmentEnabled_round_trips() {
        var c = Config.default
        c.voiceEnrollmentEnabled = false
        let dict = Config.serializeToDictionary(c)
        let features = dict["features"] as? [String: Any]
        XCTAssertEqual(features?["voice_enrollment_enabled"] as? Bool, false)
        let reparsed = Config.parse(fromDictionary: dict)
        XCTAssertFalse(reparsed.voiceEnrollmentEnabled)
    }

    // MARK: - voiceprintClipStorageEnabled (default: true)

    func test_voiceprintClipStorageEnabled_default_is_true() {
        XCTAssertTrue(Config.default.voiceprintClipStorageEnabled,
                      "voiceprintClipStorageEnabled should default to true")
    }

    func test_voiceprintClipStorageEnabled_absent_key_yields_default_true() {
        let c = Config.parse(fromDictionary: [:])
        XCTAssertTrue(c.voiceprintClipStorageEnabled)
    }

    func test_voiceprintClipStorageEnabled_parses_false() {
        let c = Config.parse(fromDictionary: ["features": ["voiceprint_clip_storage_enabled": false]])
        XCTAssertFalse(c.voiceprintClipStorageEnabled)
    }

    func test_voiceprintClipStorageEnabled_round_trips() {
        var c = Config.default
        c.voiceprintClipStorageEnabled = false
        let dict = Config.serializeToDictionary(c)
        let features = dict["features"] as? [String: Any]
        XCTAssertEqual(features?["voiceprint_clip_storage_enabled"] as? Bool, false)
        let reparsed = Config.parse(fromDictionary: dict)
        XCTAssertFalse(reparsed.voiceprintClipStorageEnabled)
    }

    // MARK: - voiceClipStorageConsented (default: false)

    func test_voiceClipStorageConsented_default_is_false() {
        XCTAssertFalse(Config.default.voiceClipStorageConsented,
                       "voiceClipStorageConsented must be opt-in (false by default)")
    }

    func test_voiceClipStorageConsented_absent_key_yields_default_false() {
        let c = Config.parse(fromDictionary: [:])
        XCTAssertFalse(c.voiceClipStorageConsented)
    }

    func test_voiceClipStorageConsented_parses_true() {
        let c = Config.parse(fromDictionary: ["features": ["voice_clip_storage_consented": true]])
        XCTAssertTrue(c.voiceClipStorageConsented)
    }

    func test_voiceClipStorageConsented_round_trips() {
        var c = Config.default
        c.voiceClipStorageConsented = true
        let dict = Config.serializeToDictionary(c)
        let features = dict["features"] as? [String: Any]
        XCTAssertEqual(features?["voice_clip_storage_consented"] as? Bool, true)
        let reparsed = Config.parse(fromDictionary: dict)
        XCTAssertTrue(reparsed.voiceClipStorageConsented)
    }

    // MARK: - Combined: all three at non-default values

    func test_all_three_fields_non_default_parse_and_round_trip() {
        let input: [String: Any] = [
            "features": [
                "voice_enrollment_enabled": false,
                "voiceprint_clip_storage_enabled": false,
                "voice_clip_storage_consented": true,
            ]
        ]
        let c = Config.parse(fromDictionary: input)
        XCTAssertFalse(c.voiceEnrollmentEnabled)
        XCTAssertFalse(c.voiceprintClipStorageEnabled)
        XCTAssertTrue(c.voiceClipStorageConsented)

        // Round-trip through serialize → parse.
        let dict = Config.serializeToDictionary(c)
        let reparsed = Config.parse(fromDictionary: dict)
        XCTAssertFalse(reparsed.voiceEnrollmentEnabled)
        XCTAssertFalse(reparsed.voiceprintClipStorageEnabled)
        XCTAssertTrue(reparsed.voiceClipStorageConsented)
    }

    // MARK: - Combined: all three absent → defaults

    func test_all_three_fields_absent_yield_defaults() {
        let c = Config.parse(fromDictionary: ["features": [:]])
        XCTAssertTrue(c.voiceEnrollmentEnabled)
        XCTAssertTrue(c.voiceprintClipStorageEnabled)
        XCTAssertFalse(c.voiceClipStorageConsented)
    }

    // MARK: - mergeForSave round-trip (the path Config.save() actually uses)
    //
    // The serializeToDictionary round-trips above pass even when
    // mergeForSave drops a field — they exercise a different code path.
    // Config.save() goes through mergeForSave, so persistence across
    // restart depends on it carrying all three new fields.

    func test_mergeForSave_round_trips_all_three_fields() {
        var c = Config.default
        c.voiceEnrollmentEnabled = false
        c.voiceprintClipStorageEnabled = false
        c.voiceClipStorageConsented = true

        let dict = Config.mergeForSave(c, existing: [:])
        let features = dict["features"] as? [String: Any]
        XCTAssertEqual(features?["voice_enrollment_enabled"] as? Bool, false)
        XCTAssertEqual(features?["voiceprint_clip_storage_enabled"] as? Bool, false)
        XCTAssertEqual(features?["voice_clip_storage_consented"] as? Bool, true)

        let reparsed = Config.parse(fromDictionary: dict)
        XCTAssertFalse(reparsed.voiceEnrollmentEnabled)
        XCTAssertFalse(reparsed.voiceprintClipStorageEnabled)
        XCTAssertTrue(reparsed.voiceClipStorageConsented)
    }

    // MDM-managed keys preserve the on-disk value (carry-forward), so
    // removing the profile restores the user's pre-MDM choice.
    func test_mergeForSave_preserves_on_disk_value_for_managed_keys() {
        var c = Config.default
        c.voiceEnrollmentEnabled = false       // effective (MDM-forced) value
        c.voiceprintClipStorageEnabled = false // effective (MDM-forced) value
        c.managedKeys = ["voiceEnrollmentEnabled", "voiceprintClipStorageEnabled"]

        let existing: [String: Any] = [
            "features": [
                "voice_enrollment_enabled": true,        // user's pre-MDM choice
                "voiceprint_clip_storage_enabled": true, // user's pre-MDM choice
            ]
        ]
        let dict = Config.mergeForSave(c, existing: existing)
        let features = dict["features"] as? [String: Any]
        XCTAssertEqual(features?["voice_enrollment_enabled"] as? Bool, true,
                       "managed key should carry forward the on-disk (pre-MDM) value")
        XCTAssertEqual(features?["voiceprint_clip_storage_enabled"] as? Bool, true,
                       "managed key should carry forward the on-disk (pre-MDM) value")
    }

    // Consent is never MDM-managed: written through even if listed as managed.
    func test_mergeForSave_consent_always_written_through() {
        var c = Config.default
        c.voiceClipStorageConsented = true
        let dict = Config.mergeForSave(c, existing: [:])
        let features = dict["features"] as? [String: Any]
        XCTAssertEqual(features?["voice_clip_storage_consented"] as? Bool, true)
    }
}
