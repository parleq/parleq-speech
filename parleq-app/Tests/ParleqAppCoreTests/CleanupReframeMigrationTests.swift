import XCTest
@testable import ParleqAppCore

/// The cleanup/refinement/context reframe (v2, 2026-07-02). Three orthogonal
/// settings:
///   - Cleanup type (Raw/Instant/Polished), global default + per-app override.
///   - Refinement type (Raw/Instant/Polished), GLOBAL. Polished interprets
///     commands; Instant/Raw are append-only.
///   - Polished provider: ONE shared cloud/local service used by whichever of
///     cleanup/refinement is Polished. Context is a separate provider.
///
/// On disk, `llm.provider` stays the cleanup config (cloud/concord/none) and
/// `llm.refine` stays the refinement's Polished provider — so downgrade to an
/// older build is faithful (concord cleanup + vertex refine). The new
/// `llm.refinement` key stores the refinement TYPE. These tests pin the
/// derivations + migration (esp. the maintainer's concord+vertex-refine mix).
final class CleanupReframeMigrationTests: XCTestCase {
    // MARK: - Helpers

    private func parse(_ json: String) throws -> Config {
        let data = json.data(using: .utf8)!
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return Config.parse(fromDictionary: obj)
    }

    private func config(provider: String, model: String = "m") -> Config {
        var c = Config.default
        c.llmProvider = provider
        c.llmModel = model
        return c
    }

    // MARK: - cleanupType (global default cleanup)

    func test_cleanupType_cloud_is_polished() {
        for p in ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai", "local"] {
            XCTAssertEqual(config(provider: p).cleanupType, .polished, "\(p)")
        }
    }

    func test_cleanupType_concord_is_instant() {
        XCTAssertEqual(config(provider: "concord").cleanupType, .instant)
    }

    func test_cleanupType_none_is_raw() {
        XCTAssertEqual(config(provider: "none").cleanupType, .raw)
    }

    // MARK: - polishedProvider (the ONE shared cloud/local service)

    func test_polished_provider_is_cleanup_when_cleanup_is_generative() {
        let c = config(provider: "gemini", model: "gemini-2.5-flash")
        XCTAssertEqual(c.polishedProvider, "gemini")
        XCTAssertEqual(c.polishedModel, "gemini-2.5-flash")
        XCTAssertTrue(c.hasPolishedProvider)
    }

    func test_polished_provider_falls_to_refine_when_cleanup_is_concord() {
        // The maintainer's shape: concord cleanup + vertex refine → the shared
        // Polished provider is vertex (from refineModel).
        var c = config(provider: "concord")
        c.refineModel = ModelIdentifier(provider: "vertex", model: "gemini-2.5-flash")
        XCTAssertEqual(c.polishedProvider, "vertex")
        XCTAssertEqual(c.polishedModel, "gemini-2.5-flash")
        XCTAssertTrue(c.hasPolishedProvider)
    }

    func test_polished_provider_is_local_when_refine_is_local_with_empty_model() throws {
        // Regression (persistence bug): the on-device Polished provider must
        // STICK across a config round-trip. The local model is centralized in
        // `llm.local.model`, so `refine.model` is legitimately empty — which
        // used to drop the whole refine tier at parse and revert Polished to a
        // cloud default on restart. polishedProvider must resolve to "local"
        // and its model must mirror the centralized local model.
        let c = try parse(#"""
        {"llm":{"provider":"concord","model":"","refine":{"provider":"local","model":""},
                "local":{"model":"mlx-community/Qwen3-4B-Instruct-2507-4bit"}}}
        """#)
        XCTAssertEqual(c.polishedProvider, "local")
        XCTAssertTrue(c.hasPolishedProvider)
        XCTAssertFalse(c.polishedModel?.isEmpty ?? true)
        XCTAssertEqual(c.polishedModel, c.localModel)
        XCTAssertEqual(c.refinementType, .polished)
    }

    func test_polished_provider_nil_for_bare_concord_and_none() {
        XCTAssertNil(config(provider: "concord").polishedProvider)
        XCTAssertFalse(config(provider: "concord").hasPolishedProvider)
        XCTAssertNil(config(provider: "none").polishedProvider)
    }

    // MARK: - refinementType migration (the crux)

    func test_refinement_migrates_to_polished_from_refine_tier() throws {
        // concord cleanup + vertex refine → Refinement = Polished (vertex kept).
        let c = try parse(#"""
        {"llm":{"provider":"concord","model":"","refine":{"provider":"vertex","model":"gemini-2.5-flash"}}}
        """#)
        XCTAssertEqual(c.cleanupType, .instant)
        XCTAssertEqual(c.refinementType, .polished)
        XCTAssertEqual(c.polishedProvider, "vertex")
    }

    func test_refinement_migrates_to_polished_from_context_when_no_refine() throws {
        // concord cleanup + no refine tier + vertex context → old refine fell
        // back to context, so Refinement = Polished via vertex (copied into the
        // refinement provider so polishedProvider resolves it).
        let c = try parse(#"""
        {"llm":{"provider":"concord","model":""},"context_model":{"provider":"vertex","model":"gemini-2.5-flash"}}
        """#)
        XCTAssertEqual(c.refinementType, .polished)
        XCTAssertEqual(c.polishedProvider, "vertex")
    }

    func test_refinement_migrates_to_polished_for_cloud_cleanup() throws {
        let c = try parse(#"{"llm":{"provider":"gemini","model":"gemini-2.5-flash"}}"#)
        XCTAssertEqual(c.refinementType, .polished)
        XCTAssertEqual(c.polishedProvider, "gemini")
    }

    func test_refinement_migrates_to_instant_for_bare_concord() throws {
        // concord cleanup, no refine/context → nothing can refine → Instant
        // (append-only, cleaned on-device).
        let c = try parse(#"{"llm":{"provider":"concord","model":""}}"#)
        XCTAssertEqual(c.refinementType, .instant)
        XCTAssertNil(c.polishedProvider)
    }

    func test_refinement_migrates_to_raw_for_none() throws {
        let c = try parse(#"{"llm":{"provider":"none","model":""}}"#)
        XCTAssertEqual(c.refinementType, .raw)
        XCTAssertNil(c.polishedProvider)
    }

    func test_none_with_context_does_not_promote_refinement_to_cloud() throws {
        // Privacy regression guard: a migrated "none" user (Raw cleanup = the
        // global no-cloud switch) with a leftover CONTEXT tier must NOT be
        // auto-promoted to Polished (cloud) refinement — that would silently
        // start sending voice-refine turns to the cloud on upgrade. Refinement
        // stays append-only and NO cloud provider is resolvable.
        let c = try parse(#"""
        {"llm":{"provider":"none","model":""},"context_model":{"provider":"vertex","model":"gemini-2.5-flash"}}
        """#)
        XCTAssertEqual(c.refinementType, .raw)
        XCTAssertNil(c.polishedProvider)
        XCTAssertEqual(c.modelForInvocation(hasReferences: false, isRefine: true).provider, "none")
    }

    func test_none_with_dead_refine_tier_stays_append_only() throws {
        // Same guard for an explicit (but dead-under-"none") refine tier — it
        // must not revive as cloud refinement; refineModel is dropped.
        let c = try parse(#"""
        {"llm":{"provider":"none","model":"","refine":{"provider":"gemini","model":"gemini-2.5-flash"}}}
        """#)
        XCTAssertEqual(c.refinementType, .raw)
        XCTAssertNil(c.refineModel)
        XCTAssertNil(c.polishedProvider)
        XCTAssertEqual(c.modelForInvocation(hasReferences: false, isRefine: true).provider, "none")
    }

    func test_explicit_refinement_key_wins_over_migration() throws {
        // When the new key is present it is authoritative (not re-derived).
        let c = try parse(#"""
        {"llm":{"provider":"gemini","model":"gemini-2.5-flash","refinement":"raw"}}
        """#)
        XCTAssertEqual(c.refinementType, .raw)
    }

    // MARK: - behaviorForApp global default follows cleanupType

    func test_concord_unmapped_app_defaults_to_instant() {
        XCTAssertEqual(config(provider: "concord").behaviorForApp("com.example.x").mode, .instant)
    }

    func test_none_unmapped_app_defaults_to_raw() {
        XCTAssertEqual(config(provider: "none").behaviorForApp("com.example.x").mode, .raw)
    }

    func test_cloud_unmapped_app_defaults_to_polished() {
        XCTAssertEqual(config(provider: "gemini").behaviorForApp("com.example.x").mode, .polished)
    }

    func test_none_curated_app_stays_raw_curated_skipped() {
        // A none user opted out of cleanup: curated Instant/Polished defaults
        // are NOT applied; only explicit overrides lift an app out of Raw.
        let c = config(provider: "none")
        XCTAssertEqual(c.behaviorForApp("com.apple.Terminal").mode, .raw)
        XCTAssertEqual(c.behaviorForApp("com.apple.mail").mode, .raw)
    }

    func test_explicit_override_wins_over_global_default() {
        var c = config(provider: "none")
        c.appBehaviors = ["com.example.app": AppBehavior(mode: .polished)]
        XCTAssertEqual(c.behaviorForApp("com.example.app").mode, .polished)
    }

    func test_curated_polished_not_applied_when_cleanup_is_instant() {
        // The maintainer's shape: concord cleanup (Instant) + vertex refine.
        // polishedProvider is now non-nil (vertex, for refinement) — but that
        // must NOT auto-route curated comms/email apps' CLEANUP to the cloud.
        // Curated .polished apps fall back to the user's cleanup type (Instant).
        var c = config(provider: "concord")
        c.refineModel = ModelIdentifier(provider: "vertex", model: "gemini-2.5-flash")
        XCTAssertTrue(c.hasPolishedProvider, "vertex is the refinement provider")
        XCTAssertEqual(c.behaviorForApp("com.tinyspeck.slackmacgap").mode, .instant)
        XCTAssertEqual(c.behaviorForApp("com.apple.mail").mode, .instant)
        // A curated .instant app is still Instant.
        XCTAssertEqual(c.behaviorForApp("com.apple.Terminal").mode, .instant)
        // An EXPLICIT polished override IS honored (routes to vertex).
        c.appBehaviors = ["com.apple.iWork.Pages": AppBehavior(mode: .polished)]
        XCTAssertEqual(c.behaviorForApp("com.apple.iWork.Pages").mode, .polished)
    }

    func test_curated_polished_applied_when_cleanup_is_polished() {
        // A cloud-cleanup user still gets the curated demo: comms → Polished,
        // terminals → Instant.
        let c = config(provider: "gemini", model: "gemini-2.5-flash")
        XCTAssertEqual(c.behaviorForApp("com.tinyspeck.slackmacgap").mode, .polished)
        XCTAssertEqual(c.behaviorForApp("com.apple.Terminal").mode, .instant)
    }

    // MARK: - modeSource (mirrors behaviorForApp's branches; display only)

    func test_modeSource_override_wins() {
        var c = config(provider: "none")
        c.appBehaviors = ["com.example.app": AppBehavior(mode: .polished)]
        XCTAssertEqual(c.modeSource(for: "com.example.app"), .override)
    }

    func test_modeSource_curated_instant_applies_under_global_polished() {
        // iTerm2 is curated Instant; global cleanup is Polished (gemini), so
        // the curation actually takes effect.
        let c = config(provider: "gemini", model: "gemini-2.5-flash")
        XCTAssertEqual(c.behaviorForApp("com.googlecode.iterm2").mode, .instant)
        XCTAssertEqual(c.modeSource(for: "com.googlecode.iterm2"), .curated)
    }

    func test_modeSource_unmapped_app_is_global() {
        let c = config(provider: "gemini", model: "gemini-2.5-flash")
        XCTAssertEqual(c.modeSource(for: "com.example.unmapped"), .global)
    }

    func test_modeSource_global_raw_even_for_curated_app() {
        // Global cleanup is Raw ("none") — curated defaults are skipped
        // entirely, so even a curated app resolves to .global, not .curated.
        let c = config(provider: "none")
        XCTAssertEqual(c.behaviorForApp("com.googlecode.iterm2").mode, .raw)
        XCTAssertEqual(c.modeSource(for: "com.googlecode.iterm2"), .global)
    }

    func test_modeSource_curated_polished_downgrade_edge_is_global() {
        // com.apple.mail is curated .polished, but the user's global cleanup
        // is Instant (concord) — the curation does NOT take effect (resolved
        // mode falls back to the global Instant), so the source is .global,
        // not .curated.
        let c = config(provider: "concord")
        XCTAssertEqual(c.behaviorForApp("com.apple.mail").mode, .instant)
        XCTAssertEqual(c.modeSource(for: "com.apple.mail"), .global)
    }

    func test_concord_refine_routes_to_shared_polished_provider() {
        // The maintainer's path: a refine / re-clean for a concord-cleanup user
        // resolves to their shared Polished provider (vertex), not concord.
        var c = config(provider: "concord")
        c.refineModel = ModelIdentifier(provider: "vertex", model: "gemini-2.5-flash")
        let r = c.modelForInvocation(hasReferences: false, isRefine: true)
        XCTAssertEqual(r.provider, "vertex")
        XCTAssertEqual(r.model, "gemini-2.5-flash")
    }

    func test_none_never_routes_to_cloud_even_with_refine_and_isRefine() {
        // Pin the invariant for the none + refineModel + isRefine case.
        var c = config(provider: "none")
        c.refineModel = ModelIdentifier(provider: "vertex", model: "gemini-2.5-flash")
        XCTAssertEqual(c.modelForInvocation(hasReferences: false, isRefine: true).provider, "none")
    }

    // MARK: - Downgrade safety: on-disk cleanup/refine strings unchanged

    func test_maintainer_shape_round_trips_for_downgrade() throws {
        // concord cleanup + vertex refine must serialize back to the same
        // llm.provider / llm.refine an older build reads.
        let c = try parse(#"""
        {"llm":{"provider":"concord","model":"","refine":{"provider":"vertex","model":"gemini-2.5-flash"}}}
        """#)
        let dict = Config.serializeToDictionary(c)
        let llm = try XCTUnwrap(dict["llm"] as? [String: Any])
        XCTAssertEqual(llm["provider"] as? String, "concord")
        let refine = try XCTUnwrap(llm["refine"] as? [String: Any])
        XCTAssertEqual(refine["provider"] as? String, "vertex")
        XCTAssertEqual(llm["refinement"] as? String, "polished")
    }

    func test_none_round_trips_provider_string() throws {
        let c = try parse(#"{"llm":{"provider":"none","model":""}}"#)
        let llm = try XCTUnwrap(Config.serializeToDictionary(c)["llm"] as? [String: Any])
        XCTAssertEqual(llm["provider"] as? String, "none")
    }

    // MARK: - save() (mergeForSave) persists the refinement type

    func test_mergeForSave_persists_refinement_type() throws {
        // Regression: the MDM-aware llm-section rebuild in save() overwrites the
        // dict serializeToDictionary produced, and once dropped `llm.refinement`
        // — reverting an Instant/Raw choice to the migrated default on reload.
        for type in [TargetMode.raw, .instant, .polished] {
            var c = config(provider: "gemini", model: "gemini-2.5-flash")
            c.refinementType = type
            let dict = Config.mergeForSave(c, existing: [:])
            let llm = try XCTUnwrap(dict["llm"] as? [String: Any])
            XCTAssertEqual(llm["refinement"] as? String, type.rawValue, "\(type)")
            // And it round-trips back through parse (explicit key wins).
            XCTAssertEqual(Config.parse(fromDictionary: dict).refinementType, type, "\(type)")
        }
    }

    // MARK: - "none = no cloud" invariant

    func test_none_never_routes_to_cloud_even_with_context() {
        var c = config(provider: "none")
        c.contextModel = ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash")
        XCTAssertEqual(c.modelForInvocation(hasReferences: false).provider, "none")
        XCTAssertEqual(c.modelForInvocation(hasReferences: true).provider, "none")
    }

    // MARK: - isGenerativeProvider predicate

    func test_isGenerativeProvider_open_world() {
        for p in ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai", "local", "future"] {
            XCTAssertTrue(Config.isGenerativeProvider(p), p)
        }
        for p in ["concord", "none", ""] {
            XCTAssertFalse(Config.isGenerativeProvider(p), p)
        }
    }

    // MARK: - cleanupDisplayIdentifier (stale on-device model badge/picker bug)

    /// The badge/picker display identifier for an on-device cleanup provider
    /// must come from the authoritative on-device selection (`localModel`),
    /// NOT the stale `llmModel` left over from a prior cloud provider (which
    /// the runtime provider-build path in main.swift already ignores on the
    /// local path).
    func test_cleanupDisplayIdentifier_local_uses_localModel_not_stale_llmModel() {
        var c = config(provider: "local", model: "gemini-2.5-flash")
        c.localModel = LocalModelCatalog.qwen3_4B.checkpoint
        let id = c.cleanupDisplayIdentifier
        XCTAssertEqual(id.provider, "local")
        XCTAssertEqual(id.model, LocalModelCatalog.qwen3_4B.checkpoint)
        XCTAssertNotEqual(id.model, c.llmModel)
    }

    /// For every cloud provider, cleanupDisplayIdentifier is just llmModel —
    /// unchanged behavior.
    func test_cleanupDisplayIdentifier_cloud_is_llmModel() {
        for p in ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"] {
            let c = config(provider: p, model: "some-model")
            XCTAssertEqual(c.cleanupDisplayIdentifier, ModelIdentifier(provider: p, model: "some-model"), p)
        }
    }

    /// modelForInvocation's resolved identifier for a plain local cleanup
    /// (no references, no refine) must likewise carry the on-device
    /// selection, not a stale llmModel — this is what actually feeds the
    /// overlay's ModelBadge.
    func test_modelForInvocation_local_cleanup_uses_localModel() {
        var c = config(provider: "local", model: "gemini-2.5-flash")
        c.localModel = LocalModelCatalog.qwen3_4B.checkpoint
        let resolved = c.modelForInvocation(hasReferences: false)
        XCTAssertEqual(resolved, ModelIdentifier(provider: "local", model: LocalModelCatalog.qwen3_4B.checkpoint))
    }

    // MARK: - Fix 3: llm.model / llm.local.model anti-recurrence at save time

    /// Once the cleanup provider is on-device, saving must sync `llm.model`
    /// on disk to the current `llm.local.model` selection — so the two
    /// fields can't diverge (the divergence is exactly what caused the
    /// stale badge/picker bug in the first place). A stale on-disk
    /// `llm.model` from a prior cloud provider gets corrected on the next
    /// save.
    func test_mergeForSave_local_provider_syncs_llmModel_to_localModel() throws {
        var c = config(provider: "local", model: "gemini-2.5-flash")
        c.localModel = LocalModelCatalog.qwen3_4B.checkpoint
        let dict = Config.mergeForSave(c, existing: [:])
        let llm = try XCTUnwrap(dict["llm"] as? [String: Any])
        XCTAssertEqual(llm["model"] as? String, LocalModelCatalog.qwen3_4B.checkpoint)

        // Round-trips: re-parsing the saved dict keeps llm.model and
        // llm.local.model coherent.
        let reparsed = Config.parse(fromDictionary: dict)
        XCTAssertEqual(reparsed.llmModel, LocalModelCatalog.qwen3_4B.checkpoint)
        XCTAssertEqual(reparsed.localModel, LocalModelCatalog.qwen3_4B.checkpoint)
    }

    /// A stale on-disk `llm.model` (from before switching to the on-device
    /// provider) is corrected by the very next save — the divergence does
    /// not persist across saves.
    func test_mergeForSave_local_provider_corrects_stale_ondisk_llmModel() throws {
        var c = config(provider: "local")
        c.localModel = LocalModelCatalog.qwen3_4B.checkpoint
        let existing: [String: Any] = [
            "llm": ["mode": "default", "provider": "local", "model": "gemini-2.5-flash"],
        ]
        let dict = Config.mergeForSave(c, existing: existing)
        let llm = try XCTUnwrap(dict["llm"] as? [String: Any])
        XCTAssertEqual(llm["model"] as? String, LocalModelCatalog.qwen3_4B.checkpoint)
    }

    /// A cloud provider's model is untouched by the local-sync rule.
    func test_mergeForSave_cloud_provider_model_unaffected() throws {
        let c = config(provider: "vertex", model: "gemini-2.5-pro")
        let dict = Config.mergeForSave(c, existing: [:])
        let llm = try XCTUnwrap(dict["llm"] as? [String: Any])
        XCTAssertEqual(llm["model"] as? String, "gemini-2.5-pro")
    }

    /// serializeToDictionary (the single-source-of-truth full serializer)
    /// applies the same local-sync rule.
    func test_serializeToDictionary_local_provider_syncs_llmModel_to_localModel() throws {
        var c = config(provider: "local", model: "gemini-2.5-flash")
        c.localModel = LocalModelCatalog.qwen3_4B.checkpoint
        let dict = Config.serializeToDictionary(c)
        let llm = try XCTUnwrap(dict["llm"] as? [String: Any])
        XCTAssertEqual(llm["model"] as? String, LocalModelCatalog.qwen3_4B.checkpoint)
    }
}
