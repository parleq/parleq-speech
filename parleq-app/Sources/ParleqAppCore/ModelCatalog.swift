// ModelCatalog — canonical model lists for every supported provider.
//
// These lists mirror the curated picker entries in SettingsWindow.swift.
// Two consumers:
//   1. SettingsView reads the value lists to populate pickers
//      (SettingsWindow keeps its own (value, label) tuples for the
//      human-readable labels; the values come from here).
//   2. Config.load() queries isCanonical / defaultModel to enforce
//      defense-in-depth when customModelEntryEnabled is false.
//
// When you add or retire a model in SettingsWindow, update this
// catalog in the same commit so the validation in Config.load()
// stays consistent with what the picker offers.

public enum ModelCatalog {

    // MARK: - Per-provider model value lists

    public static let geminiModels: [String] = [
        "gemini-3.5-flash-lite",
        "gemini-3.8-flash",
        "gemini-4-argon",
    ]

    /// Vertex Gemini 3.x / 4 models are served ONLY from the `global`
    /// location (every regional endpoint 404s as of 2026-11), so the
    /// Vertex default region is "global" and `VertexProvider` maps it to
    /// the un-prefixed `aiplatform.googleapis.com` host. Claude Haiku 5.5
    /// is likewise global-only on Vertex (Sonnet 5.5 is also in us-east5).
    public static let vertexModels: [String] = [
        "gemini-3.5-flash-lite",
        "gemini-3.8-flash",
        "gemini-4-argon",
        "claude-haiku-5-5",
        "claude-sonnet-5-5",
    ]

    public static let bedrockModels: [String] = [
        "openai.gpt-oss-120b-1:0",
        "us.anthropic.claude-haiku-5-5",
        "us.anthropic.claude-sonnet-5-5",
        "us.amazon.nova-pro-v1:0",
        "us.amazon.nova-lite-v1:0",
        "us.amazon.nova-micro-v1:0",
        "us.meta.llama3-3-70b-instruct-v1:0",
    ]

    public static let bedrockBearerModels: [String] = [
        "openai.gpt-oss-120b-1:0",
        "us.anthropic.claude-haiku-5-5",
        "us.anthropic.claude-sonnet-5-5",
        "us.amazon.nova-pro-v1:0",
        "us.amazon.nova-lite-v1:0",
        "us.amazon.nova-micro-v1:0",
        "us.meta.llama3-3-70b-instruct-v1:0",
    ]

    /// Azure routes by DEPLOYMENT name; this label only selects the
    /// request shape (reasoning vs standard), vision capability, and the
    /// pricing row. The gpt-4o / gpt-4.1 labels stay while Azure keeps
    /// serving those deployments (retirement 2027-04-14; gpt-4.1-nano's
    /// Azure date is unpublished, so it stays too — dropping a live label
    /// would let the customModelEntryEnabled=false scrub flip it to
    /// gpt-6-luna and send that standard deployment reasoning params).
    /// The o-series labels were dropped (Azure retirement 2026-11-19; a
    /// scrub to gpt-6-luna keeps the same reasoning request shape).
    public static let azureModels: [String] = [
        "gpt-6-luna",
        "gpt-6.1-terra",
        "gpt-6.1-sol",
        "gpt-4o-mini",
        "gpt-4o",
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4.1-nano",
    ]

    public static let openAIModels: [String] = [
        "gpt-6-luna",
        "gpt-6.1-terra",
        "gpt-6.1-sol",
    ]

    // MARK: - Retired-model migration

    /// Retired (or shutting-down) model IDs → their replacement, keyed by
    /// provider. Applied at config load (`Config.migrateRetiredModels`) so
    /// a config written by an older build keeps working instead of
    /// failing every cleanup call once the vendor shuts the old ID off.
    ///
    /// Sources (checked 2026-11-16): Gemini API deprecations page
    /// (2.5 Flash/Pro shut down 2026-12-01; access already limited to
    /// prior users), Vertex model-versions page (2.5 family retired
    /// 2026-10-20), Anthropic deprecations (Sonnet 4.5 retires
    /// 2026-11-30), OpenAI deprecations (o1/o3-mini/o4-mini/gpt-4.1-nano
    /// shut down 2026-10-23, o3 2026-12-11, gpt-4o/4.1 family 2027-01-14;
    /// OpenAI names gpt-6-luna as the 4o/4.1 replacement).
    ///
    /// Azure is deliberately absent: its model field is only a label for
    /// the user's own deployment, so rewriting it would misdescribe what
    /// is actually deployed.
    public static let retiredModelReplacements: [String: [String: String]] = {
        let gemini: [String: String] = [
            "gemini-2.5-flash":      "gemini-3.5-flash-lite",  // Google's own auto-route target
            "gemini-2.5-flash-lite": "gemini-3.5-flash-lite",
            "gemini-2.5-pro":        "gemini-4-argon",
        ]
        let bedrock: [String: String] = [
            "us.anthropic.claude-haiku-4-5-20251001-v1:0":  "us.anthropic.claude-haiku-5-5",
            "us.anthropic.claude-sonnet-4-5-20250929-v1:0": "us.anthropic.claude-sonnet-5-5",
        ]
        var vertex = gemini
        vertex["claude-haiku-4-5@20251001"]  = "claude-haiku-5-5"
        vertex["claude-sonnet-4-5@20250929"] = "claude-sonnet-5-5"
        return [
            "gemini": gemini,
            "vertex": vertex,
            "bedrock": bedrock,
            "bedrock-bearer": bedrock,
            "openai": [
                "gpt-4o-mini":  "gpt-6-luna",
                "gpt-4o":       "gpt-6-luna",
                "gpt-4.1":      "gpt-6-luna",
                "gpt-4.1-mini": "gpt-6-luna",
                "gpt-4.1-nano": "gpt-6-luna",
                "o1":           "gpt-6.1-sol",
                "o1-mini":      "gpt-6.1-sol",
                "o3":           "gpt-6.1-sol",
                "o3-mini":      "gpt-6.1-sol",
                "o4-mini":      "gpt-6.1-terra",
            ],
        ]
    }()

    /// An MDM model allowlist as it applies to `provider`: each entry
    /// `provider` has retired gets its successor inserted right after it
    /// (originals kept, order preserved, deduped).
    ///
    /// Provider-scoped on purpose: allowlists are flat cross-provider ID
    /// lists, and the same ID can be retired on one provider but live on
    /// another (OpenAI retired gpt-4o-mini / gpt-4.1-nano; they are still
    /// live Azure deployment labels). Expanding with another provider's
    /// table would offer an Azure user gpt-6-luna for a standard
    /// deployment. Without any expansion, a policy naming gemini-2.5-flash
    /// would migrate the effective model while the picker offered only the
    /// retired ID (blank selection).
    public static func expandingRetiredModels(_ allowlist: [String], forProvider provider: String) -> [String] {
        let table = retiredModelReplacements[provider] ?? [:]
        var out: [String] = []
        var seen = Set<String>()
        func add(_ id: String) { if seen.insert(id).inserted { out.append(id) } }
        for id in allowlist {
            add(id)
            if let next = table[id] { add(next) }
        }
        return out
    }

    /// True when `model` is a model `provider` offers now OR has retired.
    /// Use for "does this ID belong to that provider?" ownership checks
    /// (cross-provider allowlist filtering, pinned-provider mismatch):
    /// a retired ID must still count as its provider's, or an allowlist
    /// naming gemini-2.5-flash would read as a bare custom ID on OpenAI.
    ///
    /// Azure is special: its model field is a free label for the user's
    /// own deployment and uses OpenAI's model names, so every OpenAI-family
    /// ID (current or retired, e.g. an "o4-mini" deployment) is a valid
    /// Azure label. Azure therefore owns OpenAI's IDs too, so an Azure
    /// allowlist of ["o4-mini"] is not filtered out as "OpenAI's model".
    public static func ownsModel(provider: String, model: String) -> Bool {
        if isCanonical(provider: provider, model: model)
            || replacementForRetiredModel(provider: provider, model: model) != nil {
            return true
        }
        return provider == "azure" && ownsModel(provider: "openai", model: model)
    }

    /// The replacement for `model` under `provider` when it has been
    /// retired, else nil. Exact-ID match only — dated snapshots or other
    /// custom IDs the user typed are left alone.
    public static func replacementForRetiredModel(provider: String, model: String) -> String? {
        retiredModelReplacements[provider]?[model]
    }

    // MARK: - Lookups

    /// Returns the curated model list for the given provider string.
    /// Matches the provider IDs in Config.llmProvider / ModelIdentifier.provider.
    public static func models(forProvider provider: String) -> [String] {
        switch provider {
        case "gemini":         return geminiModels
        case "vertex":         return vertexModels
        case "bedrock":        return bedrockModels
        case "bedrock-bearer": return bedrockBearerModels
        case "azure":          return azureModels
        case "openai":         return openAIModels
        default:               return []
        }
    }

    /// Returns true when `model` is in the curated list for `provider`.
    /// An empty provider (unknown) returns false — caller decides how
    /// to handle that; Config.load() treats unknown provider as
    /// non-canonical and resets to default.
    public static func isCanonical(provider: String, model: String) -> Bool {
        models(forProvider: provider).contains(model)
    }

    /// Returns the curated default model for `provider`. Matches the
    /// mapping used in SetupWizard.swift (cleanupModelIdentifier) and
    /// Config.default (gemini-3.5-flash-lite for the Gemini path).
    ///
    /// Providers whose curated list is non-empty use the first entry as
    /// the default; unknown providers fall back to `fallbackDefaultModel`
    /// so a misconfigured provider doesn't leave the model blank.
    public static func defaultModel(forProvider provider: String) -> String {
        let list = models(forProvider: provider)
        return list.first ?? fallbackDefaultModel
    }

    // MARK: - Model-family helpers

    /// The major version of a `gemini-<major>…` model ID (e.g. 3 for
    /// "gemini-3.5-flash-lite", 4 for "gemini-4-argon"); nil for anything
    /// else, including aliases like "gemini-flash-latest".
    public static func geminiMajorVersion(_ model: String) -> Int? {
        let m = model.lowercased()
        guard m.hasPrefix("gemini-") else { return nil }
        let digits = m.dropFirst("gemini-".count).prefix { $0.isNumber }
        return Int(digits)
    }

    /// Gemini 3+ models take `thinkingLevel` (a 2.5-style `thinkingBudget`
    /// is rejected by some of them, e.g. gemini-4-argon on Vertex).
    public static func usesGeminiThinkingLevel(_ model: String) -> Bool {
        (geminiMajorVersion(model) ?? 0) >= 3
    }

    /// Vertex serves Gemini 3+ only from the `global` location.
    public static func isVertexGlobalOnlyGeminiModel(_ model: String) -> Bool {
        usesGeminiThinkingLevel(model)
    }

    /// Claude models Vertex serves only from `global` (Haiku 5.5 404s in
    /// us-east5; Sonnet 5.5 is available there).
    public static func isVertexGlobalOnlyClaudeModel(_ model: String) -> Bool {
        model.lowercased().hasPrefix("claude-haiku-5-5")
    }

    /// Gemini image-input capability — explicit allowlist (unknown IDs
    /// are treated as text-only). All three Gemini 3+ picks accepted an
    /// inline PNG in testing (2026-11); 2.5 Flash-Lite is text-only.
    public static func geminiSupportsVision(_ model: String) -> Bool {
        switch model.lowercased() {
        case "gemini-2.5-flash", "gemini-2.5-pro",
             "gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-4-argon":
            return true
        default:
            return false
        }
    }

    /// The default cleanup model when nothing else applies.
    public static let fallbackDefaultModel = "gemini-3.5-flash-lite"
}
