// VisionCapableCatalog — curated list of vision-capable models the
// Setup Wizard's AdvancedModelStep offers per-provider.
//
// The Settings Models tab uses the per-provider model-options lists
// (geminiModelOptions, bedrockModelOptions, etc.) directly rather
// than calling here, since Settings exposes both cleanup-tier and
// context-tier model options. The catalog stays focused on the
// wizard, where vision-capability filtering is meaningful (the
// AdvancedModel step is specifically about routing reference-aware
// turns to a vision-capable model).

import Foundation

enum VisionCapableCatalog {
    /// Vision-capable models that share auth with `provider`. Empty
    /// for providers without a vision-capable variant.
    ///
    /// Model IDs match the strings accepted by each concrete provider:
    ///   - Gemini/Vertex: bare model name passed to the API URL.
    ///     Vertex also includes Claude IDs in the `<base>@<version>`
    ///     format (e.g. `claude-sonnet-4-5@20250929`) — routed via
    ///     the Anthropic publisher using `vertexAnthropicRegion`.
    ///   - Bedrock/Bedrock-bearer: cross-region inference profile IDs
    ///     (`us.anthropic.*`) — the same format used in
    ///     SettingsWindow.bedrockModelOptions.
    ///   - Azure: model IDs whose `contains("gpt-4o")` check in
    ///     `AzureOpenAIProvider.supportsVision` returns true.
    static func visionModels(forProvider provider: String) -> [ModelIdentifier] {
        switch provider.lowercased() {
        case "gemini":
            return [
                ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash"),
                ModelIdentifier(provider: "gemini", model: "gemini-2.5-pro"),
            ]
        case "vertex":
            return [
                ModelIdentifier(provider: "vertex", model: "gemini-2.5-flash"),
                ModelIdentifier(provider: "vertex", model: "gemini-2.5-pro"),
                ModelIdentifier(provider: "vertex", model: "claude-haiku-4-5@20251001"),
                ModelIdentifier(provider: "vertex", model: "claude-sonnet-4-5@20250929"),
            ]
        case "bedrock":
            return [
                ModelIdentifier(provider: "bedrock", model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
                ModelIdentifier(provider: "bedrock", model: "us.anthropic.claude-haiku-4-5-20251001-v1:0"),
            ]
        case "bedrock-bearer":
            return [
                ModelIdentifier(provider: "bedrock-bearer", model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
                ModelIdentifier(provider: "bedrock-bearer", model: "us.anthropic.claude-haiku-4-5-20251001-v1:0"),
            ]
        case "azure":
            // Standard GPT families + vision-capable o-series reasoning models.
            // o1-mini and o3-mini are text-only and excluded.
            return [
                ModelIdentifier(provider: "azure", model: "gpt-4o"),
                ModelIdentifier(provider: "azure", model: "gpt-4o-mini"),
                ModelIdentifier(provider: "azure", model: "gpt-4.1"),
                ModelIdentifier(provider: "azure", model: "gpt-4.1-mini"),
                ModelIdentifier(provider: "azure", model: "o1"),
                ModelIdentifier(provider: "azure", model: "o3"),
                ModelIdentifier(provider: "azure", model: "o4-mini"),
            ]
        case "openai":
            // OpenAI direct (api.openai.com). gpt-4.1-nano is text-only.
            // Vision-capable o-series reasoning models (o1, o3, o4-mini)
            // added; o1-mini and o3-mini are text-only and excluded.
            return [
                ModelIdentifier(provider: "openai", model: "gpt-4o"),
                ModelIdentifier(provider: "openai", model: "gpt-4o-mini"),
                ModelIdentifier(provider: "openai", model: "gpt-4.1"),
                ModelIdentifier(provider: "openai", model: "gpt-4.1-mini"),
                ModelIdentifier(provider: "openai", model: "o1"),
                ModelIdentifier(provider: "openai", model: "o3"),
                ModelIdentifier(provider: "openai", model: "o4-mini"),
            ]
        default:
            return []
        }
    }
}
