import XCTest
@testable import ParleqAppCore

final class TransformPresetsTests: XCTestCase {

    // MARK: - Model + Config fields

    func test_transform_preset_holds_id_name_prompt() {
        let p = TransformPreset(id: "abc", name: "Concise", prompt: "Rewrite concisely.")
        XCTAssertEqual(p.id, "abc")
        XCTAssertEqual(p.name, "Concise")
        XCTAssertEqual(p.prompt, "Rewrite concisely.")
    }

    func test_config_defaults_have_no_presets_and_feature_enabled() {
        let c = Config.default
        XCTAssertTrue(c.transformPresets.isEmpty, "Zero-config users must see no presets")
        XCTAssertTrue(c.presetAppDefaults.isEmpty)
        XCTAssertTrue(c.transformPresetsEnabled, "Feature is on by default; only MDM disables it")
    }

    // MARK: - Parse / save round-trip

    func test_presets_parse_from_top_level_array() throws {
        // JSON input:
        // { "presets": [ {"id": "p1", "name": "Concise", "prompt": "Rewrite concisely."},
        //                {"id": "",   "name": "Bad",     "prompt": "dropped — empty id"},
        //                {"id": "p2", "name": " ",       "prompt": "dropped — blank name"} ],
        //   "preset_app_defaults": { "com.tinyspeck.slackmacgap": "p1", "bad": 7 } }
        // Expect: exactly one preset (p1); mapping keeps only the string-valued entry.
        let input: [String: Any] = [
            "presets": [
                ["id": "p1", "name": "Concise", "prompt": "Rewrite concisely."],
                ["id": "",   "name": "Bad",     "prompt": "dropped — empty id"],
                ["id": "p2", "name": " ",       "prompt": "dropped — blank name"],
            ] as [[String: Any]],
            "preset_app_defaults": [
                "com.tinyspeck.slackmacgap": "p1",
                "bad": 7,
            ] as [String: Any],
        ]
        let c = Config.parseForTesting(input)
        XCTAssertEqual(c.transformPresets.map { $0.id }, ["p1"])
        XCTAssertEqual(c.presetAppDefaults, ["com.tinyspeck.slackmacgap": "p1"])
    }

    func test_config_without_preset_keys_loads_empty() throws {
        // "{}" → transformPresets empty, presetAppDefaults empty, transformPresetsEnabled true
        let c = Config.parseForTesting([:])
        XCTAssertTrue(c.transformPresets.isEmpty)
        XCTAssertTrue(c.presetAppDefaults.isEmpty)
        XCTAssertTrue(c.transformPresetsEnabled)
    }

    func test_presets_round_trip_through_save() throws {
        // Config with one preset (id p1, name Concise) + mapping com.apple.mail→p1,
        // serialized → dict["presets"] has 1 element; dict["preset_app_defaults"]["com.apple.mail"] == "p1"
        var c = Config.default
        c.transformPresets = [TransformPreset(id: "p1", name: "Concise", prompt: "Rewrite concisely.")]
        c.presetAppDefaults = ["com.apple.mail": "p1"]
        let dict = Config.serializeForTesting(c)
        let presets = dict["presets"] as? [[String: Any]]
        XCTAssertEqual(presets?.count, 1)
        XCTAssertEqual(presets?.first?["id"] as? String, "p1")
        XCTAssertEqual(presets?.first?["name"] as? String, "Concise")
        let appDefaults = dict["preset_app_defaults"] as? [String: String]
        XCTAssertEqual(appDefaults?["com.apple.mail"], "p1")
    }

    func test_save_omits_empty_preset_sections() throws {
        // Config.default serialized → dict has NO "presets" key and NO "preset_app_defaults" key
        // (existing configs stay byte-stable when the feature is unused)
        let dict = Config.serializeForTesting(Config.default)
        XCTAssertNil(dict["presets"], "No presets → key must be absent for byte-stability")
        XCTAssertNil(dict["preset_app_defaults"], "No app defaults → key must be absent for byte-stability")
    }
}
