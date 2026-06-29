import XCTest
@testable import ParleqAppCore

final class CuratedAppDefaultsTests: XCTestCase {
    // MARK: - Curated mode lookup

    func test_curated_terminal_is_instant() {
        XCTAssertEqual(CuratedAppDefaults.mode(for: "com.apple.Terminal"), .instant)
    }

    func test_curated_spreadsheet_is_instant() {
        XCTAssertEqual(CuratedAppDefaults.mode(for: "com.microsoft.Excel"), .instant)
        XCTAssertEqual(CuratedAppDefaults.mode(for: "com.apple.iWork.Numbers"), .instant)
    }

    func test_jetbrains_prefix_is_instant() {
        // JetBrains IDEs share a com.jetbrains.* prefix.
        XCTAssertEqual(CuratedAppDefaults.mode(for: "com.jetbrains.intellij"), .instant)
        XCTAssertEqual(CuratedAppDefaults.mode(for: "com.jetbrains.pycharm"), .instant)
    }

    func test_curated_communication_is_polished() {
        XCTAssertEqual(CuratedAppDefaults.mode(for: "com.tinyspeck.slackmacgap"), .polished)
    }

    func test_unknown_app_has_no_curated_mode() {
        XCTAssertNil(CuratedAppDefaults.mode(for: "com.example.unknown"))
    }

    // MARK: - Suggested tone (suggested, never auto-applied)

    func test_slack_suggested_tone_is_friendly_concise() {
        XCTAssertEqual(CuratedAppDefaults.suggestedTone(for: "com.tinyspeck.slackmacgap"), .friendlyConcise)
    }

    func test_mail_suggested_tone_is_professional() {
        XCTAssertEqual(CuratedAppDefaults.suggestedTone(for: "com.apple.mail"), .professional)
    }

    func test_terminal_has_no_suggested_tone() {
        XCTAssertNil(CuratedAppDefaults.suggestedTone(for: "com.apple.Terminal"))
    }

    // MARK: - behaviorForApp resolution order

    func test_behaviorForApp_unknown_is_polished_no_preset() {
        let c = Config.default
        let b = c.behaviorForApp("com.example.unknown")
        XCTAssertEqual(b.mode, .polished)
        XCTAssertNil(b.presetID)
    }

    func test_behaviorForApp_nil_bundle_is_polished() {
        XCTAssertEqual(Config.default.behaviorForApp(nil).mode, .polished)
    }

    func test_behaviorForApp_uses_curated_mode_when_no_override() {
        XCTAssertEqual(Config.default.behaviorForApp("com.apple.Terminal").mode, .instant)
    }

    func test_behaviorForApp_user_override_beats_curated() {
        var c = Config.default
        c.appBehaviors["com.apple.Terminal"] = AppBehavior(mode: .polished, presetID: nil)
        let b = c.behaviorForApp("com.apple.Terminal")
        XCTAssertEqual(b.mode, .polished)
        XCTAssertNil(b.presetID)
    }

    func test_behaviorForApp_never_applies_a_suggested_tone() {
        // Slack has a suggested tone, but with no user override the resolver
        // must return Polished with NO preset — suggestions are never
        // auto-applied.
        let b = Config.default.behaviorForApp("com.tinyspeck.slackmacgap")
        XCTAssertEqual(b.mode, .polished)
        XCTAssertNil(b.presetID)
    }
}
