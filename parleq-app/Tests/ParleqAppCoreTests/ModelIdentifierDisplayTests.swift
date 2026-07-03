import XCTest
@testable import ParleqAppCore

/// Guards the display name used by the header ModelBadge + model picker rows.
/// Provider-level tiers carry an empty `model` field (the on-device Concord
/// "Lightweight" corrector is the main one); before the fix these rendered
/// blank — a nameless checked picker row and an icon-only badge.
final class ModelIdentifierDisplayTests: XCTestCase {

    func test_concord_empty_model_shows_lightweight() {
        XCTAssertEqual(ModelIdentifier(provider: "concord", model: "").displayShort, "Lightweight")
    }

    func test_local_empty_model_shows_on_device() {
        XCTAssertEqual(ModelIdentifier(provider: "local", model: "").displayShort, "On-device")
    }

    func test_unknown_empty_model_falls_back_to_capitalized_provider() {
        XCTAssertEqual(ModelIdentifier(provider: "acme", model: "").displayShort, "Acme")
    }

    /// The normal model-name path is unchanged (prefix-strip + title-case).
    func test_named_model_unchanged() {
        XCTAssertEqual(ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash").displayShort, "2 5 Flash")
        XCTAssertEqual(ModelIdentifier(provider: "bedrock", model: "claude-sonnet-4-5").displayShort, "Sonnet 4 5")
    }
}
