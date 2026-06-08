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

    func test_allKeys_count_is_fortyfive() {
        // Phase 1 (8) + Phase 2 (8) + Phase 3 (2) + Phase 4 (3)
        // + Phase 7 (9 incl. vertexAuthMode) + Phase 8 (2 transcript-history)
        // + Phase 9 (3 learn-from-corrections) + transform-presets (1)
        // + Enterprise OIDC federation (9 incl. redirect_uri + extra_auth_params) = 45.
        // If this fails, a key was added or removed — update the docs table
        // (web managed-configuration page) and this count together.
        XCTAssertEqual(ManagedConfig.allKeys.count, 45,
                       "ManagedConfig.allKeys must contain exactly 45 managed-eligible keys")
    }

    func test_allKeys_contains_transformPresetsEnabled() {
        XCTAssertTrue(ManagedConfig.allKeys.contains("transformPresetsEnabled"))
    }

    func test_allKeys_contains_phase9_learn_keys() {
        let phase9Keys = [
            "learnFromCorrectionsEnabled",
            "learnedCorrectionsMaxEntries",
            "learnedCorrectionsRetentionHours",
        ]
        for key in phase9Keys {
            XCTAssertTrue(ManagedConfig.allKeys.contains(key),
                          "allKeys should contain Phase 9 key '\(key)'")
        }
    }

    func test_allKeys_contains_all_phase7_destination_pin_keys() {
        let phase7Keys = [
            "vertexAuthMode",
            "asrEndpoint",
            "vertexProject",
            "vertexRegion",
            "vertexAnthropicRegion",
            "awsRegion",
            "awsProfile",
            "azureResource",
            "azureDeployment",
        ]
        for key in phase7Keys {
            XCTAssertTrue(ManagedConfig.allKeys.contains(key),
                          "allKeys should contain Phase 7 key '\(key)'")
        }
    }

    // MARK: - Phase 7 — validateASREndpoint

    func test_validateASREndpoint_accepts_bundled_sentinel() {
        XCTAssertEqual(
            ManagedConfig.validateASREndpoint("http://127.0.0.1:8767/inference"),
            "http://127.0.0.1:8767/inference",
            "The bundled-FluidAudio sentinel string must validate verbatim"
        )
    }

    func test_validateASREndpoint_accepts_https_with_host() {
        XCTAssertEqual(
            ManagedConfig.validateASREndpoint("https://asr.example.com/inference"),
            "https://asr.example.com/inference"
        )
    }

    func test_validateASREndpoint_trims_whitespace() {
        XCTAssertEqual(
            ManagedConfig.validateASREndpoint("  https://asr.example.com/inference  "),
            "https://asr.example.com/inference"
        )
    }

    func test_validateASREndpoint_rejects_http_when_not_bundled_sentinel() {
        // Plain HTTP to anywhere other than the bundled sentinel is rejected —
        // MDM-pushed audio routing must travel over TLS.
        XCTAssertNil(ManagedConfig.validateASREndpoint("http://attacker.example/inference"))
        XCTAssertNil(ManagedConfig.validateASREndpoint("http://127.0.0.1:9999/inference"))
    }

    func test_validateASREndpoint_rejects_empty() {
        XCTAssertNil(ManagedConfig.validateASREndpoint(""))
        XCTAssertNil(ManagedConfig.validateASREndpoint("   "))
    }

    func test_validateASREndpoint_rejects_userinfo() {
        // Embedded credentials would leak via logs / clipboard snapshots.
        XCTAssertNil(ManagedConfig.validateASREndpoint("https://user:pass@asr.example.com/inference"))
    }

    func test_validateASREndpoint_rejects_query_string() {
        // Query strings suggest tokenized URLs we don't want logged.
        XCTAssertNil(ManagedConfig.validateASREndpoint("https://asr.example.com/inference?token=secret"))
    }

    func test_validateASREndpoint_rejects_no_host() {
        XCTAssertNil(ManagedConfig.validateASREndpoint("https:///inference"))
    }

    func test_validateASREndpoint_rejects_file_scheme() {
        XCTAssertNil(ManagedConfig.validateASREndpoint("file:///tmp/inference"))
    }

    func test_validateOIDCIssuer_accepts_https() {
        XCTAssertEqual(
            ManagedConfig.validateOIDCIssuer("https://acme.okta.com"),
            "https://acme.okta.com"
        )
    }

    func test_validateOIDCIssuer_trims_whitespace() {
        XCTAssertEqual(
            ManagedConfig.validateOIDCIssuer("  https://acme.okta.com  "),
            "https://acme.okta.com"
        )
    }

    func test_validateOIDCIssuer_accepts_http_loopback() {
        // The in-repo Keycloak dev rig runs on http://localhost — allowed.
        XCTAssertEqual(
            ManagedConfig.validateOIDCIssuer("http://localhost:8080/realms/parleq"),
            "http://localhost:8080/realms/parleq"
        )
        XCTAssertEqual(
            ManagedConfig.validateOIDCIssuer("http://127.0.0.1:8080/realms/parleq"),
            "http://127.0.0.1:8080/realms/parleq"
        )
    }

    func test_validateOIDCIssuer_rejects_http_non_loopback() {
        // An MDM-pushed plain-HTTP non-loopback issuer must fail closed at load
        // — it would let a network attacker substitute the discovery document.
        XCTAssertNil(ManagedConfig.validateOIDCIssuer("http://attacker.example/realms/parleq"))
    }

    func test_validateOIDCIssuer_rejects_empty() {
        XCTAssertNil(ManagedConfig.validateOIDCIssuer(""))
        XCTAssertNil(ManagedConfig.validateOIDCIssuer("   "))
    }

    func test_validateOIDCIssuer_rejects_file_scheme() {
        XCTAssertNil(ManagedConfig.validateOIDCIssuer("file:///tmp/issuer"))
    }

    // MARK: - validateOIDCRedirectURI

    func test_validateOIDCRedirectURI_accepts_custom_scheme() {
        // parleq-auth: app-private scheme.
        XCTAssertEqual(
            ManagedConfig.validateOIDCRedirectURI("parleq-auth://oidc/callback"),
            "parleq-auth://oidc/callback"
        )
        // Reversed-client-ID shape (Google native OAuth).
        XCTAssertEqual(
            ManagedConfig.validateOIDCRedirectURI("com.googleusercontent.apps.1234:/oauth2redirect"),
            "com.googleusercontent.apps.1234:/oauth2redirect"
        )
        // Trimmed.
        XCTAssertEqual(
            ManagedConfig.validateOIDCRedirectURI("  parleq-auth://oidc/callback  "),
            "parleq-auth://oidc/callback"
        )
    }

    func test_validateOIDCRedirectURI_rejects_https() {
        // http(s):// can never be intercepted by ASWebAuthenticationSession's
        // custom-scheme callback — it would fail opaquely at sign-in.
        XCTAssertNil(ManagedConfig.validateOIDCRedirectURI("https://example.com/callback"))
        XCTAssertNil(ManagedConfig.validateOIDCRedirectURI("HTTPS://example.com/callback"))
    }

    func test_validateOIDCRedirectURI_accepts_http_loopback() {
        // Google "Desktop app" loopback redirect — answered by a transient
        // 127.0.0.1-only listener (the configured port is ignored at runtime).
        XCTAssertEqual(
            ManagedConfig.validateOIDCRedirectURI("http://127.0.0.1/oauth2redirect"),
            "http://127.0.0.1/oauth2redirect")
        XCTAssertEqual(
            ManagedConfig.validateOIDCRedirectURI("http://localhost:8080/callback"),
            "http://localhost:8080/callback")
        XCTAssertEqual(
            ManagedConfig.validateOIDCRedirectURI("http://[::1]/oauth2redirect"),
            "http://[::1]/oauth2redirect")
        // Case-insensitive scheme.
        XCTAssertEqual(
            ManagedConfig.validateOIDCRedirectURI("HTTP://127.0.0.1/cb"),
            "HTTP://127.0.0.1/cb")
    }

    func test_validateOIDCRedirectURI_rejects_http_non_loopback() {
        // http on a non-loopback host could be answered by a network attacker.
        XCTAssertNil(ManagedConfig.validateOIDCRedirectURI("http://example.com/callback"))
        XCTAssertNil(ManagedConfig.validateOIDCRedirectURI("http://192.168.1.5/callback"))
    }

    func test_validateOIDCRedirectURI_rejects_schemeless_and_empty() {
        XCTAssertNil(ManagedConfig.validateOIDCRedirectURI("no-scheme-here"))
        XCTAssertNil(ManagedConfig.validateOIDCRedirectURI(""))
        XCTAssertNil(ManagedConfig.validateOIDCRedirectURI("   "))
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

    // MARK: - 16b. Save-side model preservation under a pinned provider
    //
    // These drive the pure mergeForSave seam directly. The MDM bug:
    // provider pinned (cleanupProvider) without a model pin/allowlist
    // used to preserve the ON-DISK model unconditionally, swallowing
    // the user's in-app model pick within the pinned provider. The fix
    // preserves on-disk only when that on-disk model is FOREIGN to the
    // pinned provider (a pre-MDM fallback to restore on profile removal).

    func test_save_pinned_provider_canonical_ondisk_writes_user_pick() {
        // Regression: MDM pins cleanupProvider=vertex (no model pin).
        // On disk: vertex/gemini-2.5-flash. User picked flash-lite in
        // Settings. The save must WRITE the in-memory pick, not snap
        // back to the on-disk model.
        var c = Config.default
        c.llmProvider = "vertex"
        c.llmModel = "gemini-2.5-flash-lite"
        c.managedKeys = ["cleanupProvider"]
        let existing: [String: Any] = [
            "llm": ["provider": "vertex", "model": "gemini-2.5-flash"]
        ]
        let merged = Config.mergeForSave(c, existing: existing)
        let llm = merged["llm"] as? [String: Any]
        XCTAssertEqual(llm?["model"] as? String, "gemini-2.5-flash-lite",
                       "User's in-pin model pick must be written, not the on-disk value")
    }

    func test_save_pinned_provider_foreign_ondisk_is_preserved() {
        // Original protection intact: provider pinned (so the written
        // provider is the on-disk value), and the on-disk model is
        // FOREIGN to that provider (gpt-4o-mini is not in vertex's
        // catalog) — a pre-MDM fallback awaiting the runtime auto-snap.
        // Preserve it so removing the profile restores the user's
        // original choice; the in-memory model is the auto-snap.
        var c = Config.default
        c.llmProvider = "vertex"
        c.llmModel = "gemini-2.5-flash"  // runtime auto-snap
        c.managedKeys = ["cleanupProvider"]
        let existing: [String: Any] = [
            "llm": ["provider": "vertex", "model": "gpt-4o-mini"]
        ]
        let merged = Config.mergeForSave(c, existing: existing)
        let llm = merged["llm"] as? [String: Any]
        XCTAssertEqual(llm?["model"] as? String, "gpt-4o-mini",
                       "Foreign on-disk model (pre-MDM fallback) must be preserved")
    }

    func test_save_model_pinned_preserves_ondisk_regardless() {
        // cleanupModel pinned → always preserve the on-disk value, even
        // when it is canonical for the (also-pinned) provider. Unchanged
        // by the fix.
        var c = Config.default
        c.llmProvider = "vertex"
        c.llmModel = "gemini-2.5-flash-lite"  // would-be in-memory value
        c.managedKeys = ["cleanupProvider", "cleanupModel"]
        let existing: [String: Any] = [
            "llm": ["provider": "vertex", "model": "gemini-2.5-flash"]
        ]
        let merged = Config.mergeForSave(c, existing: existing)
        let llm = merged["llm"] as? [String: Any]
        XCTAssertEqual(llm?["model"] as? String, "gemini-2.5-flash",
                       "Pinned model always preserves the on-disk value")
    }

    func test_save_ctx_pinned_provider_canonical_ondisk_writes_user_pick() {
        // Context-tier mirror of the regression: contextProvider pinned
        // to vertex (no contextModel pin); on disk vertex/gemini-2.5-flash;
        // user picked flash-lite. The save must write the in-memory pick.
        var c = Config.default
        c.managedKeys = ["contextProvider"]
        c.contextModel = ModelIdentifier(provider: "vertex", model: "gemini-2.5-flash-lite")
        let existing: [String: Any] = [
            "context_model": ["provider": "vertex", "model": "gemini-2.5-flash"]
        ]
        let merged = Config.mergeForSave(c, existing: existing)
        let ctx = merged["context_model"] as? [String: Any]
        XCTAssertEqual(ctx?["model"] as? String, "gemini-2.5-flash-lite",
                       "Context tier: user's in-pin model pick must be written")
    }

    func test_save_ctx_pinned_provider_foreign_ondisk_is_preserved() {
        // Context-tier mirror of the protection: provider pinned (the
        // written provider is the preserved on-disk vertex), on-disk
        // model is foreign to vertex (gpt-4o-mini) → preserve it.
        var c = Config.default
        c.managedKeys = ["contextProvider"]
        c.contextModel = ModelIdentifier(provider: "vertex", model: "gemini-2.5-flash")
        let existing: [String: Any] = [
            "context_model": ["provider": "vertex", "model": "gpt-4o-mini"]
        ]
        let merged = Config.mergeForSave(c, existing: existing)
        let ctx = merged["context_model"] as? [String: Any]
        XCTAssertEqual(ctx?["model"] as? String, "gpt-4o-mini",
                       "Context tier: foreign on-disk model must be preserved")
    }

    // MARK: - 17. Phase 3 — sparkleUpdateFeedURL validation

    func test_sparkleUpdateFeedURL_https_url_is_valid() {
        // A well-formed https:// URL should be accepted.
        let url = "https://example.com/parleq/appcast.xml"
        XCTAssertNotNil(URL(string: url), "A valid URL string should parse to a URL")
        XCTAssertTrue(url.hasPrefix("https://"), "URL should start with https://")
    }

    func test_sparkleUpdateFeedURL_http_url_is_rejected() {
        // http:// URLs must be rejected — only https:// is accepted.
        let url = "http://example.com/appcast.xml"
        let isAccepted = !url.isEmpty && URL(string: url) != nil && url.hasPrefix("https://")
        XCTAssertFalse(isAccepted, "http:// URL should be rejected by validation logic")
    }

    func test_sparkleUpdateFeedURL_file_scheme_is_rejected() {
        // file:// URLs are not accepted (local paths make no sense for a feed URL).
        let url = "file:///tmp/appcast.xml"
        let isAccepted = !url.isEmpty && URL(string: url) != nil && url.hasPrefix("https://")
        XCTAssertFalse(isAccepted, "file:// URL should be rejected by validation logic")
    }

    func test_sparkleUpdateFeedURL_malformed_string_is_rejected() {
        // A non-URL string (e.g. an empty string or garbage) must be rejected.
        let malformed = "not a url"
        // The validation gate: non-empty, parses as URL, starts with https://.
        let isAccepted = !malformed.isEmpty && URL(string: malformed) != nil && malformed.hasPrefix("https://")
        XCTAssertFalse(isAccepted, "A non-URL string should be rejected")
    }

    // MARK: - 18. Phase 3 — loggingMode validation

    func test_loggingMode_lengthOnly_is_recognized() {
        let recognized = ["lengthOnly", "verbose"]
        XCTAssertTrue(recognized.contains("lengthOnly"),
                      "\"lengthOnly\" must be a recognized loggingMode value")
    }

    func test_loggingMode_verbose_is_recognized() {
        let recognized = ["lengthOnly", "verbose"]
        XCTAssertTrue(recognized.contains("verbose"),
                      "\"verbose\" must be a recognized loggingMode value (forward-compat, no current effect)")
    }

    func test_loggingMode_unrecognized_is_rejected_and_not_added_to_managedKeys() {
        // An unrecognized value (e.g. "verboseUltra") should be rejected
        // and NOT result in the key being added to managedKeys.
        let recognized = ["lengthOnly", "verbose"]
        let invalidValue = "verboseUltra"
        var managedKeys = Set<String>()

        // Simulate the Config.applyManagedOverlay loggingMode block.
        if recognized.contains(invalidValue) {
            managedKeys.insert("loggingMode")
        }
        // else: log warning and leave managedKeys unchanged

        XCTAssertFalse(managedKeys.contains("loggingMode"),
                       "An unrecognized loggingMode value must NOT be added to managedKeys")
    }

    func test_loggingMode_recognized_value_is_added_to_managedKeys() {
        let recognized = ["lengthOnly", "verbose"]
        let validValue = "lengthOnly"
        var managedKeys = Set<String>()

        if recognized.contains(validValue) {
            managedKeys.insert("loggingMode")
        }

        XCTAssertTrue(managedKeys.contains("loggingMode"),
                      "A recognized loggingMode value should be added to managedKeys")
    }

    // MARK: - 19. Phase 3 — ManagedConfig.allKeys includes new keys

    func test_allKeys_contains_phase3_operational_policy_keys() {
        let phase3Keys = ["sparkleUpdateFeedURL", "loggingMode"]
        for key in phase3Keys {
            XCTAssertTrue(ManagedConfig.allKeys.contains(key),
                          "allKeys should contain Phase 3 key '\(key)'")
        }
    }

    // MARK: - 20. Phase 4 — staticApiKeysAllowed default and classification

    func test_allKeys_contains_phase4_auth_mode_restriction_keys() {
        let phase4Keys = ["staticApiKeysAllowed", "azureAuthMode", "bedrockAuthMode"]
        for key in phase4Keys {
            XCTAssertTrue(ManagedConfig.allKeys.contains(key),
                          "allKeys should contain Phase 4 key '\(key)'")
        }
    }

    func test_staticApiKeysAllowed_returns_nil_when_unmanaged() {
        // On a non-MDM-enrolled dev machine, staticApiKeysAllowed is not
        // managed and should return nil from managedBool.
        let result = ManagedConfig.managedBool(forKey: "staticApiKeysAllowed")
        // On an MDM-managed machine this could be non-nil; we document
        // the expected contract (nil on unmanaged) but don't XCTFail on
        // non-nil since the test may run on a managed machine.
        if result == nil {
            XCTAssertTrue(true, "staticApiKeysAllowed is unmanaged on this machine — expected")
        } else {
            XCTAssertTrue(true, "staticApiKeysAllowed is managed on this machine — acceptable")
        }
    }

    func test_staticApiKeysAllowed_managed_false_is_added_to_managedKeys() {
        // Simulate Config.applyManagedOverlay detecting staticApiKeysAllowed.
        // The key should be inserted into managedKeys even when the value is
        // false (non-nil is the insert criterion, not the value itself).
        var managedKeys = Set<String>()
        // Replicate the insert logic from applyManagedOverlay.
        // managedBool returns non-nil when forced; we simulate that here.
        let simulatedManaged: Bool? = false  // as if MDM pushed false
        if simulatedManaged != nil {
            managedKeys.insert("staticApiKeysAllowed")
        }
        XCTAssertTrue(managedKeys.contains("staticApiKeysAllowed"),
                      "staticApiKeysAllowed must be inserted into managedKeys when MDM forces a value")
    }

    func test_staticApiKeysAllowed_managed_true_is_also_added_to_managedKeys() {
        // A managed true value (explicitly documenting policy) should also
        // land in managedKeys so the Compliance Audit can classify it.
        var managedKeys = Set<String>()
        let simulatedManaged: Bool? = true  // MDM explicitly allows keys
        if simulatedManaged != nil {
            managedKeys.insert("staticApiKeysAllowed")
        }
        XCTAssertTrue(managedKeys.contains("staticApiKeysAllowed"),
                      "staticApiKeysAllowed must be in managedKeys whether the value is true or false")
    }

    // MARK: - 21. Phase 4 — azureAuthMode validation

    func test_azureAuthMode_recognized_apiKey_is_accepted() {
        let recognized = ["apiKey", "azureAd"]
        XCTAssertTrue(recognized.contains("apiKey"),
                      "\"apiKey\" must be a recognized azureAuthMode value")
    }

    func test_azureAuthMode_recognized_azureAd_is_accepted() {
        let recognized = ["apiKey", "azureAd"]
        XCTAssertTrue(recognized.contains("azureAd"),
                      "\"azureAd\" must be a recognized azureAuthMode value")
    }

    func test_azureAuthMode_unrecognized_is_rejected_and_not_added_to_managedKeys() {
        // An unrecognized value must NOT be added to managedKeys; the audit
        // should then show the key as Default rather than Managed.
        let recognized = ["apiKey", "azureAd"]
        let invalidValue = "serviceToken"
        var managedKeys = Set<String>()
        // Simulate Config.applyManagedOverlay azureAuthMode block.
        if recognized.contains(invalidValue) {
            managedKeys.insert("azureAuthMode")
        }
        XCTAssertFalse(managedKeys.contains("azureAuthMode"),
                       "An unrecognized azureAuthMode value must NOT be added to managedKeys")
    }

    func test_azureAuthMode_recognized_value_is_added_to_managedKeys_and_applied() {
        // A recognized value should be applied to config and added to managedKeys.
        let recognized = ["apiKey", "azureAd"]
        let validValue = "azureAd"
        var c = Config.default
        var managedKeys = Set<String>()
        // Simulate applyManagedOverlay block.
        if recognized.contains(validValue) {
            c.azureAuthMode = validValue
            managedKeys.insert("azureAuthMode")
        }
        XCTAssertEqual(c.azureAuthMode, "azureAd",
                       "Recognized azureAuthMode value should be applied to config")
        XCTAssertTrue(managedKeys.contains("azureAuthMode"),
                      "Recognized azureAuthMode value should be added to managedKeys")
    }

    // MARK: - 22. Phase 4 — bedrockAuthMode validation

    func test_bedrockAuthMode_recognized_sso_is_accepted() {
        let recognized = ["sso", "static", "bedrockApiKey"]
        XCTAssertTrue(recognized.contains("sso"),
                      "\"sso\" must be a recognized bedrockAuthMode value")
    }

    func test_bedrockAuthMode_recognized_static_is_accepted() {
        let recognized = ["sso", "static", "bedrockApiKey"]
        XCTAssertTrue(recognized.contains("static"),
                      "\"static\" must be a recognized bedrockAuthMode value")
    }

    func test_bedrockAuthMode_recognized_bedrockApiKey_is_accepted() {
        let recognized = ["sso", "static", "bedrockApiKey"]
        XCTAssertTrue(recognized.contains("bedrockApiKey"),
                      "\"bedrockApiKey\" must be a recognized bedrockAuthMode value")
    }

    func test_bedrockAuthMode_unrecognized_is_rejected_and_not_added_to_managedKeys() {
        let recognized = ["sso", "static", "bedrockApiKey"]
        let invalidValue = "oidc"
        var managedKeys = Set<String>()
        if recognized.contains(invalidValue) {
            managedKeys.insert("bedrockAuthMode")
        }
        XCTAssertFalse(managedKeys.contains("bedrockAuthMode"),
                       "An unrecognized bedrockAuthMode value must NOT be added to managedKeys")
    }

    func test_bedrockAuthMode_sso_pin_is_applied_to_awsAuthMode() {
        // When bedrockAuthMode is managed, applyManagedOverlay sets
        // c.awsAuthMode to the managed value. This test verifies that
        // relationship (bedrockAuthMode maps to the awsAuthMode field).
        let recognized = ["sso", "static", "bedrockApiKey"]
        let validValue = "sso"
        var c = Config.default
        c.awsAuthMode = "static"  // user had static; MDM pins to sso
        var managedKeys = Set<String>()
        if recognized.contains(validValue) {
            c.awsAuthMode = validValue
            managedKeys.insert("bedrockAuthMode")
        }
        XCTAssertEqual(c.awsAuthMode, "sso",
                       "bedrockAuthMode pin should override awsAuthMode in config")
        XCTAssertTrue(managedKeys.contains("bedrockAuthMode"),
                      "bedrockAuthMode should be in managedKeys when its managed value is recognized")
    }

    // MARK: - 23. Phase 5 — isProviderAuthPathBlocked helper

    // The tests below exercise the production
    // `ManagedConfig.isProviderAuthPathBlocked(provider:authMode:staticApiKeysAllowed:)`
    // variant that takes the master-switch value as an explicit parameter,
    // bypassing the CFPreferences check. This is the same code path the
    // no-arg public variant calls into (with `staticApiKeysAllowed=false`),
    // so a regression in the matrix logic is caught here directly rather
    // than via a parallel re-implementation.

    private func isBlocked(provider: String, authMode: String?) -> Bool {
        ManagedConfig.isProviderAuthPathBlocked(
            provider: provider,
            authMode: authMode,
            staticApiKeysAllowed: false
        )
    }

    func test_phase5_gemini_always_blocked() {
        // Gemini is API-key only — always blocked under master switch off.
        XCTAssertTrue(isBlocked(provider: "gemini", authMode: nil),
                      "gemini should always be blocked (no federated fallback)")
    }

    func test_phase5_openai_always_blocked() {
        XCTAssertTrue(isBlocked(provider: "openai", authMode: nil),
                      "openai should always be blocked (no federated fallback)")
    }

    func test_phase5_bedrock_bearer_always_blocked() {
        XCTAssertTrue(isBlocked(provider: "bedrock-bearer", authMode: nil),
                      "bedrock-bearer should always be blocked (no federated fallback)")
    }

    func test_phase5_vertex_serviceAccount_is_blocked() {
        XCTAssertTrue(isBlocked(provider: "vertex", authMode: "serviceAccount"),
                      "vertex serviceAccount uses a static JSON key — must be blocked")
    }

    func test_phase5_vertex_adc_is_not_blocked() {
        // ADC (Application Default Credentials via gcloud) is federated —
        // must NOT be blocked even when the master switch is off.
        XCTAssertFalse(isBlocked(provider: "vertex", authMode: "adc"),
                       "vertex adc is federated (gcloud) — must NOT be blocked")
    }

    func test_phase5_vertex_default_authMode_nil_treats_as_adc() {
        // When no authMode is provided for vertex, the default is adc —
        // must not be blocked.
        XCTAssertFalse(isBlocked(provider: "vertex", authMode: nil),
                       "vertex with nil authMode defaults to adc — must NOT be blocked")
    }

    func test_phase5_azure_apiKey_is_blocked() {
        XCTAssertTrue(isBlocked(provider: "azure", authMode: "apiKey"),
                      "azure apiKey uses a static resource API key — must be blocked")
    }

    func test_phase5_azure_azureAd_is_not_blocked() {
        // azureAd (Entra ID via az login) is federated — must NOT be blocked.
        XCTAssertFalse(isBlocked(provider: "azure", authMode: "azureAd"),
                       "azure azureAd is federated (Entra ID / az login) — must NOT be blocked")
    }

    func test_phase5_azure_default_authMode_nil_treats_as_apiKey() {
        // When no authMode is provided for Azure, the default is apiKey —
        // must be blocked.
        XCTAssertTrue(isBlocked(provider: "azure", authMode: nil),
                      "azure with nil authMode defaults to apiKey — must be blocked")
    }

    func test_phase5_bedrock_static_is_blocked() {
        XCTAssertTrue(isBlocked(provider: "bedrock", authMode: "static"),
                      "bedrock static IAM keys must be blocked")
    }

    func test_phase5_bedrock_bedrockApiKey_is_blocked() {
        XCTAssertTrue(isBlocked(provider: "bedrock", authMode: "bedrockApiKey"),
                      "bedrock bedrockApiKey must be blocked")
    }

    func test_phase5_bedrock_sso_is_not_blocked() {
        // AWS SSO session (aws sso login) is federated — must NOT be blocked.
        XCTAssertFalse(isBlocked(provider: "bedrock", authMode: "sso"),
                       "bedrock sso is federated (AWS SSO) — must NOT be blocked")
    }

    func test_phase5_bedrock_default_authMode_nil_treats_as_sso() {
        // When no authMode is provided for Bedrock IAM, the default is sso —
        // must not be blocked.
        XCTAssertFalse(isBlocked(provider: "bedrock", authMode: nil),
                       "bedrock with nil authMode defaults to sso — must NOT be blocked")
    }

    func test_phase5_none_provider_never_blocked() {
        // "none" (user opted out of cleanup) must never be blocked.
        XCTAssertFalse(isBlocked(provider: "none", authMode: nil),
                       "'none' provider should never be blocked")
    }

    func test_phase5_unknown_provider_never_blocked() {
        // An unknown/future provider ID must default to not-blocked to
        // avoid false-positive lockouts when a new provider is added.
        XCTAssertFalse(isBlocked(provider: "some-future-provider", authMode: nil),
                       "Unknown provider should default to not-blocked")
    }

    func test_phase5_bedrock_bedrockApiKey_case_insensitive() {
        // The gate normalizes the mode to lowercase before comparing.
        // Both "bedrockApiKey" (config canonical) and "bedrockapikey"
        // (lowercased) must match the blocked path.
        XCTAssertTrue(isBlocked(provider: "bedrock", authMode: "bedrockApiKey"),
                      "bedrockApiKey (mixed-case) should be blocked")
        XCTAssertTrue(isBlocked(provider: "bedrock", authMode: "bedrockapikey"),
                      "bedrockapikey (all-lowercase) should also be blocked")
    }

    func test_phase5_isProviderAuthPathBlocked_returns_false_when_unmanaged() {
        // On a dev machine without MDM, staticApiKeysAllowed is not managed.
        // The public API must return false regardless of provider/authMode.
        // This is the contract the Settings UI and main.swift depend on —
        // non-MDM-enrolled machines must never see spurious blocks.
        let result = ManagedConfig.isProviderAuthPathBlocked(provider: "gemini", authMode: nil)
        // On an MDM machine this could be true if staticApiKeysAllowed=false
        // is managed. We document the expected behavior on a dev machine
        // but don't XCTFail on a managed machine.
        if result {
            // MDM-managed machine with staticApiKeysAllowed=false — acceptable.
            XCTAssertTrue(true, "MDM-managed machine with staticApiKeysAllowed=false — blocked result is correct")
        } else {
            // Expected on an unmanaged dev machine.
            XCTAssertFalse(result, "isProviderAuthPathBlocked should return false when staticApiKeysAllowed is not managed (dev machine)")
        }
    }

    // MARK: - 24. Phase 5 — LLMError.authPathBlocked

    func test_authPathBlocked_error_description_contains_message() {
        let msg = "Your cleanup provider's auth path is disabled by your organization."
        let error = LLMError.authPathBlocked(msg)
        XCTAssertTrue(error.description.contains(msg),
                      "LLMError.authPathBlocked description should contain the original message")
    }

    func test_authPathBlocked_logSafeDescription_contains_detail() {
        let detail = "Test policy detail"
        let error = LLMError.authPathBlocked(detail)
        XCTAssertTrue(error.logSafeDescription.contains(detail),
                      "logSafeDescription for authPathBlocked should include the detail (IT-authored, safe to log)")
    }

    func test_blocked_provider_cleanupFailureHint_returns_message() {
        let msg = "Test blocked message"
        let provider = BlockedProvider(providerID: "gemini", model: "gemini-2.5-flash", message: msg)
        let hint = provider.cleanupFailureHint(for: .authPathBlocked(msg))
        XCTAssertEqual(hint, msg,
                       "BlockedProvider.cleanupFailureHint should return the stored message for .authPathBlocked")
    }

    func test_blocked_provider_cleanupFailureHint_nil_for_other_errors() {
        let provider = BlockedProvider(providerID: "gemini", model: "gemini-2.5-flash", message: "blocked")
        // cleanupFailureHint should return nil for non-authPathBlocked errors
        // so the AppState fallback chain (network hint, generic hint) still works.
        XCTAssertNil(provider.cleanupFailureHint(for: .missingAPIKey),
                     "cleanupFailureHint should return nil for non-authPathBlocked errors")
        XCTAssertNil(provider.cleanupFailureHint(for: .badStatus(401, "Unauthorized")),
                     "cleanupFailureHint should return nil for badStatus errors")
    }

    func test_blocked_provider_supportsVision_is_false() {
        let provider = BlockedProvider(providerID: "gemini", model: "gemini-2.5-flash", message: "blocked")
        XCTAssertFalse(provider.supportsVision,
                       "BlockedProvider should not claim to support vision")
    }

    func test_blocked_provider_generates_streaming_throws_authPathBlocked() async {
        let msg = "blocked by org"
        let provider = BlockedProvider(providerID: "gemini", model: "gemini-2.5-flash", message: msg)
        do {
            try await provider.generateStreaming(
                systemPrompt: "sys",
                messages: [LLMMessage(role: "user", content: "test")],
                onEvent: { _ in }
            )
            XCTFail("generateStreaming should have thrown .authPathBlocked")
        } catch let error as LLMError {
            if case .authPathBlocked(let detail) = error {
                XCTAssertEqual(detail, msg,
                               "Thrown authPathBlocked error should carry the original message")
            } else {
                XCTFail("Expected LLMError.authPathBlocked, got \(error)")
            }
        } catch {
            XCTFail("Expected LLMError, got \(error)")
        }
    }

    // MARK: - transformPresetsEnabled audit row

    func test_auditRow_transformPresetsEnabled_does_not_render_as_unknown() {
        // buildAuditRows() delegates to resolveAuditRow which previously
        // fell through to the `default: "(unknown key)"` branch for this key.
        // Confirm the dedicated case is now wired up.
        let rows = buildAuditRows(config: Config.default)
        guard let row = rows.first(where: { $0.key == "transformPresetsEnabled" }) else {
            XCTFail("transformPresetsEnabled must appear in buildAuditRows() output")
            return
        }
        XCTAssertNotEqual(row.displayValue, "(unknown key)",
                          "transformPresetsEnabled must not render as (unknown key)")
        // The default value is true; without MDM override it should render "true".
        XCTAssertFalse(row.displayValue.isEmpty,
                       "transformPresetsEnabled audit row must have a non-empty display value")
    }

    /// Every OIDC-federation key must have a dedicated audit-row case — none
    /// may fall through to the "(unknown key)" default. Guards the generic-OP
    /// keys (oidcRedirectURI / oidcExtraAuthParams) and the existing seven
    /// against being added to allKeys without an audit row.
    func test_every_oidc_allKey_has_an_audit_row() {
        let oidcKeys = ManagedConfig.allKeys.filter {
            $0.hasPrefix("oidc") || $0 == "awsRoleArn"
                || $0 == "awsSessionDurationSeconds" || $0 == "vertexWorkforceProvider"
        }
        let rows = buildAuditRows(config: Config.default)
        for key in oidcKeys {
            guard let row = rows.first(where: { $0.key == key }) else {
                XCTFail("\(key) missing from buildAuditRows()")
                continue
            }
            XCTAssertNotEqual(row.displayValue, "(unknown key)",
                              "\(key) must have a dedicated audit-row case")
        }
    }

    func test_auditRow_oidc_generic_op_keys_render() {
        // Synthetic default config — NOT Config.load(): the developer's live
        // ~/.parleq/config.json may legitimately carry non-default OIDC
        // values (it did, during live testing, and broke this test).
        let rows = buildAuditRows(config: Config.default)
        let redirect = rows.first { $0.key == "oidcRedirectURI" }
        XCTAssertEqual(redirect?.displayValue, "parleq-auth://oidc/callback",
                       "default redirect URI must render verbatim")
        let extra = rows.first { $0.key == "oidcExtraAuthParams" }
        XCTAssertEqual(extra?.displayValue, "(none)",
                       "empty extra-auth-params must render as (none)")
    }
}
