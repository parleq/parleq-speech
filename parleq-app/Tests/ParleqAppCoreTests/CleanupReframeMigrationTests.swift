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
}
