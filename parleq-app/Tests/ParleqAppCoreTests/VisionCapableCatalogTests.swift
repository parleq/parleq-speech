// VisionCapableCatalogTests — the wizard's vision-capable model list is
// DERIVED from ModelCatalog filtered by ModelCapability.supportsVision
// (0.47.1), so these tests pin the derivation rather than a hand list.

import XCTest
@testable import ParleqAppCore

final class VisionCapableCatalogTests: XCTestCase {

    private func ids(_ provider: String) -> [String] {
        VisionCapableCatalog.visionModels(forProvider: provider).map(\.model)
    }

    // MARK: - Derivation invariants

    func test_every_vision_model_is_canonical_and_vision_capable() {
        for provider in ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"] {
            for id in VisionCapableCatalog.visionModels(forProvider: provider) {
                XCTAssertEqual(id.provider, provider)
                XCTAssertTrue(ModelCatalog.isCanonical(provider: provider, model: id.model),
                              "\(provider)/\(id.model) must be in the curated catalog")
                XCTAssertTrue(ModelCapability.supportsVision(id),
                              "\(provider)/\(id.model) must be vision-capable")
            }
        }
    }

    func test_order_follows_catalog_order() {
        for provider in ["gemini", "vertex", "bedrock", "azure", "openai"] {
            let catalog = ModelCatalog.models(forProvider: provider)
            let vision = ids(provider)
            let positions = vision.compactMap { catalog.firstIndex(of: $0) }
            XCTAssertEqual(positions, positions.sorted(), "\(provider) vision list must keep catalog order")
        }
    }

    // MARK: - Per-provider membership

    func test_gemini_all_three_picks_are_vision_capable() {
        XCTAssertEqual(ids("gemini"), ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-4-argon"])
    }

    func test_gemini_provider_case_insensitive() {
        XCTAssertEqual(VisionCapableCatalog.visionModels(forProvider: "GEMINI"),
                       VisionCapableCatalog.visionModels(forProvider: "gemini"))
    }

    func test_vertex_includes_gemini_and_claude() {
        XCTAssertEqual(ids("vertex"), [
            "gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-4-argon",
            "claude-haiku-5-5", "claude-sonnet-5-5",
        ])
    }

    func test_bedrock_excludes_text_only_models() {
        let models = ids("bedrock")
        XCTAssertTrue(models.contains("us.anthropic.claude-haiku-5-5"))
        XCTAssertTrue(models.contains("us.anthropic.claude-sonnet-5-5"))
        XCTAssertFalse(models.contains("openai.gpt-oss-120b-1:0"), "GPT-OSS is text-only")
        XCTAssertFalse(models.contains("us.amazon.nova-micro-v1:0"), "Nova Micro is text-only")
    }

    func test_bedrock_bearer_matches_bedrock() {
        XCTAssertEqual(ids("bedrock-bearer"), ids("bedrock"))
    }

    func test_azure_includes_new_and_legacy_labels() {
        // gpt-4.1-nano is in the Azure catalog but text-only, so absent here.
        XCTAssertEqual(ids("azure"), [
            "gpt-6-luna", "gpt-6.1-terra", "gpt-6.1-sol",
            "gpt-4o-mini", "gpt-4o", "gpt-4.1", "gpt-4.1-mini",
        ])
    }

    func test_openai_lists_current_lineup() {
        XCTAssertEqual(ids("openai"), ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.1-sol"])
    }

    func test_unknown_provider_returns_empty_list() {
        XCTAssertTrue(VisionCapableCatalog.visionModels(forProvider: "unknown-provider-xyz").isEmpty)
    }

    func test_empty_string_provider_returns_empty_list() {
        XCTAssertTrue(VisionCapableCatalog.visionModels(forProvider: "").isEmpty)
    }
}
