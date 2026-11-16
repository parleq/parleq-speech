// ModelDeprecationMigrationTests — 0.47.1 model refresh: retired-model
// rewrite at config load, Vertex `global` routing, Gemini 3+ thinkingLevel,
// and gpt-5/gpt-6 reasoning-shape detection.

import XCTest
@testable import ParleqAppCore

final class ModelDeprecationMigrationTests: XCTestCase {

    // MARK: - Retired-model rewrite

    func test_gemini_25_ids_migrate_to_successors() {
        for (old, new) in [("gemini-2.5-flash", "gemini-3.5-flash-lite"),
                           ("gemini-2.5-flash-lite", "gemini-3.5-flash-lite"),
                           ("gemini-2.5-pro", "gemini-4-argon")] {
            var c = Config.default
            c.llmProvider = "gemini"
            c.llmModel = old
            Config.migrateRetiredModels(&c)
            XCTAssertEqual(c.llmModel, new, "\(old) should migrate to \(new)")
        }
    }

    func test_every_replacement_target_is_canonical() {
        for (provider, map) in ModelCatalog.retiredModelReplacements {
            for (old, new) in map {
                XCTAssertTrue(ModelCatalog.isCanonical(provider: provider, model: new),
                              "\(provider): \(old) → \(new) must target a curated model")
                XCTAssertFalse(ModelCatalog.isCanonical(provider: provider, model: old),
                               "\(provider): retired \(old) must not still be curated")
            }
        }
    }

    func test_migration_is_idempotent_and_ignores_current_ids() {
        var c = Config.default
        c.llmProvider = "gemini"
        c.llmModel = "gemini-3.8-flash"
        Config.migrateRetiredModels(&c)
        Config.migrateRetiredModels(&c)
        XCTAssertEqual(c.llmModel, "gemini-3.8-flash")
    }

    func test_custom_dated_ids_are_left_alone() {
        var c = Config.default
        c.llmProvider = "openai"
        c.llmModel = "gpt-4o-2024-11-20"
        Config.migrateRetiredModels(&c)
        XCTAssertEqual(c.llmModel, "gpt-4o-2024-11-20", "only exact retired IDs are rewritten")
    }

    func test_azure_labels_are_never_rewritten() {
        var c = Config.default
        c.llmProvider = "azure"
        c.llmModel = "o4-mini"
        Config.migrateRetiredModels(&c)
        XCTAssertEqual(c.llmModel, "o4-mini", "Azure model is a deployment label, not a routing key")
    }

    func test_context_and_refine_tiers_migrate() {
        var c = Config.default
        c.llmProvider = "concord"
        c.llmModel = ""
        c.contextModel = ModelIdentifier(provider: "bedrock", model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
        c.refineModel = ModelIdentifier(provider: "openai", model: "o3-mini")
        Config.migrateRetiredModels(&c)
        XCTAssertEqual(c.contextModel?.model, "us.anthropic.claude-sonnet-5-5")
        XCTAssertEqual(c.refineModel?.model, "gpt-6.1-sol")
    }

    func test_azure_live_legacy_labels_stay_canonical() {
        // Dropping a still-served Azure label would let the
        // customModelEntryEnabled=false scrub flip it to gpt-6-luna and send
        // that standard deployment reasoning-shape params (400).
        for m in ["gpt-4o-mini", "gpt-4o", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"] {
            XCTAssertTrue(ModelCatalog.isCanonical(provider: "azure", model: m), m)
        }
    }

    // MARK: - MDM allowlist expansion

    func test_allowlist_expansion_adds_successors_and_keeps_originals() {
        XCTAssertEqual(ModelCatalog.expandingRetiredModels(["gemini-2.5-flash", "gpt-4o-mini"]),
                       ["gemini-2.5-flash", "gemini-3.5-flash-lite", "gpt-4o-mini", "gpt-6-luna"],
                       "gpt-4o-mini stays: it is still a live Azure label")
    }

    func test_allowlist_expansion_dedupes_and_ignores_current_ids() {
        XCTAssertEqual(ModelCatalog.expandingRetiredModels(["gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-3.8-flash"]),
                       ["gemini-2.5-flash", "gemini-3.5-flash-lite", "gemini-2.5-flash-lite", "gemini-3.8-flash"])
        XCTAssertEqual(ModelCatalog.expandingRetiredModels(["gemini-3.8-flash"]), ["gemini-3.8-flash"])
    }

    // MARK: - Vertex location migration

    func test_vertex_old_default_region_moves_to_global() {
        var c = Config.default
        c.llmProvider = "vertex"
        c.llmModel = "gemini-2.5-flash"
        c.vertexRegion = "us-central1"
        Config.migrateRetiredModels(&c)
        XCTAssertEqual(c.llmModel, "gemini-3.5-flash-lite")
        XCTAssertEqual(c.vertexRegion, "global")
    }

    func test_vertex_non_default_region_is_preserved() {
        var c = Config.default
        c.llmProvider = "vertex"
        c.llmModel = "gemini-2.5-flash"
        c.vertexRegion = "europe-west4"  // possibly a data-residency choice
        Config.migrateRetiredModels(&c)
        XCTAssertEqual(c.vertexRegion, "europe-west4")
    }

    func test_vertex_managed_region_is_preserved() {
        var c = Config.default
        c.llmProvider = "vertex"
        c.llmModel = "gemini-2.5-flash"
        c.vertexRegion = "us-central1"
        c.managedKeys = ["vertexRegion"]
        Config.migrateRetiredModels(&c)
        XCTAssertEqual(c.vertexRegion, "us-central1", "an MDM-pinned region is never rewritten")
    }

    func test_vertex_region_untouched_when_no_global_only_model() {
        var c = Config.default
        c.llmProvider = "vertex"
        c.llmModel = "claude-sonnet-5-5"  // served from us-east5 too
        c.vertexRegion = "us-central1"
        c.vertexAnthropicRegion = "us-east5"
        Config.migrateRetiredModels(&c)
        XCTAssertEqual(c.vertexRegion, "us-central1")
        XCTAssertEqual(c.vertexAnthropicRegion, "us-east5")
    }

    func test_vertex_haiku_moves_old_default_anthropic_region_to_global() {
        var c = Config.default
        c.llmProvider = "vertex"
        c.llmModel = "claude-haiku-4-5@20251001"
        c.vertexAnthropicRegion = "us-east5"
        Config.migrateRetiredModels(&c)
        XCTAssertEqual(c.llmModel, "claude-haiku-5-5")
        XCTAssertEqual(c.vertexAnthropicRegion, "global", "Haiku 5.5 is global-only on Vertex")
    }

    func test_vertex_global_host() {
        XCTAssertEqual(VertexProvider.host(forLocation: "global"), "aiplatform.googleapis.com")
        XCTAssertEqual(VertexProvider.host(forLocation: "us-central1"), "us-central1-aiplatform.googleapis.com")
    }

    func test_defaults_use_global_vertex_locations() {
        XCTAssertEqual(Config.default.vertexRegion, "global")
        XCTAssertEqual(Config.default.vertexAnthropicRegion, "global")
        XCTAssertEqual(Config.default.llmModel, "gemini-3.5-flash-lite")
    }

    // MARK: - Gemini thinking config

    func test_gemini_3_plus_uses_thinking_level() {
        let t = LLMTuning()
        XCTAssertEqual(t.resolvedThinkingConfig(forModel: "gemini-3.5-flash-lite") as? [String: String],
                       ["thinkingLevel": "minimal"])
        XCTAssertEqual(t.resolvedThinkingConfig(forModel: "gemini-3.8-flash") as? [String: String],
                       ["thinkingLevel": "low"], "3.8 Flash rejects minimal")
        XCTAssertEqual(t.resolvedThinkingConfig(forModel: "gemini-4-argon") as? [String: String],
                       ["thinkingLevel": "low"], "Argon rejects minimal")
    }

    func test_gemini_3_plus_ignores_budget_override() {
        let t = LLMTuning(thinkingBudget: 0)
        XCTAssertNil(t.resolvedThinkingConfig(forModel: "gemini-4-argon")["thinkingBudget"],
                     "Argon on Vertex rejects any thinkingBudget")
    }

    func test_gemini_25_keeps_budget_split() {
        let t = LLMTuning()
        XCTAssertEqual(t.resolvedThinkingConfig(forModel: "gemini-2.5-flash") as? [String: Int], ["thinkingBudget": 0])
        XCTAssertEqual(t.resolvedThinkingConfig(forModel: "gemini-2.5-pro") as? [String: Int], ["thinkingBudget": 128])
        XCTAssertEqual(LLMTuning(thinkingBudget: 512).resolvedThinkingConfig(forModel: "gemini-2.5-flash") as? [String: Int],
                       ["thinkingBudget": 512])
    }

    func test_gemini_major_version_parsing() {
        XCTAssertEqual(ModelCatalog.geminiMajorVersion("gemini-3.5-flash-lite"), 3)
        XCTAssertEqual(ModelCatalog.geminiMajorVersion("gemini-4-argon"), 4)
        XCTAssertEqual(ModelCatalog.geminiMajorVersion("gemini-2.5-pro"), 2)
        XCTAssertNil(ModelCatalog.geminiMajorVersion("gemini-flash-latest"))
        XCTAssertNil(ModelCatalog.geminiMajorVersion("claude-haiku-5-5"))
    }

    // MARK: - OpenAI reasoning shape

    func test_gpt5_and_gpt6_are_reasoning_models() {
        for m in ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-5-mini", "gpt-5.6-luna"] {
            XCTAssertTrue(isOpenAIReasoningModel(m), "\(m) rejects max_tokens; needs the reasoning shape")
        }
        XCTAssertFalse(isOpenAIReasoningModel("gpt-5-chat-latest"), "chat variant is non-reasoning")
        XCTAssertFalse(isOpenAIReasoningModel("gpt-4o-mini"))
    }

    func test_reasoning_effort_none_only_where_verified() {
        XCTAssertEqual(openAIReasoningEffort(forModel: "gpt-6-luna"), "none")
        XCTAssertEqual(openAIReasoningEffort(forModel: "gpt-6.1-terra"), "none")
        XCTAssertEqual(openAIReasoningEffort(forModel: "gpt-6.1-sol"), "low", "6.1-sol rejects none")
        XCTAssertEqual(openAIReasoningEffort(forModel: "o3"), "low")
    }

    func test_new_openai_models_are_vision_capable() {
        for m in ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.1-sol"] {
            XCTAssertTrue(OpenAIProvider(model: m).supportsVision, m)
        }
    }

    func test_new_gemini_models_are_vision_capable() {
        for m in ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-4-argon"] {
            XCTAssertTrue(LLMClient(model: m).supportsVision, m)
        }
        XCTAssertFalse(LLMClient(model: "gemini-2.5-flash-lite").supportsVision)
    }
}
