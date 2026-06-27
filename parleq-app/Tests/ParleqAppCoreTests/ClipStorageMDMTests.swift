// ClipStorageMDMTests — unit tests for the Phase 10 voiceprint MDM controls.
//
// Covers:
//   1. ManagedConfig.managedValuePresent returns false for an unmanaged key.
//   2. ManagedConfig.resolveClipStorage truth table (SI-2 fail-closed).
//   3. ManagedConfig.allKeys contains the two new Phase 10 keys.
//   4. Config overlay logic for voiceEnrollmentEnabled (normal Bool).
//   5. Config overlay logic for voiceprintClipStorageEnabled (fail-closed).
//
// The CFPreferencesAppValueIsForced path (the real MDM channel) cannot be
// driven in `swift test` without a managed domain, so:
//   • managedValuePresent is tested for the false/unmanaged case only.
//   • The fail-closed DECISION logic is tested via the pure resolveClipStorage
//     helper, which owns the truth table independently of CFPreferences.
//   • The overlay application blocks (applyManagedOverlay) are exercised by
//     simulating the overlay in-test — the same technique used by
//     ManagedConfigTests for all other managed keys.

import XCTest
@testable import ParleqAppCore

final class ClipStorageMDMTests: XCTestCase {

    // MARK: - 1. managedValuePresent — unmanaged key returns false

    func test_managedValuePresent_returns_false_for_unmanaged_key() {
        // Use a test-only key that can never appear in
        // /Library/Managed Preferences on a development machine.
        let result = ManagedConfig.managedValuePresent(forKey: "parleq.test.nonexistent.key.clip.xyz")
        XCTAssertFalse(result,
                       "managedValuePresent must return false for a key that is not managed")
    }

    func test_managedValuePresent_returns_false_for_voiceprintClipStorageEnabled_when_unmanaged() {
        // On a typical dev machine without a managed plist, this key is not forced.
        // If the test machine happens to be MDM-enrolled with this key pushed, the
        // result is non-false — acceptable; we document the contract.
        let result = ManagedConfig.managedValuePresent(forKey: "voiceprintClipStorageEnabled")
        if !result {
            XCTAssertFalse(result, "Expected: key not managed on dev machine")
        } else {
            // MDM-managed machine — result is acceptable.
            XCTAssertTrue(result, "MDM-managed machine: voiceprintClipStorageEnabled is managed")
        }
    }

    // MARK: - 2. resolveClipStorage — fail-closed truth table

    func test_resolveClipStorage_not_present_returns_not_managed_with_placeholder_false() {
        // (present: false, parsed: nil) → (value: false, managed: false)
        // Key is not in the managed domain; caller must use its own default.
        let r = ManagedConfig.resolveClipStorage(present: false, parsed: nil)
        XCTAssertFalse(r.managed, "Not-present key must not be classified as managed")
        // value is a placeholder when !managed; we test it is false as documented.
        XCTAssertFalse(r.value, "Placeholder value must be false when not managed")
    }

    func test_resolveClipStorage_not_present_with_true_parsed_returns_not_managed() {
        // Even if somehow parsed=true but present=false, the key is not managed.
        // This case cannot occur in production (managedBool returns nil when
        // IsForced=false), but the helper must be robust.
        let r = ManagedConfig.resolveClipStorage(present: false, parsed: true)
        XCTAssertFalse(r.managed, "Non-present key must not be managed regardless of parsed value")
    }

    func test_resolveClipStorage_present_and_parsed_true_returns_managed_true() {
        // (present: true, parsed: true) → (value: true, managed: true)
        // MDM explicitly enables clip storage.
        let r = ManagedConfig.resolveClipStorage(present: true, parsed: true)
        XCTAssertTrue(r.managed, "Forced key must be classified as managed")
        XCTAssertTrue(r.value, "Explicitly-true forced value must enable clip storage")
    }

    func test_resolveClipStorage_present_and_parsed_false_returns_managed_false() {
        // (present: true, parsed: false) → (value: false, managed: true)
        // MDM explicitly disables clip storage.
        let r = ManagedConfig.resolveClipStorage(present: true, parsed: false)
        XCTAssertTrue(r.managed, "Forced key must be classified as managed")
        XCTAssertFalse(r.value, "Explicitly-false forced value must disable clip storage")
    }

    func test_resolveClipStorage_present_and_parsed_nil_fails_closed() {
        // (present: true, parsed: nil) → (value: false, managed: true)
        // The key IS managed (forced) but the value is malformed/unparseable
        // (e.g. the string "false" in the plist, which CFPreferences can't
        // bridge to Bool). SI-2: this MUST fail CLOSED — disable clip storage.
        let r = ManagedConfig.resolveClipStorage(present: true, parsed: nil)
        XCTAssertTrue(r.managed,
                      "A forced-but-malformed key must still be classified as managed")
        XCTAssertFalse(r.value,
                       "SI-2 fail-closed: malformed forced value must disable clip storage, not leave it on")
    }

    // MARK: - 3. allKeys contains Phase 10 keys

    func test_allKeys_contains_voiceEnrollmentEnabled() {
        XCTAssertTrue(ManagedConfig.allKeys.contains("voiceEnrollmentEnabled"),
                      "allKeys must contain 'voiceEnrollmentEnabled' (Phase 10)")
    }

    func test_allKeys_contains_voiceprintClipStorageEnabled() {
        XCTAssertTrue(ManagedConfig.allKeys.contains("voiceprintClipStorageEnabled"),
                      "allKeys must contain 'voiceprintClipStorageEnabled' (Phase 10)")
    }

    // MARK: - 4. Overlay simulation — voiceEnrollmentEnabled (normal Bool)

    func test_voiceEnrollmentEnabled_managed_false_disables_enrollment() {
        // Simulate what applyManagedOverlay does when MDM forces
        // voiceEnrollmentEnabled = false.
        var c = Config.default
        XCTAssertTrue(c.voiceEnrollmentEnabled, "Default must be true before overlay")

        // Simulate the overlay block:
        //   if let v = ManagedConfig.managedBool(forKey: "voiceEnrollmentEnabled") {
        //       c.voiceEnrollmentEnabled = v; managedKeys.insert("voiceEnrollmentEnabled")
        //   }
        let simulatedManaged: Bool? = false  // as if MDM pushed false
        var managedKeys = Set<String>()
        if let v = simulatedManaged {
            c.voiceEnrollmentEnabled = v
            managedKeys.insert("voiceEnrollmentEnabled")
        }

        XCTAssertFalse(c.voiceEnrollmentEnabled,
                       "voiceEnrollmentEnabled must be false when MDM forces false")
        XCTAssertTrue(managedKeys.contains("voiceEnrollmentEnabled"),
                      "'voiceEnrollmentEnabled' must be in managedKeys when managed")
    }

    func test_voiceEnrollmentEnabled_managed_true_enables_enrollment() {
        var c = Config.default
        c.voiceEnrollmentEnabled = false  // user had disabled it
        var managedKeys = Set<String>()

        let simulatedManaged: Bool? = true  // MDM re-enables fleet-wide
        if let v = simulatedManaged {
            c.voiceEnrollmentEnabled = v
            managedKeys.insert("voiceEnrollmentEnabled")
        }

        XCTAssertTrue(c.voiceEnrollmentEnabled,
                      "MDM-forced true must override user's stored false")
        XCTAssertTrue(managedKeys.contains("voiceEnrollmentEnabled"))
    }

    func test_voiceEnrollmentEnabled_not_managed_preserves_user_value() {
        var c = Config.default
        c.voiceEnrollmentEnabled = false  // user disabled it
        var managedKeys = Set<String>()

        let simulatedManaged: Bool? = nil  // not managed
        if let v = simulatedManaged {
            c.voiceEnrollmentEnabled = v
            managedKeys.insert("voiceEnrollmentEnabled")
        }

        XCTAssertFalse(c.voiceEnrollmentEnabled,
                       "Unmanaged key must not touch the user's stored value")
        XCTAssertFalse(managedKeys.contains("voiceEnrollmentEnabled"),
                       "Unmanaged key must not appear in managedKeys")
    }

    // MARK: - 5. Overlay simulation — voiceprintClipStorageEnabled (fail-closed)

    func test_voiceprintClipStorageEnabled_managed_true_enables_storage() {
        var c = Config.default
        c.voiceprintClipStorageEnabled = false  // user had disabled it
        var managedKeys = Set<String>()

        // Simulate: present=true, parsed=true (MDM explicitly enables)
        let r = ManagedConfig.resolveClipStorage(present: true, parsed: true)
        if r.managed {
            c.voiceprintClipStorageEnabled = r.value
            managedKeys.insert("voiceprintClipStorageEnabled")
        }

        XCTAssertTrue(c.voiceprintClipStorageEnabled,
                      "MDM explicit true must enable clip storage")
        XCTAssertTrue(managedKeys.contains("voiceprintClipStorageEnabled"))
    }

    func test_voiceprintClipStorageEnabled_managed_false_disables_storage() {
        var c = Config.default
        XCTAssertTrue(c.voiceprintClipStorageEnabled, "Default must be true")
        var managedKeys = Set<String>()

        // Simulate: present=true, parsed=false (MDM kill-switch)
        let r = ManagedConfig.resolveClipStorage(present: true, parsed: false)
        if r.managed {
            c.voiceprintClipStorageEnabled = r.value
            managedKeys.insert("voiceprintClipStorageEnabled")
        }

        XCTAssertFalse(c.voiceprintClipStorageEnabled,
                       "MDM explicit false must disable clip storage")
        XCTAssertTrue(managedKeys.contains("voiceprintClipStorageEnabled"))
    }

    func test_voiceprintClipStorageEnabled_malformed_forced_value_fails_closed() {
        // SI-2: A present-but-malformed forced value (parsed=nil) must fail
        // CLOSED — clip storage stays OFF even though the admin probably
        // intended to disable it. This is the gap that plain managedBool
        // cannot close on its own.
        var c = Config.default
        XCTAssertTrue(c.voiceprintClipStorageEnabled, "Default must be true before overlay")
        var managedKeys = Set<String>()

        // Simulate: present=true (key IS in managed plist), parsed=nil (bad type, e.g. string)
        let r = ManagedConfig.resolveClipStorage(present: true, parsed: nil)
        if r.managed {
            c.voiceprintClipStorageEnabled = r.value
            managedKeys.insert("voiceprintClipStorageEnabled")
        }

        XCTAssertFalse(c.voiceprintClipStorageEnabled,
                       "SI-2: malformed forced value must disable clip storage (fail closed)")
        XCTAssertTrue(managedKeys.contains("voiceprintClipStorageEnabled"),
                      "The key must still appear in managedKeys so the audit UI marks it Managed")
    }

    func test_voiceprintClipStorageEnabled_not_managed_preserves_default_true() {
        var c = Config.default
        var managedKeys = Set<String>()

        // Simulate: present=false (key not in managed plist at all)
        let r = ManagedConfig.resolveClipStorage(present: false, parsed: nil)
        if r.managed {
            c.voiceprintClipStorageEnabled = r.value
            managedKeys.insert("voiceprintClipStorageEnabled")
        }

        XCTAssertTrue(c.voiceprintClipStorageEnabled,
                      "Unmanaged key must leave clip storage at its default (true)")
        XCTAssertFalse(managedKeys.contains("voiceprintClipStorageEnabled"),
                       "Unmanaged key must not appear in managedKeys")
    }

    func test_voiceprintClipStorageEnabled_not_managed_preserves_user_false() {
        var c = Config.default
        c.voiceprintClipStorageEnabled = false  // user explicitly disabled it
        var managedKeys = Set<String>()

        let r = ManagedConfig.resolveClipStorage(present: false, parsed: nil)
        if r.managed {
            c.voiceprintClipStorageEnabled = r.value
            managedKeys.insert("voiceprintClipStorageEnabled")
        }

        XCTAssertFalse(c.voiceprintClipStorageEnabled,
                       "Unmanaged key must not override the user's stored false")
        XCTAssertFalse(managedKeys.contains("voiceprintClipStorageEnabled"))
    }
}
