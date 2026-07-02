import XCTest
@testable import ParleqAppCore

/// Phase A of the cleanup provider/level reframe (2026-07-02).
///
/// The two-layer model reinterprets the legacy `llm.provider` string:
///   - a generative provider (gemini/…/local) → the "Polished" provider
///   - "concord" → NO Polished provider; Polished degrades to Instant,
///                 refine becomes append-only. Default cleanup level Polished.
///   - "none"    → NO Polished provider; global default cleanup level Raw
///                 (preserves the "send nothing to any cloud" guarantee).
///
/// Crucially this is a pure REINTERPRETATION: the on-disk `llm.provider`
/// value space is unchanged, so an older build reading a downgraded config
/// sees exactly the same provider string it always did. These tests pin the
/// derivation, the behaviorForApp default level, downgrade round-trips, the
/// "none = no cloud" invariant, and MDM-pin translation.
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

    // MARK: - Migration matrix: derived Polished provider + default level

    func test_cloud_provider_is_the_polished_provider() {
        let c = config(provider: "gemini", model: "gemini-2.5-flash")
        XCTAssertEqual(c.polishedProvider, "gemini")
        XCTAssertEqual(c.polishedModel, "gemini-2.5-flash")
        XCTAssertTrue(c.hasPolishedProvider)
        XCTAssertEqual(c.cleanupDefaultLevel, .polished)
    }

    func test_all_generative_providers_are_polished() {
        for p in ["vertex", "bedrock", "bedrock-bearer", "azure", "openai", "local"] {
            let c = config(provider: p)
            XCTAssertEqual(c.polishedProvider, p, "\(p) should be a Polished provider")
            XCTAssertTrue(c.hasPolishedProvider, "\(p) should have a Polished provider")
            XCTAssertEqual(c.cleanupDefaultLevel, .polished, "\(p) default level")
        }
    }

    func test_concord_has_no_polished_provider_polished_default() {
        let c = config(provider: "concord")
        XCTAssertNil(c.polishedProvider, "concord is a LEVEL state, not a Polished provider")
        XCTAssertNil(c.polishedModel)
        XCTAssertFalse(c.hasPolishedProvider)
        // concord keeps concord-everywhere behavior: default level stays
        // Polished (which degrades to Instant at routing when no provider).
        XCTAssertEqual(c.cleanupDefaultLevel, .polished)
    }

    func test_none_has_no_polished_provider_raw_default() {
        let c = config(provider: "none")
        XCTAssertNil(c.polishedProvider)
        XCTAssertNil(c.polishedModel)
        XCTAssertFalse(c.hasPolishedProvider)
        // none preserves "send nothing to any cloud": Raw everywhere.
        XCTAssertEqual(c.cleanupDefaultLevel, .raw)
    }

    // MARK: - behaviorForApp default level follows the migration

    func test_none_config_unmapped_app_defaults_to_raw() {
        let c = config(provider: "none")
        XCTAssertEqual(c.behaviorForApp("com.example.unmapped").mode, .raw)
    }

    func test_none_config_nil_and_empty_bundle_defaults_to_raw() {
        let c = config(provider: "none")
        XCTAssertEqual(c.behaviorForApp(nil).mode, .raw)
        XCTAssertEqual(c.behaviorForApp("").mode, .raw)
        XCTAssertEqual(c.behaviorForApp("   ").mode, .raw)
    }

    func test_none_config_curated_app_stays_raw() {
        // A none user opted out of cleanup entirely. Curated defaults
        // (Terminal→Instant, Mail→Polished) are NOT silently applied — they
        // keep Raw everywhere. Only an explicit override lifts an app out.
        let c = config(provider: "none")
        XCTAssertEqual(c.behaviorForApp("com.apple.Terminal").mode, .raw)
        XCTAssertEqual(c.behaviorForApp("com.apple.mail").mode, .raw)
    }

    func test_none_config_explicit_polished_override_is_honored() {
        // If the user explicitly set an app to Polished, that override wins
        // over the Raw global default (they asked for it).
        var c = config(provider: "none")
        c.appBehaviors = ["com.example.app": AppBehavior(mode: .polished)]
        XCTAssertEqual(c.behaviorForApp("com.example.app").mode, .polished)
    }

    func test_concord_config_unmapped_app_defaults_to_polished() {
        let c = config(provider: "concord")
        XCTAssertEqual(c.behaviorForApp("com.apple.mail").mode, .polished)
    }

    func test_cloud_config_unmapped_app_defaults_to_polished() {
        // Regression: the existing cloud default is unchanged.
        let c = config(provider: "gemini", model: "gemini-2.5-flash")
        XCTAssertEqual(c.behaviorForApp("com.apple.mail").mode, .polished)
    }

    // MARK: - Downgrade safety: on-disk provider string is unchanged

    func test_concord_round_trips_provider_string_for_downgrade() throws {
        let c = try parse(#"{"llm":{"provider":"concord","model":""}}"#)
        let dict = Config.serializeToDictionary(c)
        let llm = try XCTUnwrap(dict["llm"] as? [String: Any])
        XCTAssertEqual(llm["provider"] as? String, "concord",
                       "downgrade must see 'concord' verbatim")
    }

    func test_none_round_trips_provider_string_for_downgrade() throws {
        let c = try parse(#"{"llm":{"provider":"none","model":""}}"#)
        let dict = Config.serializeToDictionary(c)
        let llm = try XCTUnwrap(dict["llm"] as? [String: Any])
        XCTAssertEqual(llm["provider"] as? String, "none",
                       "downgrade must see 'none' verbatim")
    }

    func test_cloud_round_trips_provider_string() throws {
        let c = try parse(#"{"llm":{"provider":"gemini","model":"gemini-2.5-flash"}}"#)
        let dict = Config.serializeToDictionary(c)
        let llm = try XCTUnwrap(dict["llm"] as? [String: Any])
        XCTAssertEqual(llm["provider"] as? String, "gemini")
        XCTAssertEqual(llm["model"] as? String, "gemini-2.5-flash")
    }

    // MARK: - "none = no cloud" invariant (unchanged by the reframe)

    func test_none_never_routes_to_cloud_even_with_context_and_refine() {
        // Even when a context/refine tier is still configured, a none config
        // must short-circuit so no transcript reaches a cloud provider.
        var c = config(provider: "none")
        c.contextModel = ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash")
        c.refineModel = ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash")

        let plain = c.modelForInvocation(hasReferences: false)
        XCTAssertEqual(plain.provider, "none")

        let withRefs = c.modelForInvocation(hasReferences: true)
        XCTAssertEqual(withRefs.provider, "none", "references must not leak to cloud when none")

        let refine = c.modelForInvocation(hasReferences: false, isRefine: true)
        XCTAssertEqual(refine.provider, "none", "refine must not leak to cloud when none")
    }

    // MARK: - isGenerativeProvider predicate (open-world)

    func test_isGenerativeProvider_true_for_cloud_and_local_and_unknown() {
        for p in ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure",
                  "openai", "local", "some-future-provider"] {
            XCTAssertTrue(Config.isGenerativeProvider(p), "\(p) should be generative")
        }
    }

    func test_isGenerativeProvider_false_for_level_sentinels_and_empty() {
        XCTAssertFalse(Config.isGenerativeProvider("concord"))
        XCTAssertFalse(Config.isGenerativeProvider("none"))
        XCTAssertFalse(Config.isGenerativeProvider(""))
    }

    // MARK: - MDM pin translation (simulated, as ManagedConfigTests does)

    func test_mdm_pinned_concord_maps_to_no_polished_provider() {
        // Simulate an MDM `cleanupProvider = concord` pin: it sets llmProvider
        // verbatim, and the derivation must interpret it — NOT reset it to a
        // cloud provider.
        var c = Config.default
        c.llmProvider = "concord"
        XCTAssertNil(c.polishedProvider)
        XCTAssertEqual(c.cleanupDefaultLevel, .polished)
    }

    func test_mdm_pinned_none_maps_to_raw_default() {
        var c = Config.default
        c.llmProvider = "none"
        XCTAssertNil(c.polishedProvider)
        XCTAssertEqual(c.cleanupDefaultLevel, .raw)
    }
}
