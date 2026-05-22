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
        "gemini-2.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-2.5-pro",
    ]

    public static let vertexModels: [String] = [
        "gemini-2.5-flash-lite",
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "claude-haiku-4-5@20251001",
        "claude-sonnet-4-5@20250929",
    ]

    public static let bedrockModels: [String] = [
        "openai.gpt-oss-120b-1:0",
        "us.anthropic.claude-haiku-4-5-20251001-v1:0",
        "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
        "us.amazon.nova-pro-v1:0",
        "us.amazon.nova-lite-v1:0",
        "us.amazon.nova-micro-v1:0",
        "us.meta.llama3-3-70b-instruct-v1:0",
    ]

    public static let bedrockBearerModels: [String] = [
        "openai.gpt-oss-120b-1:0",
        "us.anthropic.claude-haiku-4-5-20251001-v1:0",
        "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
        "us.amazon.nova-pro-v1:0",
        "us.amazon.nova-lite-v1:0",
        "us.amazon.nova-micro-v1:0",
        "us.meta.llama3-3-70b-instruct-v1:0",
    ]

    public static let azureModels: [String] = [
        "gpt-4o-mini",
        "gpt-4o",
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4.1-nano",
        "o1",
        "o1-mini",
        "o3",
        "o3-mini",
        "o4-mini",
    ]

    public static let openAIModels: [String] = [
        "gpt-4o-mini",
        "gpt-4o",
        "gpt-4.1",
        "gpt-4.1-mini",
        "gpt-4.1-nano",
        "o1",
        "o1-mini",
        "o3",
        "o3-mini",
        "o4-mini",
    ]

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
    /// Config.default (gemini-2.5-flash for the Gemini path).
    ///
    /// Providers whose curated list is non-empty use the first entry as
    /// the default; unknown providers fall back to "gemini-2.5-flash"
    /// so a misconfigured provider doesn't leave the model blank.
    public static func defaultModel(forProvider provider: String) -> String {
        let list = models(forProvider: provider)
        return list.first ?? "gemini-2.5-flash"
    }
}
