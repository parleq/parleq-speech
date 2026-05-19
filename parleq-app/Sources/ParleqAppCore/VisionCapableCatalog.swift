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
            return [
                ModelIdentifier(provider: "azure", model: "gpt-4o"),
                ModelIdentifier(provider: "azure", model: "gpt-4o-mini"),
                ModelIdentifier(provider: "azure", model: "gpt-4.1"),
                ModelIdentifier(provider: "azure", model: "gpt-4.1-mini"),
            ]
        default:
            return []
        }
    }
}
