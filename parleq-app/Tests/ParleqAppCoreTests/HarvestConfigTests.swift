import XCTest
@testable import ParleqAppCore

/// Task 2 — `voiceprintHarvestEnabled` config key (default true, MDM fail-closed).
/// Mirrors the ClipStorageMDM pattern: the field is a normal Bool consumed only by
/// the #if Concord harvest paths, but the config plumbing itself is trait-independent.
final class HarvestConfigTests: XCTestCase {

    // MARK: - Default + JSON decode

    func test_voiceprintHarvestEnabled_defaults_to_true() {
        XCTAssertTrue(Config.default.voiceprintHarvestEnabled,
                      "Harvest refines only terms the user explicitly enrolled — default ON for enrolled terms.")
    }

    func test_absent_key_decodes_true() {
        // A config written before this feature existed (no features key at all).
        let c = Config.parse(fromDictionary: [:])
        XCTAssertTrue(c.voiceprintHarvestEnabled)
    }

    func test_explicit_false_decodes_false() {
        let c = Config.parse(fromDictionary: ["features": ["voiceprint_harvest_enabled": false]])
        XCTAssertFalse(c.voiceprintHarvestEnabled)
    }

    func test_round_trips_through_serialize() {
        var c = Config.default
        c.voiceprintHarvestEnabled = false
        let dict = Config.serializeToDictionary(c)
        let features = dict["features"] as? [String: Any]
        XCTAssertEqual(features?["voiceprint_harvest_enabled"] as? Bool, false)
        XCTAssertFalse(Config.parse(fromDictionary: dict).voiceprintHarvestEnabled)
    }

    // MARK: - Managed key registration

    func test_allKeys_contains_voiceprintHarvestEnabled() {
        XCTAssertTrue(ManagedConfig.allKeys.contains("voiceprintHarvestEnabled"),
                      "allKeys must contain 'voiceprintHarvestEnabled' so the audit UI marks it")
    }

    // MARK: - MDM fail-closed overlay (reuses the resolveClipStorage present-or-off resolver)

    func test_managed_true_enables_harvest() {
        var c = Config.default
        c.voiceprintHarvestEnabled = false   // user had disabled it
        var managedKeys = Set<String>()
        let r = ManagedConfig.resolveClipStorage(present: true, parsed: true)
        if r.managed { c.voiceprintHarvestEnabled = r.value; managedKeys.insert("voiceprintHarvestEnabled") }
        XCTAssertTrue(c.voiceprintHarvestEnabled)
        XCTAssertTrue(managedKeys.contains("voiceprintHarvestEnabled"))
    }

    func test_managed_false_disables_harvest() {
        var c = Config.default
        var managedKeys = Set<String>()
        let r = ManagedConfig.resolveClipStorage(present: true, parsed: false)
        if r.managed { c.voiceprintHarvestEnabled = r.value; managedKeys.insert("voiceprintHarvestEnabled") }
        XCTAssertFalse(c.voiceprintHarvestEnabled)
        XCTAssertTrue(managedKeys.contains("voiceprintHarvestEnabled"))
    }

    func test_malformed_forced_value_fails_closed() {
        // present=true, parsed=nil (e.g. the string "false" in the plist) → OFF + managed.
        var c = Config.default
        XCTAssertTrue(c.voiceprintHarvestEnabled, "precondition: default true")
        var managedKeys = Set<String>()
        let r = ManagedConfig.resolveClipStorage(present: true, parsed: nil)
        if r.managed { c.voiceprintHarvestEnabled = r.value; managedKeys.insert("voiceprintHarvestEnabled") }
        XCTAssertFalse(c.voiceprintHarvestEnabled, "malformed forced value must fail closed (off)")
        XCTAssertTrue(managedKeys.contains("voiceprintHarvestEnabled"))
    }

    func test_not_managed_preserves_user_value() {
        var c = Config.default
        c.voiceprintHarvestEnabled = false   // user disabled it
        var managedKeys = Set<String>()
        let r = ManagedConfig.resolveClipStorage(present: false, parsed: nil)
        if r.managed { c.voiceprintHarvestEnabled = r.value; managedKeys.insert("voiceprintHarvestEnabled") }
        XCTAssertFalse(c.voiceprintHarvestEnabled, "unmanaged key must not touch the user's stored value")
        XCTAssertFalse(managedKeys.contains("voiceprintHarvestEnabled"))
    }
}
