import XCTest
@testable import ParleqAppCore

final class AppBehaviorConfigTests: XCTestCase {
    // MARK: - Helpers

    /// Parse a JSON object string the same way Config.load would, but
    /// without touching ~/.parleq/config.json on disk.
    private func parse(_ json: String) throws -> Config {
        let data = json.data(using: .utf8)!
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return Config.parse(fromDictionary: obj)
    }

    // MARK: - Parsing the new key

    func test_parsing_app_behaviors_stores_mode_and_folds_preset() throws {
        // Terminal is a mode-only Instant override. Slack carries a native
        // `preset`, which must be folded into presetAppDefaults (the single
        // source of truth) rather than duplicated into appBehaviors.
        let c = try parse("""
        {"app_behaviors":{
            "com.apple.Terminal":{"mode":"instant"},
            "com.tinyspeck.slackmacgap":{"mode":"polished","preset":"p1"}
        }}
        """)
        XCTAssertEqual(c.appBehaviors["com.apple.Terminal"]?.mode, .instant)

        // The native preset lives in presetAppDefaults, not appBehaviors.
        XCTAssertEqual(c.presetAppDefaults["com.tinyspeck.slackmacgap"], "p1")
        XCTAssertNil(c.appBehaviors["com.tinyspeck.slackmacgap"]?.presetID)
        XCTAssertEqual(c.appBehaviors["com.tinyspeck.slackmacgap"]?.mode, .polished)
    }

    // MARK: - Migration from the legacy key

    func test_migration_preserves_legacy_preset_without_duplication() throws {
        // A non-curated app (Mail defaults to Polished) keeps its legacy preset
        // in presetAppDefaults; no appBehaviors entry is synthesized (the
        // default mode is already Polished), so the two maps don't duplicate.
        let c = try parse("""
        {"preset_app_defaults":{"com.apple.mail":"p2"}}
        """)
        XCTAssertEqual(c.presetAppDefaults["com.apple.mail"], "p2")
        XCTAssertNil(c.appBehaviors["com.apple.mail"])
        XCTAssertEqual(c.behaviorForApp("com.apple.mail").mode, .polished)
    }

    func test_migration_preserves_polished_intent_over_curated_instant() throws {
        // A curated-Instant app (Terminal) that the user had styled under the
        // old system must STAY Polished (intent preserved), via a mode-only
        // override — not silently flipped to Instant. The preset stays in
        // presetAppDefaults.
        let c = try parse("""
        {"preset_app_defaults":{"com.apple.Terminal":"p2"}}
        """)
        XCTAssertEqual(c.appBehaviors["com.apple.Terminal"]?.mode, .polished)
        XCTAssertNil(c.appBehaviors["com.apple.Terminal"]?.presetID)
        XCTAssertEqual(c.presetAppDefaults["com.apple.Terminal"], "p2")
        XCTAssertEqual(c.behaviorForApp("com.apple.Terminal").mode, .polished)
    }

    func test_app_behaviors_wins_over_legacy_when_both_present() throws {
        let c = try parse("""
        {
            "app_behaviors":{"com.apple.mail":{"mode":"instant"}},
            "preset_app_defaults":{"com.apple.mail":"p2"}
        }
        """)
        XCTAssertEqual(c.behaviorForApp("com.apple.mail").mode, .instant)
        // Instant never carries a preset, even though a legacy one exists.
        XCTAssertNil(c.behaviorForApp("com.apple.mail").presetID)
    }

    // MARK: - Unknown mode

    func test_unknown_mode_string_falls_back_to_polished() throws {
        let c = try parse("""
        {"app_behaviors":{"com.apple.mail":{"mode":"bogus"}}}
        """)
        XCTAssertEqual(c.appBehaviors["com.apple.mail"]?.mode, .polished)
    }

    // MARK: - Serialize (dual-key) + no-drift / no-resurrection

    func test_serialize_writes_both_keys_authoritatively() throws {
        var c = Config.default
        c.presetAppDefaults = ["com.apple.mail": "p2"]      // preset source of truth
        c.appBehaviors = ["x": AppBehavior(mode: .instant)] // new mode dimension

        let dict = Config.serializeToDictionary(c)

        // preset_app_defaults is written verbatim from presetAppDefaults.
        let legacy = try XCTUnwrap(dict["preset_app_defaults"] as? [String: String])
        XCTAssertEqual(legacy["com.apple.mail"], "p2")
        XCTAssertNil(legacy["x"])

        // app_behaviors carries the Instant entry (no legacy equivalent).
        let behaviors = try XCTUnwrap(dict["app_behaviors"] as? [String: Any])
        let xObj = try XCTUnwrap(behaviors["x"] as? [String: Any])
        XCTAssertEqual(xObj["mode"] as? String, "instant")

        // Round-trips.
        let reloaded = Config.parse(fromDictionary: dict)
        XCTAssertEqual(reloaded.presetAppDefaults["com.apple.mail"], "p2")
        XCTAssertEqual(reloaded.appBehaviors["x"]?.mode, .instant)
    }

    func test_deleted_preset_is_not_resurrected_on_save() throws {
        // Regression for the dual-source-of-truth drift: parse a legacy preset
        // for a curated-Instant app (synthesizes a Polished override), then
        // simulate the Settings UI deleting the preset (mutates presetAppDefaults
        // only). Serializing must NOT write the deleted preset back out.
        var c = try parse("""
        {"preset_app_defaults":{"com.apple.Terminal":"p2"}}
        """)
        XCTAssertEqual(c.appBehaviors["com.apple.Terminal"]?.mode, .polished) // override present

        c.presetAppDefaults = [:] // user deletes the per-app preset

        let dict = Config.serializeToDictionary(c)
        let legacy = dict["preset_app_defaults"] as? [String: String] ?? [:]
        XCTAssertNil(legacy["com.apple.Terminal"], "deleted preset must not be resurrected")
    }

    func test_legacy_only_entries_preserved_on_save() throws {
        var c = Config.default
        c.appBehaviors = ["x": AppBehavior(mode: .instant)]
        c.presetAppDefaults = ["com.legacy.only": "p9"]

        let dict = Config.serializeToDictionary(c)
        let legacy = try XCTUnwrap(dict["preset_app_defaults"] as? [String: String])
        XCTAssertEqual(legacy["com.legacy.only"], "p9")
    }
}
