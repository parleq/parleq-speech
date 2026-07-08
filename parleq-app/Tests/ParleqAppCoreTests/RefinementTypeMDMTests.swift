// RefinementTypeMDMTests — the refinement-type MDM key + the fail-closed
// "pinned-none cleanup forces non-cloud refinement" rule (0.43.0).
//
// Since the 0.40.0 reframe, Cleanup and Refinement are independent, so a "none"
// (Raw) cleanup no longer implies zero cloud egress — Polished refinement still
// sends voice-refine turns to a cloud provider. These pin:
//   1. The pure fail-closed truth table (resolveRefinementUnderPinnedNoneCleanup).
//   2. `refinementType` is a recognized managed key (allKeys).
//   3. The pin-application overlay (valid + invalid TargetMode raw values).
//   4. Serialization preservation: a managed refinementType preserves the
//      on-disk value so removing the MDM profile restores the user's choice.
//
// The CFPreferences MDM channel can't be driven in `swift test`, so the pin
// application is simulated inline (the same technique ManagedConfigTests /
// ClipStorageMDMTests use for every other key), while the security-critical
// decision lives in a pure helper exercised directly.

import XCTest
@testable import ParleqAppCore

final class RefinementTypeMDMTests: XCTestCase {

    // MARK: - 1. Fail-closed truth table (the security-critical decision)

    func test_pinned_none_cleanup_forces_polished_refinement_to_raw() {
        let r = ManagedConfig.resolveRefinementUnderPinnedNoneCleanup(
            cleanupPinnedNone: true, refinement: .polished)
        XCTAssertEqual(r.type, .raw, "Polished refinement must be forced to Raw under a zero-cloud lockdown")
        XCTAssertTrue(r.forced, "the rule must report it engaged so the key becomes managed")
    }

    func test_pinned_none_cleanup_leaves_instant_refinement_untouched() {
        // Instant is on-device — no cloud egress — so it survives the lockdown.
        let r = ManagedConfig.resolveRefinementUnderPinnedNoneCleanup(
            cleanupPinnedNone: true, refinement: .instant)
        XCTAssertEqual(r.type, .instant)
        XCTAssertFalse(r.forced)
    }

    func test_pinned_none_cleanup_leaves_raw_refinement_untouched() {
        let r = ManagedConfig.resolveRefinementUnderPinnedNoneCleanup(
            cleanupPinnedNone: true, refinement: .raw)
        XCTAssertEqual(r.type, .raw)
        XCTAssertFalse(r.forced)
    }

    func test_no_lockdown_leaves_polished_refinement_untouched() {
        // Without the "none" cleanup pin, Polished refinement is a legitimate
        // user choice and must NOT be downgraded.
        let r = ManagedConfig.resolveRefinementUnderPinnedNoneCleanup(
            cleanupPinnedNone: false, refinement: .polished)
        XCTAssertEqual(r.type, .polished)
        XCTAssertFalse(r.forced)
    }

    // MARK: - 1b. cleanupLockedToNone — the lockdown trigger (pin AND allowlist)

    func test_lockdown_pin_to_none() {
        XCTAssertTrue(ManagedConfig.cleanupLockedToNone(
            effectiveProvider: "none", providerPinned: true, allowedProviders: nil))
    }

    func test_lockdown_single_entry_allowlist_none() {
        // The bypass the audit caught: cleanupAllowedProviders=["none"] is a
        // functionally-identical zero-cloud lockdown and MUST also trigger.
        XCTAssertTrue(ManagedConfig.cleanupLockedToNone(
            effectiveProvider: "none", providerPinned: false, allowedProviders: ["none"]))
    }

    func test_not_a_lockdown_multi_entry_allowlist_including_none() {
        // The admin permitted a cloud choice; the user just has none selected.
        // Forcing refinement off-cloud here would be over-restrictive.
        XCTAssertFalse(ManagedConfig.cleanupLockedToNone(
            effectiveProvider: "none", providerPinned: false, allowedProviders: ["none", "vertex"]))
    }

    func test_not_a_lockdown_unmanaged_user_chose_none() {
        // No pin, no allowlist — the user chose none cleanup themselves; their
        // Polished refinement stays their own choice.
        XCTAssertFalse(ManagedConfig.cleanupLockedToNone(
            effectiveProvider: "none", providerPinned: false, allowedProviders: nil))
    }

    func test_not_a_lockdown_when_effective_provider_is_not_none() {
        // cleanupProvider pinned to a cloud provider is not a zero-cloud lockdown.
        XCTAssertFalse(ManagedConfig.cleanupLockedToNone(
            effectiveProvider: "vertex", providerPinned: true, allowedProviders: nil))
    }

    func test_allowlist_none_lockdown_forces_polished_refinement_end_to_end() {
        // The two helpers compose: allowlist-["none"] lockdown → Polished forced to Raw.
        let locked = ManagedConfig.cleanupLockedToNone(
            effectiveProvider: "none", providerPinned: false, allowedProviders: ["none"])
        let r = ManagedConfig.resolveRefinementUnderPinnedNoneCleanup(
            cleanupPinnedNone: locked, refinement: .polished)
        XCTAssertEqual(r.type, .raw)
        XCTAssertTrue(r.forced)
    }

    // MARK: - 2. refinementType is a recognized managed key

    func test_allKeys_contains_refinementType() {
        XCTAssertTrue(ManagedConfig.allKeys.contains("refinementType"),
                      "allKeys must contain 'refinementType' so the audit + validation recognize it")
    }

    // MARK: - 3. Pin application (simulated overlay, matching test convention)

    func test_refinementType_pin_valid_value_overrides_and_marks_managed() {
        var c = Config.default
        c.refinementType = .polished   // user's stored choice
        var managedKeys = Set<String>()

        // Simulate: refinementType = "instant" (MDM pin)
        let pinned = "instant"
        if let mode = TargetMode(rawValue: pinned) {
            c.refinementType = mode
            managedKeys.insert("refinementType")
        }

        XCTAssertEqual(c.refinementType, .instant, "valid pin overrides the stored value")
        XCTAssertTrue(managedKeys.contains("refinementType"))
    }

    func test_refinementType_pin_invalid_value_is_ignored() {
        var c = Config.default
        c.refinementType = .polished
        var managedKeys = Set<String>()

        // Simulate: refinementType = "bogus" (unrecognized) → ignored.
        let pinned = "bogus"
        if let mode = TargetMode(rawValue: pinned) {
            c.refinementType = mode
            managedKeys.insert("refinementType")
        }

        XCTAssertEqual(c.refinementType, .polished, "an unrecognized pin must not change the value")
        XCTAssertFalse(managedKeys.contains("refinementType"),
                       "an unrecognized pin must not mark the key managed")
    }

    func test_explicit_polished_pin_still_yields_to_none_cleanup_lockdown() {
        // An admin who pins refinementType=polished AND cleanupProvider=none has
        // a contradictory policy; the lockdown is the stricter, safer one and
        // must win — refinement ends up Raw, and stays managed.
        var c = Config.default
        var managedKeys: Set<String> = ["cleanupProvider", "refinementType"]
        c.llmProvider = "none"
        c.refinementType = .polished   // explicit pin

        let r = ManagedConfig.resolveRefinementUnderPinnedNoneCleanup(
            cleanupPinnedNone: managedKeys.contains("cleanupProvider") && c.llmProvider == "none",
            refinement: c.refinementType)
        if r.forced {
            c.refinementType = r.type
            managedKeys.insert("refinementType")
        }

        XCTAssertEqual(c.refinementType, .raw, "the zero-cloud lockdown wins over an explicit polished pin")
        XCTAssertTrue(managedKeys.contains("refinementType"))
    }

    // MARK: - 4. Serialization preservation (mergeForSave — real seam)

    func test_managed_refinementType_preserves_on_disk_value_on_save() {
        // A pinned/forced refinementType must preserve the user's pre-MDM value
        // on disk, so removing the MDM profile restores their choice — mirror of
        // the refine-tier preservation.
        var c = Config.default
        c.refinementType = .raw               // effective (forced) value in memory
        c.managedKeys = ["refinementType"]

        // On-disk config still carries the user's original "polished" choice.
        let existing: [String: Any] = ["llm": ["refinement": "polished"]]
        let merged = Config.mergeForSave(c, existing: existing)
        let llm = merged["llm"] as? [String: Any]
        XCTAssertEqual(llm?["refinement"] as? String, "polished",
                       "managed refinementType must preserve the on-disk value, not overwrite with the forced value")
    }

    func test_unmanaged_refinementType_writes_in_memory_value_on_save() {
        var c = Config.default
        c.refinementType = .instant
        c.managedKeys = []   // not managed

        let existing: [String: Any] = ["llm": ["refinement": "polished"]]
        let merged = Config.mergeForSave(c, existing: existing)
        let llm = merged["llm"] as? [String: Any]
        XCTAssertEqual(llm?["refinement"] as? String, "instant",
                       "an unmanaged refinementType writes the user's in-memory choice")
    }
}
