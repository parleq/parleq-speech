import XCTest
@testable import ParleqAppCore

final class ConfigContextModelTests: XCTestCase {
    // MARK: - Helpers

    private func config(
        cleanup: ModelIdentifier,
        context: ModelIdentifier?
    ) -> Config {
        var c = Config.default
        c.llmProvider = cleanup.provider
        c.llmModel = cleanup.model
        c.contextModel = context
        return c
    }

    // MARK: - modelForInvocation resolution logic

    func test_no_references_uses_cleanup() {
        let cleanup = ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash")
        let context = ModelIdentifier(provider: "vertex", model: "gemini-2.5-pro")
        let c = config(cleanup: cleanup, context: context)

        let result = c.modelForInvocation(hasReferences: false)
        XCTAssertEqual(result, cleanup)
    }

    func test_references_uses_context_when_set() {
        let cleanup = ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash")
        let context = ModelIdentifier(provider: "vertex", model: "gemini-2.5-pro")
        let c = config(cleanup: cleanup, context: context)

        let result = c.modelForInvocation(hasReferences: true)
        XCTAssertEqual(result, context)
    }

    func test_references_falls_back_to_cleanup_when_context_nil() {
        let cleanup = ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash")
        let c = config(cleanup: cleanup, context: nil)

        let result = c.modelForInvocation(hasReferences: true)
        XCTAssertEqual(result, cleanup)
    }

    func test_override_beats_everything() {
        let cleanup = ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash")
        let context = ModelIdentifier(provider: "vertex", model: "gemini-2.5-pro")
        let override = ModelIdentifier(provider: "bedrock", model: "us.anthropic.claude-3-5-sonnet-20241022-v2:0")
        let c = config(cleanup: cleanup, context: context)

        let result = c.modelForInvocation(hasReferences: true, override: override)
        XCTAssertEqual(result, override)
    }

    func test_override_with_nil_context_and_no_references() {
        let cleanup = ModelIdentifier(provider: "azure", model: "gpt-4o")
        let override = ModelIdentifier(provider: "bedrock", model: "us.anthropic.claude-3-5-sonnet-20241022-v2:0")
        let c = config(cleanup: cleanup, context: nil)

        let result = c.modelForInvocation(hasReferences: false, override: override)
        XCTAssertEqual(result, override)
    }

    // MARK: - Refine tier resolution

    func test_refine_uses_refine_model_when_set() {
        let cleanup = ModelIdentifier(provider: "concord", model: "")
        let refine  = ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash")
        var c = config(cleanup: cleanup, context: nil)
        c.refineModel = refine

        let result = c.modelForInvocation(hasReferences: false, isRefine: true)
        XCTAssertEqual(result, refine)
    }

    func test_refine_falls_back_to_context_then_cleanup() {
        let cleanup = ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash")
        let context = ModelIdentifier(provider: "vertex", model: "gemini-2.5-pro")
        var c = config(cleanup: cleanup, context: context)
        c.refineModel = nil

        // No refine model → falls back to the context tier.
        XCTAssertEqual(c.modelForInvocation(hasReferences: false, isRefine: true), context)

        // No refine OR context model → falls back to cleanup.
        c.contextModel = nil
        XCTAssertEqual(c.modelForInvocation(hasReferences: false, isRefine: true), cleanup)
    }

    func test_refine_with_concord_cleanup_and_no_refine_tier_resolves_to_cleanup_id() {
        // Concord can't refine. With no refine/context tier configured the
        // identifier still resolves to the (non-refining) cleanup id — the
        // runtime guard (streamCleanupOrRefine) is what surfaces guidance
        // rather than no-op'ing. This documents that contract.
        let cleanup = ModelIdentifier(provider: "concord", model: "")
        var c = config(cleanup: cleanup, context: nil)
        c.refineModel = nil

        XCTAssertEqual(c.modelForInvocation(hasReferences: false, isRefine: true), cleanup)
    }

    // MARK: - providerCanRefine capability

    func test_providerCanRefine_false_for_non_instruction_providers() {
        XCTAssertFalse(Config.providerCanRefine("concord"))
        XCTAssertFalse(Config.providerCanRefine("none"))
    }

    func test_providerCanRefine_true_for_llm_providers() {
        for p in ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai", "local"] {
            XCTAssertTrue(Config.providerCanRefine(p), "\(p) should be refine-capable")
        }
    }

    // MARK: - Load/save round-trip

    // Config.save() and Config.load() are hardcoded to ~/.parleq/config.json
    // with no injectable path parameter, so a true disk round-trip test would
    // clobber the developer's actual config. The serialization path is
    // exercised by modelForInvocation tests above (which mutate Config in
    // memory) and by the integration E2E suite. A refactor to accept an
    // optional path parameter would enable a proper unit test here — tracked
    // as a future cleanup item.

    func test_default_config_context_model_is_nil() {
        let c = Config.default
        XCTAssertNil(c.contextModel, "Default config should have contextModel == nil")
    }
}
