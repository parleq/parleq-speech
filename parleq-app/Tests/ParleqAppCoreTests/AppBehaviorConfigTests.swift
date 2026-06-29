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

    func test_parsing_app_behaviors() throws {
        let c = try parse("""
        {"app_behaviors":{
            "com.apple.Terminal":{"mode":"instant"},
            "com.tinyspeck.slackmacgap":{"mode":"polished","preset":"p1"}
        }}
        """)
        XCTAssertEqual(c.appBehaviors["com.apple.Terminal"]?.mode, .instant)
        XCTAssertNil(c.appBehaviors["com.apple.Terminal"]?.presetID)

        let slack = c.appBehaviors["com.tinyspeck.slackmacgap"]
        XCTAssertEqual(slack?.mode, .polished)
        XCTAssertEqual(slack?.presetID, "p1")
    }

    // MARK: - Migration from the legacy key

    func test_migration_from_legacy_preset_app_defaults() throws {
        let c = try parse("""
        {"preset_app_defaults":{"com.apple.mail":"p2"}}
        """)
        XCTAssertEqual(
            c.appBehaviors["com.apple.mail"],
            AppBehavior(mode: .polished, presetID: "p2")
        )
    }

    func test_app_behaviors_wins_over_legacy_when_both_present() throws {
        // Same bundle in both maps; app_behaviors says Instant, legacy says
        // a polished preset. app_behaviors must win.
        let c = try parse("""
        {
            "app_behaviors":{"com.apple.mail":{"mode":"instant"}},
            "preset_app_defaults":{"com.apple.mail":"p2"}
        }
        """)
        XCTAssertEqual(c.appBehaviors["com.apple.mail"]?.mode, .instant)
        XCTAssertNil(c.appBehaviors["com.apple.mail"]?.presetID)
    }

    func test_legacy_only_bundles_are_merged_in() throws {
        // app_behaviors covers one bundle; a legacy-only bundle must still
        // survive into appBehaviors as a polished+preset entry.
        let c = try parse("""
        {
            "app_behaviors":{"com.apple.Terminal":{"mode":"instant"}},
            "preset_app_defaults":{"com.apple.mail":"p2"}
        }
        """)
        XCTAssertEqual(c.appBehaviors["com.apple.Terminal"]?.mode, .instant)
        XCTAssertEqual(
            c.appBehaviors["com.apple.mail"],
            AppBehavior(mode: .polished, presetID: "p2")
        )
    }

    // MARK: - Unknown mode

    func test_unknown_mode_string_falls_back_to_polished() throws {
        let c = try parse("""
        {"app_behaviors":{"com.apple.mail":{"mode":"bogus"}}}
        """)
        XCTAssertEqual(c.appBehaviors["com.apple.mail"]?.mode, .polished)
    }

    // MARK: - Dual-write on save

    func test_dual_write_on_save() throws {
        // Config.save/load are hardcoded to ~/.parleq/config.json, so exercise
        // the serialize→parse round-trip in memory (the same path save/load
        // use) rather than clobbering the developer's real config.
        var c = Config.default
        c.appBehaviors = [
            "com.apple.mail": AppBehavior(mode: .polished, presetID: "p2"),
            "x": AppBehavior(mode: .instant, presetID: nil),
        ]

        let dict = Config.serializeToDictionary(c)

        // Legacy key dual-written: the polished+preset entry survives; the
        // instant entry has no legacy equivalent.
        let legacy = try XCTUnwrap(dict["preset_app_defaults"] as? [String: String])
        XCTAssertEqual(legacy["com.apple.mail"], "p2")
        XCTAssertNil(legacy["x"])

        // New key round-trips both entries.
        let reloaded = Config.parse(fromDictionary: dict)
        XCTAssertEqual(
            reloaded.appBehaviors["com.apple.mail"],
            AppBehavior(mode: .polished, presetID: "p2")
        )
        XCTAssertEqual(
            reloaded.appBehaviors["x"],
            AppBehavior(mode: .instant, presetID: nil)
        )
    }

    func test_legacy_only_entries_preserved_on_save() throws {
        // A bundle present only in the legacy map (e.g. written by an older
        // build, never migrated into appBehaviors) must not be lost on save.
        var c = Config.default
        c.appBehaviors = ["x": AppBehavior(mode: .instant, presetID: nil)]
        c.presetAppDefaults = ["com.legacy.only": "p9"]

        let dict = Config.serializeToDictionary(c)
        let legacy = try XCTUnwrap(dict["preset_app_defaults"] as? [String: String])
        XCTAssertEqual(legacy["com.legacy.only"], "p9")
    }
}
