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
}
