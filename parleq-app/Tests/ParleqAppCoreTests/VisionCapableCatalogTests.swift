// VisionCapableCatalogTests — per-provider member lists.
//
// Pins the exact set of vision-capable models each provider exposes
// so that adding or removing a model is a deliberate, test-visible
// change. Uses Set comparisons so test is order-independent.

import XCTest
@testable import ParleqAppCore

final class VisionCapableCatalogTests: XCTestCase {

    // MARK: - Gemini (direct Google AI API)

    func test_gemini_vision_models_count_and_members() {
        let models = VisionCapableCatalog.visionModels(forProvider: "gemini")
        let modelNames = Set(models.map(\.model))
        XCTAssertEqual(models.count, 2)
        XCTAssertTrue(modelNames.contains("gemini-2.5-flash"), "Gemini catalog must include 2.5 Flash")
        XCTAssertTrue(modelNames.contains("gemini-2.5-pro"), "Gemini catalog must include 2.5 Pro")
        // Retired 1.5 family must not appear.
        XCTAssertFalse(modelNames.contains(where: { $0.contains("1.5") }), "Retired Gemini 1.5 must not appear in catalog")
    }

    func test_gemini_vision_models_provider_field() {
        let models = VisionCapableCatalog.visionModels(forProvider: "gemini")
        for m in models {
            XCTAssertEqual(m.provider, "gemini", "All Gemini catalog entries should carry provider 'gemini'")
        }
    }

    func test_gemini_provider_case_insensitive() {
        // The catalog switches on provider.lowercased() — verify upper-case input works.
        let lower = VisionCapableCatalog.visionModels(forProvider: "gemini")
        let upper = VisionCapableCatalog.visionModels(forProvider: "GEMINI")
        XCTAssertEqual(lower, upper, "Provider lookup should be case-insensitive")
    }

    // MARK: - Vertex (Google Cloud Vertex AI)

    func test_vertex_vision_models_count_and_members() {
        let models = VisionCapableCatalog.visionModels(forProvider: "vertex")
        let modelNames = Set(models.map(\.model))
        XCTAssertEqual(models.count, 2)
        XCTAssertTrue(modelNames.contains("gemini-2.5-flash"), "Vertex catalog must include Gemini 2.5 Flash")
        XCTAssertTrue(modelNames.contains("gemini-2.5-pro"), "Vertex catalog must include Gemini 2.5 Pro")
        // Claude was removed from Vertex's curated list due to region constraints.
        XCTAssertFalse(modelNames.contains(where: { $0.contains("claude") }), "Claude must not appear in Vertex curated catalog (region issue)")
    }

    // MARK: - Bedrock (AWS Bedrock with SigV4 auth)

    func test_bedrock_vision_models_count_and_members() {
        let models = VisionCapableCatalog.visionModels(forProvider: "bedrock")
        let modelNames = Set(models.map(\.model))
        XCTAssertEqual(models.count, 2)
        XCTAssertTrue(
            modelNames.contains("us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
            "Bedrock catalog must include cross-region Sonnet 4-5 profile ID"
        )
        XCTAssertTrue(
            modelNames.contains("us.anthropic.claude-haiku-4-5-20251001-v1:0"),
            "Bedrock catalog must include cross-region Haiku 4-5 profile ID"
        )
    }

    func test_bedrock_vision_models_use_cross_region_profile_ids() {
        // Cross-region inference profile IDs start with "us." — verify
        // we're not accidentally using bare model IDs here.
        let models = VisionCapableCatalog.visionModels(forProvider: "bedrock")
        for m in models {
            XCTAssertTrue(m.model.hasPrefix("us."), "Bedrock vision models must use cross-region inference profile IDs (us. prefix); got \(m.model)")
        }
    }

    // MARK: - Bedrock-bearer (AWS Bedrock with bearer token auth)

    func test_bedrock_bearer_vision_models_match_bedrock() {
        // bedrock and bedrock-bearer share the same model set; only
        // the auth mechanism differs.
        let bedrock = VisionCapableCatalog.visionModels(forProvider: "bedrock")
        let bearer = VisionCapableCatalog.visionModels(forProvider: "bedrock-bearer")
        let bedrockModels = Set(bedrock.map(\.model))
        let bearerModels = Set(bearer.map(\.model))
        XCTAssertEqual(bedrockModels, bearerModels, "bedrock and bedrock-bearer vision catalogs must contain the same model IDs")
        XCTAssertEqual(bearer.count, 2)
    }

    func test_bedrock_bearer_provider_field() {
        let models = VisionCapableCatalog.visionModels(forProvider: "bedrock-bearer")
        for m in models {
            XCTAssertEqual(m.provider, "bedrock-bearer", "bedrock-bearer entries should carry 'bedrock-bearer' provider field")
        }
    }

    // MARK: - Azure (Azure OpenAI Service)

    func test_azure_vision_models_count_and_members() {
        let models = VisionCapableCatalog.visionModels(forProvider: "azure")
        let modelNames = Set(models.map(\.model))
        XCTAssertEqual(models.count, 4, "Azure catalog should have exactly 4 vision-capable models post-Batch-A fix")
        XCTAssertTrue(modelNames.contains("gpt-4o"), "Azure catalog must include gpt-4o")
        XCTAssertTrue(modelNames.contains("gpt-4o-mini"), "Azure catalog must include gpt-4o-mini")
        XCTAssertTrue(modelNames.contains("gpt-4.1"), "Azure catalog must include gpt-4.1")
        XCTAssertTrue(modelNames.contains("gpt-4.1-mini"), "Azure catalog must include gpt-4.1-mini")
    }

    func test_azure_nano_is_not_in_catalog() {
        // gpt-4.1-nano is text-only on Azure — must not appear.
        let models = VisionCapableCatalog.visionModels(forProvider: "azure")
        let modelNames = Set(models.map(\.model))
        XCTAssertFalse(modelNames.contains("gpt-4.1-nano"), "gpt-4.1-nano is text-only and must not appear in Azure vision catalog")
    }

    // MARK: - Unknown provider

    func test_unknown_provider_returns_empty_list() {
        let models = VisionCapableCatalog.visionModels(forProvider: "openai")
        XCTAssertTrue(models.isEmpty, "Unknown provider 'openai' should return empty vision model list")
    }

    func test_empty_string_provider_returns_empty_list() {
        let models = VisionCapableCatalog.visionModels(forProvider: "")
        XCTAssertTrue(models.isEmpty, "Empty provider string should return empty vision model list")
    }
}
