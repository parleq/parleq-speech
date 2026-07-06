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

    /// The normal model-name path strips known provider prefixes and
    /// title-cases hyphen-separated remainder, but LEAVES DOTS ALONE so
    /// version numbers survive ("2.5", not "2 5").
    func test_named_model_unchanged() {
        XCTAssertEqual(ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash").displayShort, "2.5 Flash")
        XCTAssertEqual(ModelIdentifier(provider: "vertex", model: "gemini-2.5-flash").displayShort, "2.5 Flash")
        XCTAssertEqual(ModelIdentifier(provider: "bedrock", model: "claude-sonnet-4-5").displayShort, "Sonnet 4 5")
    }

    /// A claude model id (no recognized provider prefix stripped, since
    /// "claude-" IS a recognized prefix here) keeps its shape otherwise —
    /// hyphens become spaces, title-cased, dots preserved.
    func test_claude_model_keeps_shape() {
        XCTAssertEqual(
            ModelIdentifier(provider: "vertex", model: "claude-sonnet-4-5@20250929").displayShort,
            "Sonnet 4 5@20250929")
    }

    /// On-device models are identified by a raw HF checkpoint id
    /// ("mlx-community/Qwen3-4B-Instruct-2507-4bit"). Before the fix,
    /// humanizing that string produced "Mlx Community/Qwen3 4B Instruct 2507
    /// 4bit" — displayShort must instead defer to the catalog's curated
    /// `displayName` for the local provider.
    func test_local_named_model_uses_catalog_display_name() {
        XCTAssertEqual(
            ModelIdentifier(provider: "local", model: "mlx-community/Qwen3-4B-Instruct-2507-4bit").displayShort,
            "Qwen3-4B")
        XCTAssertEqual(
            ModelIdentifier(provider: "local", model: "mlx-community/gemma-4-E4B-it-qat-4bit").displayShort,
            "Gemma 4 E4B")
    }

    /// An unrecognized local checkpoint id falls back to the catalog default
    /// (LocalModelCatalog.model(for:) itself falls back), not a humanized
    /// mangling of the raw id.
    func test_local_unknown_checkpoint_falls_back_to_catalog_default() {
        XCTAssertEqual(
            ModelIdentifier(provider: "local", model: "some-unknown-checkpoint").displayShort,
            LocalModelCatalog.default.displayName)
    }
}
