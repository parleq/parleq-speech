// ProviderRegistry — credential presence checks used by the
// Settings Context-model picker to decide which providers to
// include when building the cross-provider model list.
//
// Each `isConfigured(_:)` check is intentionally lightweight:
// it only asks "does the relevant Keychain item exist?" without
// materialising the secret value. The same pattern is already
// used by SettingsWindowModel's @Published mirrors (e.g.
// `awsStaticCredentialsSet`, `geminiKeyIsSet`) — this enum
// gives the same answer from a call-site that doesn't hold a
// SettingsWindowModel instance (e.g. a computed var on an
// @Observable view or a SwiftUI struct).
//
// Provider strings match the values stored in Config.llmProvider /
// ModelIdentifier.provider — lowercase, no spaces.

import Foundation

enum ProviderRegistry {
    /// Returns true iff the provider's required credentials exist in
    /// the Keychain. Used by the Settings Models tab to mark a
    /// provider as "(not configured)" in the per-tier provider
    /// dropdowns, enabling cross-provider cleanup+context
    /// configurations (e.g. Gemini Flash cleanup + Sonnet/Bedrock
    /// context) once both providers have credentials.
    ///
    /// - "bedrock"        → IAM static key-pair (access-key-id + secret)
    /// - "bedrock-bearer" → Bedrock API key (single opaque token)
    /// - "gemini"         → Gemini direct API key
    /// - "vertex"         → Vertex AI service-account JSON
    /// - "azure"          → Azure OpenAI resource API key
    /// - "openai"         → OpenAI direct API key (api.openai.com)
    ///
    /// Note: SSO-auth Bedrock ("sso" mode) and ADC-auth Vertex ("adc"
    /// mode) authenticate via the ambient AWS / gcloud CLI session —
    /// there is no Keychain item to check. We treat them as "configured"
    /// by checking if the provider's Keychain credential is present; for
    /// SSO/ADC the check returns false here (no static cred), so those
    /// providers' models won't appear in the cross-provider picker unless
    /// the user has also stored static credentials. This is intentionally
    /// conservative: SSO sessions expire, and surfacing models from a
    /// session-authed provider that may have lapsed would cause confusing
    /// runtime failures.
    static func isConfigured(_ provider: String) -> Bool {
        switch provider.lowercased() {
        case "gemini":
            return KeychainStore.hasGeminiAPIKey
        case "vertex":
            return KeychainStore.hasVertexServiceAccountJSON
        case "bedrock":
            return KeychainStore.hasAWSStaticCredentials
        case "bedrock-bearer":
            return KeychainStore.hasBedrockAPIKey
        case "azure":
            return KeychainStore.hasAzureAPIKey
        case "openai":
            return KeychainStore.hasOpenAIAPIKey
        case "local":
            // "configured" ≡ the model weights are downloaded and ready.
            // Uses a nonisolated file-stat helper so this sync, non-isolated
            // function can call it without a MainActor hop.
            return LocalModelStore.isReadyOnDisk()
        default:
            return false
        }
    }
}
