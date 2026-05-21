import XCTest
@testable import ParleqAppCore

/// Tests for the Phase 5 / Tier 1 Managed Configuration substrate:
///   1. Default values for all six new Config fields.
///   2. JSON round-trip through Config.load() / Config.save() is tested
///      via the existing in-memory mutation path (disk round-trip would
///      clobber the developer's real config — same caveat as
///      ConfigContextModelTests).
///   3. Config.managedKeys is empty when no MDM keys are set.
///   4. ManagedConfig.managedBool returns nil for an unmanaged key.
///   5. customDictionaryEnabled gating at the SystemPrompts boundary.
final class ManagedConfigTests: XCTestCase {

    // MARK: - 1. Default values

    func test_referenceWindowsEnabled_defaults_to_true() {
        XCTAssertTrue(Config.default.referenceWindowsEnabled)
    }

    func test_clipboardReferenceEnabled_defaults_to_true() {
        XCTAssertTrue(Config.default.clipboardReferenceEnabled)
    }

    func test_imageReferenceEnabled_defaults_to_true() {
        XCTAssertTrue(Config.default.imageReferenceEnabled)
    }

    func test_fileReferenceEnabled_defaults_to_true() {
        XCTAssertTrue(Config.default.fileReferenceEnabled)
    }

    func test_customDictionaryEnabled_defaults_to_true() {
        XCTAssertTrue(Config.default.customDictionaryEnabled)
    }

    func test_customModelEntryEnabled_defaults_to_true() {
        XCTAssertTrue(Config.default.customModelEntryEnabled)
    }

    // MARK: - 2. In-memory round-trip

    func test_referenceWindowsEnabled_round_trips() {
        var c = Config.default
        c.referenceWindowsEnabled = false
        XCTAssertFalse(c.referenceWindowsEnabled)
        c.referenceWindowsEnabled = true
        XCTAssertTrue(c.referenceWindowsEnabled)
    }

    func test_clipboardReferenceEnabled_round_trips() {
        var c = Config.default
        c.clipboardReferenceEnabled = false
        XCTAssertFalse(c.clipboardReferenceEnabled)
    }

    func test_imageReferenceEnabled_round_trips() {
        var c = Config.default
        c.imageReferenceEnabled = false
        XCTAssertFalse(c.imageReferenceEnabled)
    }

    func test_fileReferenceEnabled_round_trips() {
        var c = Config.default
        c.fileReferenceEnabled = false
        XCTAssertFalse(c.fileReferenceEnabled)
    }

    func test_customDictionaryEnabled_round_trips() {
        var c = Config.default
        c.customDictionaryEnabled = false
        XCTAssertFalse(c.customDictionaryEnabled)
    }

    func test_customModelEntryEnabled_round_trips() {
        var c = Config.default
        c.customModelEntryEnabled = false
        XCTAssertFalse(c.customModelEntryEnabled)
    }

    // MARK: - 3. managedKeys starts empty

    func test_default_config_managed_keys_is_empty() {
        XCTAssertTrue(Config.default.managedKeys.isEmpty,
                      "Default config should have no managed keys")
    }

    func test_managed_keys_can_be_populated() {
        var c = Config.default
        c.managedKeys = ["referenceWindowsEnabled", "autoUpdateEnabled"]
        XCTAssertEqual(c.managedKeys.count, 2)
        XCTAssertTrue(c.managedKeys.contains("referenceWindowsEnabled"))
        XCTAssertTrue(c.managedKeys.contains("autoUpdateEnabled"))
    }

    // MARK: - 4. ManagedConfig.managedBool returns nil for unmanaged key

    func test_managed_bool_returns_nil_for_unmanaged_key() {
        // Use a test-only key that can never appear in
        // /Library/Managed Preferences in a development environment.
        let result = ManagedConfig.managedBool(forKey: "parleq.test.nonexistent.key.xyz")
        XCTAssertNil(result,
                     "An unmanaged key should return nil from ManagedConfig.managedBool")
    }

    // MARK: - 5. customDictionaryEnabled gating at SystemPrompts boundary

    func test_cleanup_with_entries_and_enabled_includes_hint() {
        let entries = [DictionaryEntry(term: "Parleq")]
        let withDictEnabled = SystemPrompts.cleanup(dictionary: entries)
        XCTAssertTrue(
            withDictEnabled.contains("Parleq"),
            "cleanup() should include the vocabulary hint when entries are non-empty"
        )
    }

    func test_cleanup_with_empty_dictionary_excludes_hint() {
        // When customDictionaryEnabled=false, the caller passes [] to cleanup().
        let withEmptyDict = SystemPrompts.cleanup(dictionary: [])
        XCTAssertFalse(
            withEmptyDict.contains("User vocabulary hint"),
            "cleanup() should not include the vocabulary hint section when dictionary is empty"
        )
    }

    func test_dictionary_hint_with_entries_non_empty() {
        let entries = [DictionaryEntry(term: "FluidAudio", context: "on-device ASR engine")]
        let hint = SystemPrompts.dictionaryHint(dictionary: entries)
        XCTAssertFalse(hint.isEmpty,
                       "dictionaryHint() should return non-empty string for non-empty dictionary")
        XCTAssertTrue(hint.contains("FluidAudio"))
    }

    func test_dictionary_hint_with_empty_dictionary_is_empty() {
        // The gating contract: pass [] when customDictionaryEnabled=false,
        // and dictionaryHint returns "" — the LLM never sees the hint.
        let hint = SystemPrompts.dictionaryHint(dictionary: [])
        XCTAssertTrue(hint.isEmpty,
                      "dictionaryHint() should return empty string for empty dictionary")
    }

    // MARK: - 6. managedKeys not persisted across copy (no disk round-trip)

    func test_managed_keys_set_preserved_across_struct_copy() {
        var c = Config.default
        c.managedKeys = ["imageReferenceEnabled"]
        let copy = c
        XCTAssertEqual(copy.managedKeys, c.managedKeys,
                       "managedKeys should survive a struct copy (value semantics)")
    }

    // MARK: - 7. All six fields independent (toggling one doesn't affect others)

    func test_feature_toggles_are_independent() {
        var c = Config.default
        c.referenceWindowsEnabled = false
        XCTAssertTrue(c.clipboardReferenceEnabled, "Disabling parent should not disable sub-toggle in Config (UI gating handles that)")
        XCTAssertTrue(c.imageReferenceEnabled)
        XCTAssertTrue(c.fileReferenceEnabled)
        XCTAssertTrue(c.customDictionaryEnabled)
        XCTAssertTrue(c.customModelEntryEnabled)
    }

    // MARK: - 8. ModelCatalog model validation (defense-in-depth)

    func test_model_catalog_canonical_model_is_accepted() {
        // customModelEntryEnabled=true: any model (canonical or not) should
        // pass through unmodified. We test this via the catalog directly —
        // Config.load() reads from disk so we exercise ModelCatalog in
        // isolation for the "enabled" path.
        XCTAssertTrue(ModelCatalog.isCanonical(provider: "gemini", model: "gemini-2.5-flash"))
        XCTAssertTrue(ModelCatalog.isCanonical(provider: "vertex", model: "gemini-2.5-flash"))
        XCTAssertTrue(ModelCatalog.isCanonical(provider: "bedrock", model: "openai.gpt-oss-120b-1:0"))
        XCTAssertTrue(ModelCatalog.isCanonical(provider: "bedrock-bearer", model: "openai.gpt-oss-120b-1:0"))
        XCTAssertTrue(ModelCatalog.isCanonical(provider: "azure", model: "gpt-4o-mini"))
        XCTAssertTrue(ModelCatalog.isCanonical(provider: "openai", model: "gpt-4o-mini"))
    }

    func test_model_catalog_non_canonical_model_is_rejected() {
        // A hand-crafted model ID that is not in the curated list.
        XCTAssertFalse(ModelCatalog.isCanonical(provider: "gemini", model: "gemini-custom-private-v99"))
        XCTAssertFalse(ModelCatalog.isCanonical(provider: "openai", model: "gpt-5-ultra-secret"))
        XCTAssertFalse(ModelCatalog.isCanonical(provider: "unknown-provider", model: "any-model"))
    }

    func test_model_catalog_default_model_matches_expected_values() {
        XCTAssertEqual(ModelCatalog.defaultModel(forProvider: "gemini"),         "gemini-2.5-flash-lite",       "gemini default should be the first entry (Flash-Lite)")
        XCTAssertEqual(ModelCatalog.defaultModel(forProvider: "vertex"),         "gemini-2.5-flash-lite",       "vertex default should be the first entry (Flash-Lite)")
        XCTAssertEqual(ModelCatalog.defaultModel(forProvider: "bedrock"),        "openai.gpt-oss-120b-1:0",     "bedrock default should be the first entry")
        XCTAssertEqual(ModelCatalog.defaultModel(forProvider: "bedrock-bearer"), "openai.gpt-oss-120b-1:0",     "bedrock-bearer default should be the first entry")
        XCTAssertEqual(ModelCatalog.defaultModel(forProvider: "azure"),          "gpt-4o-mini",                 "azure default should be gpt-4o-mini")
        XCTAssertEqual(ModelCatalog.defaultModel(forProvider: "openai"),         "gpt-4o-mini",                 "openai default should be gpt-4o-mini")
        // Unknown provider falls back to gemini-2.5-flash hardcoded sentinel.
        XCTAssertEqual(ModelCatalog.defaultModel(forProvider: "unknown"),        "gemini-2.5-flash",            "unknown provider should fall back to gemini-2.5-flash")
    }

    func test_custom_model_entry_enabled_false_non_canonical_cleanup_reset() {
        // When customModelEntryEnabled=false and the cleanup model is not
        // in the curated list for its provider, Config.load()'s defense-
        // in-depth pass resets it to the provider's curated default.
        // We test this by constructing a Config directly (disk round-trip
        // would clobber the developer's real config.json).
        var c = Config.default
        c.customModelEntryEnabled = false
        c.llmProvider = "gemini"
        c.llmModel = "gemini-custom-private-v99"  // not in catalog

        // Simulate what Config.load() does after the MDM overlay step.
        if !c.customModelEntryEnabled {
            if !ModelCatalog.isCanonical(provider: c.llmProvider, model: c.llmModel) {
                c.llmModel = ModelCatalog.defaultModel(forProvider: c.llmProvider)
            }
        }

        XCTAssertEqual(c.llmModel, ModelCatalog.defaultModel(forProvider: "gemini"),
                       "Non-canonical cleanup model should be reset to provider default when customModelEntryEnabled=false")
    }

    func test_custom_model_entry_enabled_false_canonical_cleanup_preserved() {
        // When customModelEntryEnabled=false and the cleanup model IS in
        // the curated list, it should be left alone.
        var c = Config.default
        c.customModelEntryEnabled = false
        c.llmProvider = "gemini"
        c.llmModel = "gemini-2.5-flash"  // canonical

        if !c.customModelEntryEnabled {
            if !ModelCatalog.isCanonical(provider: c.llmProvider, model: c.llmModel) {
                c.llmModel = ModelCatalog.defaultModel(forProvider: c.llmProvider)
            }
        }

        XCTAssertEqual(c.llmModel, "gemini-2.5-flash",
                       "Canonical cleanup model should be preserved even when customModelEntryEnabled=false")
    }

    func test_custom_model_entry_enabled_false_non_canonical_context_reset() {
        // Same validation for the context model tier.
        var c = Config.default
        c.customModelEntryEnabled = false
        c.contextModel = ModelIdentifier(provider: "openai", model: "gpt-5-ultra-secret")  // not in catalog

        if !c.customModelEntryEnabled {
            if let ctx = c.contextModel,
               !ModelCatalog.isCanonical(provider: ctx.provider, model: ctx.model) {
                c.contextModel = ModelIdentifier(
                    provider: ctx.provider,
                    model: ModelCatalog.defaultModel(forProvider: ctx.provider)
                )
            }
        }

        XCTAssertEqual(c.contextModel?.model, ModelCatalog.defaultModel(forProvider: "openai"),
                       "Non-canonical context model should be reset to provider default when customModelEntryEnabled=false")
    }

    func test_custom_model_entry_enabled_true_non_canonical_preserved() {
        // When customModelEntryEnabled=true (the default), any model
        // name should be accepted as-is — no reset.
        var c = Config.default
        // customModelEntryEnabled defaults to true
        XCTAssertTrue(c.customModelEntryEnabled)
        c.llmProvider = "gemini"
        c.llmModel = "gemini-custom-private-v99"

        // The validation gate is only entered when the toggle is false.
        if !c.customModelEntryEnabled {
            if !ModelCatalog.isCanonical(provider: c.llmProvider, model: c.llmModel) {
                c.llmModel = ModelCatalog.defaultModel(forProvider: c.llmProvider)
            }
        }

        XCTAssertEqual(c.llmModel, "gemini-custom-private-v99",
                       "When customModelEntryEnabled=true, any model name should be preserved")
    }
}
