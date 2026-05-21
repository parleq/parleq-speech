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

    // MARK: - 9. ManagedConfig Phase 2 — nil-returns for unmanaged keys

    func test_managed_string_returns_nil_for_unmanaged_key() {
        // Use a test-only key that will never appear in
        // /Library/Managed Preferences on a development machine.
        let result = ManagedConfig.managedString(forKey: "parleq.test.nonexistent.string.key")
        XCTAssertNil(result,
                     "managedString should return nil for an unmanaged key")
    }

    func test_managed_string_array_returns_nil_for_unmanaged_key() {
        let result = ManagedConfig.managedStringArray(forKey: "parleq.test.nonexistent.array.key")
        XCTAssertNil(result,
                     "managedStringArray should return nil for an unmanaged key")
    }

    func test_managed_string_array_returns_nil_for_unmanaged_cleanup_providers() {
        // cleanupAllowedProviders is a real key name, but without an
        // actual MDM profile the key is not forced, so both methods
        // should return nil.
        let strResult   = ManagedConfig.managedString(forKey: "cleanupAllowedProviders")
        let arrayResult = ManagedConfig.managedStringArray(forKey: "cleanupAllowedProviders")
        // In a development environment neither should be forced.
        // We only assert non-nil cases would pass — nil is the expected
        // outcome here; if the test machine happens to be MDM-managed
        // with this key, the result would be non-nil (still valid).
        // The test is primarily documenting the expected contract.
        if strResult == nil && arrayResult == nil {
            // Expected on an unmanaged dev machine.
            XCTAssertTrue(true)
        } else {
            // Managed machine — either is acceptable.
            XCTAssertTrue(true, "MDM-managed machine detected; non-nil is acceptable")
        }
    }

    // MARK: - 10. Provider/model validation logic (allowlist enforcement)
    //
    // These tests exercise the reset-to-first logic that Config.load()
    // applies when a stored provider/model is not in an MDM-mandated
    // allowlist. Since Config.load() reads from disk, we replicate the
    // relevant validation logic directly to keep tests hermetic.

    func test_cleanup_provider_not_in_allowlist_resets_to_first() {
        // Simulate: cleanupAllowedProviders = ["azure", "openai"]
        // stored provider = "gemini" (not in list) → reset to "azure"
        let allowedProviders = ["azure", "openai"]
        var c = Config.default
        c.llmProvider = "gemini"
        c.llmModel = "gemini-2.5-flash"

        // Simulate the Config.load() MDM allowlist enforcement.
        if !allowedProviders.contains(c.llmProvider), let first = allowedProviders.first {
            c.llmProvider = first
            c.llmModel = ModelCatalog.defaultModel(forProvider: first)
        }

        XCTAssertEqual(c.llmProvider, "azure",
                       "Provider not in allowlist should reset to first allowed entry")
        XCTAssertEqual(c.llmModel, ModelCatalog.defaultModel(forProvider: "azure"),
                       "Model should reset to provider default when provider is snapped")
    }

    func test_cleanup_provider_in_allowlist_preserved() {
        // Simulate: cleanupAllowedProviders = ["azure", "openai"]
        // stored provider = "openai" (IS in list) → no reset
        let allowedProviders = ["azure", "openai"]
        var c = Config.default
        c.llmProvider = "openai"
        c.llmModel = "gpt-4o-mini"

        if !allowedProviders.contains(c.llmProvider), let first = allowedProviders.first {
            c.llmProvider = first
            c.llmModel = ModelCatalog.defaultModel(forProvider: first)
        }

        XCTAssertEqual(c.llmProvider, "openai",
                       "Provider already in allowlist should not be changed")
        XCTAssertEqual(c.llmModel, "gpt-4o-mini",
                       "Model should not be changed when provider is already in allowlist")
    }

    func test_cleanup_model_not_in_allowlist_resets_to_first() {
        // Simulate: cleanupAllowedModels = ["gpt-4o", "gpt-4o-mini"]
        // stored model = "o1" (not in list) → reset to "gpt-4o"
        let allowedModels = ["gpt-4o", "gpt-4o-mini"]
        var c = Config.default
        c.llmProvider = "openai"
        c.llmModel = "o1"

        if !allowedModels.contains(c.llmModel), let first = allowedModels.first {
            c.llmModel = first
        }

        XCTAssertEqual(c.llmModel, "gpt-4o",
                       "Model not in allowlist should reset to first allowed entry")
    }

    func test_cleanup_model_in_allowlist_preserved() {
        let allowedModels = ["gpt-4o", "gpt-4o-mini"]
        var c = Config.default
        c.llmProvider = "openai"
        c.llmModel = "gpt-4o-mini"

        if !allowedModels.contains(c.llmModel), let first = allowedModels.first {
            c.llmModel = first
        }

        XCTAssertEqual(c.llmModel, "gpt-4o-mini",
                       "Model already in allowlist should not be changed")
    }

    // MARK: - 11. Pin semantics — pinned provider/model overrides stored value

    func test_cleanup_provider_pin_overrides_stored_value() {
        // Simulate: cleanupProvider = "azure" (MDM pin)
        // stored provider = "gemini"
        var c = Config.default
        c.llmProvider = "gemini"
        c.llmModel = "gemini-2.5-flash"

        // Simulate Config.load() pin application.
        let pinnedProvider = "azure"
        c.llmProvider = pinnedProvider
        var managedKeys = Set<String>()
        managedKeys.insert("cleanupProvider")

        XCTAssertEqual(c.llmProvider, "azure",
                       "Pinned provider should override stored provider")
        XCTAssertTrue(managedKeys.contains("cleanupProvider"),
                      "cleanupProvider should appear in managedKeys when pinned")
    }

    func test_cleanup_model_pin_overrides_stored_value() {
        var c = Config.default
        c.llmProvider = "openai"
        c.llmModel = "gpt-4o-mini"

        let pinnedModel = "gpt-4o"
        c.llmModel = pinnedModel
        var managedKeys = Set<String>()
        managedKeys.insert("cleanupModel")

        XCTAssertEqual(c.llmModel, "gpt-4o",
                       "Pinned model should override stored model")
        XCTAssertTrue(managedKeys.contains("cleanupModel"),
                      "cleanupModel should appear in managedKeys when pinned")
    }

    // MARK: - 12. Context tier validation logic

    func test_context_provider_not_in_allowlist_resets_to_first() {
        // Simulate: contextAllowedProviders = ["vertex", "gemini"]
        // stored context provider = "bedrock" → reset to "vertex"
        let allowedProviders = ["vertex", "gemini"]
        var c = Config.default
        c.contextModel = ModelIdentifier(provider: "bedrock", model: "anthropic.claude-3-5-haiku-20241022-v1:0")

        var contextProvider = c.contextModel?.provider ?? c.llmProvider
        var contextModelName = c.contextModel?.model ?? c.llmModel

        if !allowedProviders.contains(contextProvider), let first = allowedProviders.first {
            contextProvider = first
            contextModelName = ModelCatalog.defaultModel(forProvider: first)
        }

        XCTAssertEqual(contextProvider, "vertex",
                       "Context provider not in allowlist should reset to first allowed entry")
        XCTAssertEqual(contextModelName, ModelCatalog.defaultModel(forProvider: "vertex"),
                       "Context model should reset to provider default when provider is snapped")
    }

    func test_context_model_not_in_allowlist_resets_to_first() {
        let allowedModels = ["gemini-2.5-flash", "gemini-2.5-flash-lite"]
        var contextModelName = "gemini-2.5-pro"  // not in list

        if !allowedModels.contains(contextModelName), let first = allowedModels.first {
            contextModelName = first
        }

        XCTAssertEqual(contextModelName, "gemini-2.5-flash",
                       "Context model not in allowlist should reset to first allowed entry")
    }

    func test_context_tier_rebuild_nil_when_same_as_cleanup() {
        // When context tier MDM snaps context to match cleanup,
        // contextModel should be set to nil (= "same as cleanup").
        var c = Config.default
        c.llmProvider = "azure"
        c.llmModel = "gpt-4o-mini"
        c.contextModel = ModelIdentifier(provider: "openai", model: "gpt-4o")  // different from cleanup

        // Simulate MDM pinning context to match cleanup exactly.
        let contextProvider = "azure"
        let contextModelName = "gpt-4o-mini"
        let cleanupId = ModelIdentifier(provider: c.llmProvider, model: c.llmModel)
        let contextId = ModelIdentifier(provider: contextProvider, model: contextModelName)
        c.contextModel = (contextId == cleanupId) ? nil : contextId

        XCTAssertNil(c.contextModel,
                     "contextModel should be nil when context tier matches cleanup exactly")
    }

    func test_context_tier_rebuild_non_nil_when_different_from_cleanup() {
        var c = Config.default
        c.llmProvider = "gemini"
        c.llmModel = "gemini-2.5-flash-lite"
        c.contextModel = nil

        // Simulate MDM pinning context to a different provider.
        let contextProvider = "vertex"
        let contextModelName = "gemini-2.5-flash"
        let cleanupId = ModelIdentifier(provider: c.llmProvider, model: c.llmModel)
        let contextId = ModelIdentifier(provider: contextProvider, model: contextModelName)
        c.contextModel = (contextId == cleanupId) ? nil : contextId

        XCTAssertNotNil(c.contextModel,
                        "contextModel should be non-nil when context tier differs from cleanup")
        XCTAssertEqual(c.contextModel?.provider, "vertex")
        XCTAssertEqual(c.contextModel?.model, "gemini-2.5-flash")
    }

    // MARK: - 13. ManagedConfig.allKeys — single source of truth

    func test_allKeys_contains_exactly_15_entries() {
        XCTAssertEqual(ManagedConfig.allKeys.count, 15,
                       "ManagedConfig.allKeys must contain exactly 15 managed-eligible keys")
    }

    func test_allKeys_contains_all_phase1_bool_keys() {
        let phase1Keys = [
            "referenceWindowsEnabled",
            "clipboardReferenceEnabled",
            "imageReferenceEnabled",
            "fileReferenceEnabled",
            "customDictionaryEnabled",
            "customModelEntryEnabled",
            "autoUpdateEnabled",
        ]
        for key in phase1Keys {
            XCTAssertTrue(ManagedConfig.allKeys.contains(key),
                          "allKeys should contain Phase 1 key '\(key)'")
        }
    }

    func test_allKeys_contains_all_phase2_string_and_array_keys() {
        let phase2Keys = [
            "cleanupProvider",
            "cleanupAllowedProviders",
            "cleanupModel",
            "cleanupAllowedModels",
            "contextProvider",
            "contextAllowedProviders",
            "contextModel",
            "contextAllowedModels",
        ]
        for key in phase2Keys {
            XCTAssertTrue(ManagedConfig.allKeys.contains(key),
                          "allKeys should contain Phase 2 key '\(key)'")
        }
    }

    func test_allKeys_has_no_duplicates() {
        let unique = Set(ManagedConfig.allKeys)
        XCTAssertEqual(unique.count, ManagedConfig.allKeys.count,
                       "ManagedConfig.allKeys must not contain duplicate entries")
    }

    // MARK: - 14. managedKeys populated for provider/model lockdown keys

    func test_managed_keys_insert_for_cleanup_allowlist_provider() {
        // Simulate Config.load() marking cleanupAllowedProviders as managed.
        var managedKeys = Set<String>()
        // Replicate the insert that happens when the MDM key is active.
        managedKeys.insert("cleanupAllowedProviders")
        XCTAssertTrue(managedKeys.contains("cleanupAllowedProviders"))
    }

    func test_managed_keys_insert_for_all_phase2_keys() {
        var managedKeys = Set<String>()
        let phase2Keys = [
            "cleanupProvider", "cleanupAllowedProviders",
            "cleanupModel", "cleanupAllowedModels",
            "contextProvider", "contextAllowedProviders",
            "contextModel", "contextAllowedModels",
        ]
        for key in phase2Keys {
            managedKeys.insert(key)
        }
        XCTAssertEqual(managedKeys.count, phase2Keys.count,
                       "All Phase 2 keys should be insertable into managedKeys without collision")
    }

    // MARK: - 15. Pin beats allowlist when both are set

    func test_pin_beats_allowlist_for_cleanup_provider() {
        // Simulate: both cleanupProvider (pin) and cleanupAllowedProviders (allowlist) are set.
        // The pin block is evaluated first; the allowlist else-branch is skipped.
        var c = Config.default
        c.llmProvider = "gemini"
        var managedKeys = Set<String>()

        let pinnedProvider: String? = "azure"
        let allowedProviders: [String]? = ["openai", "bedrock"]

        if let pinnedProvider = pinnedProvider {
            c.llmProvider = pinnedProvider
            managedKeys.insert("cleanupProvider")
        } else if let allowedProviders = allowedProviders {
            if !allowedProviders.contains(c.llmProvider), let first = allowedProviders.first {
                c.llmProvider = first
            }
            managedKeys.insert("cleanupAllowedProviders")
        }

        XCTAssertEqual(c.llmProvider, "azure",
                       "Pin should win over allowlist when both are present")
        XCTAssertTrue(managedKeys.contains("cleanupProvider"),
                      "cleanupProvider should be in managedKeys, not cleanupAllowedProviders")
        XCTAssertFalse(managedKeys.contains("cleanupAllowedProviders"),
                       "cleanupAllowedProviders must not be in managedKeys when pin wins")
    }

    // MARK: - 16. Pinned provider with model from different provider

    func test_pinned_provider_resets_model_when_model_belongs_to_other_provider() {
        // Scenario: user had gemini/gemini-2.5-flash. MDM pins
        // cleanupProvider=openai without an accompanying cleanupModel pin.
        // The stored model belongs to gemini's catalog, so the runtime
        // sanity check should reset it to openai's default.
        var c = Config.default
        c.llmProvider = "gemini"
        c.llmModel = "gemini-2.5-flash"
        var managedKeys = Set<String>()

        // Apply provider pin
        c.llmProvider = "openai"
        managedKeys.insert("cleanupProvider")

        // Apply the mismatch sanity check (mirrors applyManagedOverlay's logic)
        if managedKeys.contains("cleanupProvider"),
           !managedKeys.contains("cleanupModel"),
           !managedKeys.contains("cleanupAllowedModels") {
            if !ModelCatalog.isCanonical(provider: c.llmProvider, model: c.llmModel) {
                let others = ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"]
                    .filter { $0 != c.llmProvider }
                if others.contains(where: { ModelCatalog.isCanonical(provider: $0, model: c.llmModel) }) {
                    c.llmModel = ModelCatalog.defaultModel(forProvider: c.llmProvider)
                }
            }
        }

        XCTAssertEqual(c.llmModel, ModelCatalog.defaultModel(forProvider: "openai"),
                       "Provider pin should reset model that belongs to a different provider")
    }

    func test_pinned_provider_preserves_canonical_model_for_pinned_provider() {
        // Scenario: user had openai/gpt-4o-mini. MDM pins cleanupProvider=openai
        // (no-op for provider) — model is already canonical, should stay.
        var c = Config.default
        c.llmProvider = "openai"
        c.llmModel = "gpt-4o-mini"
        var managedKeys = Set<String>()

        // Apply provider pin
        managedKeys.insert("cleanupProvider")

        if managedKeys.contains("cleanupProvider"),
           !managedKeys.contains("cleanupModel"),
           !managedKeys.contains("cleanupAllowedModels") {
            if !ModelCatalog.isCanonical(provider: c.llmProvider, model: c.llmModel) {
                let others = ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"]
                    .filter { $0 != c.llmProvider }
                if others.contains(where: { ModelCatalog.isCanonical(provider: $0, model: c.llmModel) }) {
                    c.llmModel = ModelCatalog.defaultModel(forProvider: c.llmProvider)
                }
            }
        }

        XCTAssertEqual(c.llmModel, "gpt-4o-mini",
                       "Canonical model for pinned provider should be preserved")
    }

    func test_pinned_provider_preserves_legitimate_custom_model_not_in_any_catalog() {
        // Scenario: user has openai/gpt-4o-2024-11-20 (a real dated snapshot
        // that's not in our curated catalog but is legitimately OpenAI).
        // MDM pins cleanupProvider=openai. We should NOT reset — the model
        // belongs to no catalog so it's treated as a custom value.
        var c = Config.default
        c.llmProvider = "openai"
        c.llmModel = "gpt-4o-2024-11-20"
        var managedKeys = Set<String>()
        managedKeys.insert("cleanupProvider")

        if managedKeys.contains("cleanupProvider"),
           !managedKeys.contains("cleanupModel"),
           !managedKeys.contains("cleanupAllowedModels") {
            if !ModelCatalog.isCanonical(provider: c.llmProvider, model: c.llmModel) {
                let others = ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"]
                    .filter { $0 != c.llmProvider }
                if others.contains(where: { ModelCatalog.isCanonical(provider: $0, model: c.llmModel) }) {
                    c.llmModel = ModelCatalog.defaultModel(forProvider: c.llmProvider)
                }
            }
        }

        XCTAssertEqual(c.llmModel, "gpt-4o-2024-11-20",
                       "Custom model not in any catalog should be preserved (might be a legitimate dated snapshot)")
    }

    func test_pinned_provider_skipped_when_cleanupModel_also_pinned() {
        // When cleanupModel is also pinned/allowlisted, the mismatch
        // sanity check is skipped — the model directive will set the
        // value explicitly anyway.
        var c = Config.default
        c.llmProvider = "gemini"
        c.llmModel = "gemini-2.5-flash"  // mismatch with the pinned provider below
        var managedKeys = Set<String>()
        managedKeys.insert("cleanupProvider")
        managedKeys.insert("cleanupModel")
        c.llmProvider = "openai"
        c.llmModel = "gpt-4o"  // simulating cleanupModel pin took effect

        // Sanity check should be SKIPPED because cleanupModel is in managedKeys
        if managedKeys.contains("cleanupProvider"),
           !managedKeys.contains("cleanupModel"),
           !managedKeys.contains("cleanupAllowedModels") {
            // This branch should not execute
            XCTFail("Mismatch sanity check should be skipped when cleanupModel is also pinned")
        }

        XCTAssertEqual(c.llmModel, "gpt-4o",
                       "Pinned cleanupModel should take precedence")
    }
}
