// SettingsWindow — preferences UI for the per-user knobs in
// ~/.parleq/config.json.
//
// This is an NSWindow + NSHostingController hosting a SwiftUI Form
// rather than the macOS-13 `Settings { }` Scene API, because Parleq
// runs on top of NSApplication directly (signal handlers, status
// item, hotkey listener, custom overlay panel) — switching to the
// SwiftUI App lifecycle would mean rebuilding all that wiring. A
// hand-rolled Settings window gets us the same look and behavior
// without that disruption.
//
// Behavior:
//   - Auto-save: every binding writes through to disk on change. The
//     JSON file is tiny so the cost is negligible, and "explicit save
//     button" is a poor fit for toggles.
//   - "Restart required" hint appears at the bottom whenever a setting
//     is changed that we read once at launch (currently just the
//     hotkey binding; LLM/audio config are also restart-only in
//     practice, so we annotate those settings inline).
//   - Hotkey is rendered as a Picker over the bindings HotkeyBinding
//     understands; that's the only safe surface — anything else would
//     write a string to disk that the parser later rejects.
//
// LSUIElement note: this app has no Dock icon (LSUIElement=true), so
// NSApp.activate(ignoringOtherApps:) won't bring up a Dock icon. The
// settings window opens, takes focus, and the rest of the app stays
// in the menu bar.

import AppKit
import SwiftUI

/// One editable row in the Custom Dictionary table. The `id` is a
/// transient UUID used by SwiftUI's ForEach for stable identity; we
/// regenerate it from disk on every load, so it never gets persisted.
/// Empty `context` maps to `DictionaryEntry.context = nil` on save.
/// `aliases` is edited as a single comma-separated string for UI
/// simplicity; we split/trim on save into the on-disk array form.
struct DictionaryEntryRow: Identifiable, Equatable {
    let id: UUID
    var term: String
    var context: String
    var aliases: String
    var biasing: DictionaryBiasing

    init(
        id: UUID = UUID(),
        term: String = "",
        context: String = "",
        aliases: String = "",
        biasing: DictionaryBiasing = .asrAndLLM
    ) {
        self.id = id
        self.term = term
        self.context = context
        self.aliases = aliases
        self.biasing = biasing
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var hotkeyBinding: String
    @Published var autoAcceptSeconds: Double
    @Published var acousticFeedback: Bool
    @Published var continueOtherAudio: Bool
    /// Explicit microphone selection by Core Audio device UID. Empty
    /// string means "System Default + auto-route heuristic" (the
    /// pre-#25 behavior driven by `continueOtherAudio`). Mirrors
    /// `Config.audioInputDeviceUID`. Settings picks this both via
    /// the menu-bar Microphone submenu and via Settings → Audio.
    @Published var audioInputDeviceUID: String
    @Published var trailingSpace: Bool
    /// Editable as comma-separated text in the UI; we split/trim on
    /// save and the parser is lenient about whitespace either way.
    @Published var noTrailingSpaceAppsText: String
    @Published var llmModel: String
    /// "gemini" or "bedrock". Drives which LLMProvider is
    /// instantiated at app launch. Restart required.
    @Published var llmProvider: String
    /// AWS region for Bedrock; ignored when provider is gemini.
    @Published var awsRegion: String
    /// AWS profile name from `~/.aws/config` (empty = default
    /// profile). Passed to Soto for credential resolution against
    /// the user's existing AWS CLI session.
    @Published var awsProfile: String
    /// Bedrock auth mode (#21 step 3): "sso" uses the AWS CLI
    /// session, "static" uses Keychain-stored access keys.
    @Published var awsAuthMode: String
    /// Mirror of `KeychainStore.hasAWSStaticCredentials` for SwiftUI.
    /// Updated when the user sets or removes credentials via the
    /// Set AWS Credentials sheet.
    @Published var awsStaticCredentialsSet: Bool
    /// Mirror of `KeychainStore.hasBedrockAPIKey` for SwiftUI (#22).
    @Published var bedrockAPIKeySet: Bool
    /// Google Cloud project ID for Vertex AI (#21 step 4).
    @Published var vertexProject: String
    /// Vertex AI region, e.g. "us-central1".
    @Published var vertexRegion: String
    /// Vertex AI auth mode (#23): "adc" or "serviceAccount".
    @Published var vertexAuthMode: String
    /// Region used for Anthropic publisher calls on Vertex AI (Claude
    /// models). Separate from `vertexRegion` so users can keep Gemini
    /// in us-central1 while routing Claude through us-east5. Defaults
    /// to "us-east5".
    @Published var vertexAnthropicRegion: String
    /// Mirror of `KeychainStore.hasVertexServiceAccountJSON` for SwiftUI.
    @Published var vertexServiceAccountJSONSet: Bool
    /// Azure OpenAI resource name (#21 step 5).
    @Published var azureResource: String
    /// Azure OpenAI deployment name.
    @Published var azureDeployment: String
    /// Azure OpenAI API version.
    @Published var azureApiVersion: String
    /// Azure auth mode (#21 step 5 follow-up): "apiKey" or "azureAd".
    @Published var azureAuthMode: String
    /// Mirror of `KeychainStore.hasAzureAPIKey` for SwiftUI.
    @Published var azureAPIKeySet: Bool
    /// Mirror of `KeychainStore.hasOpenAIAPIKey` for SwiftUI.
    @Published var openAIAPIKeySet: Bool
    @Published var asrEndpoint: String
    /// Editable rows for the Custom Dictionary section. Each row is
    /// term + context fields; we strip empty terms on save and map
    /// empty context to nil. Identifiable IDs are UI-side only — they
    /// don't get persisted to disk, so they can be regenerated freely
    /// on each load.
    @Published var dictionaryEntries: [DictionaryEntryRow]

    /// Context model for reference-aware dictations. When nil,
    /// inherits from the cleanup model. Users can pick "Same as cleanup"
    /// or a specific configured model. Mirrors Config.contextModel.
    @Published var contextModel: ModelIdentifier?

    // MARK: - Feature toggle mirrors (Phase 5)

    /// Mirror of Config.referenceWindowsEnabled.
    @Published var referenceWindowsEnabled: Bool
    /// Mirror of Config.clipboardReferenceEnabled.
    @Published var clipboardReferenceEnabled: Bool
    /// Mirror of Config.imageReferenceEnabled.
    @Published var imageReferenceEnabled: Bool
    /// Mirror of Config.fileReferenceEnabled.
    @Published var fileReferenceEnabled: Bool
    /// Mirror of Config.customDictionaryEnabled.
    @Published var customDictionaryEnabled: Bool
    /// Mirror of Config.customModelEntryEnabled.
    @Published var customModelEntryEnabled: Bool
    /// Mirror of Config.transcriptHistoryMaxEntries. 0.14.0 PR 6
    /// (#221). nil = unlimited; 0 = disable history entirely.
    /// PrivacyFeaturesView binds this through an optionalIntBinding
    /// that round-trips empty TextField ↔ nil.
    @Published var transcriptHistoryMaxEntries: Int?
    /// Mirror of Config.transcriptHistoryRetentionHours. 0.14.0
    /// PR 6 (#221). nil = unlimited; 0 = disable history entirely.
    @Published var transcriptHistoryRetentionHours: Int?
    /// Set of Config keys currently managed by MDM. Rows for managed
    /// keys render as `.disabled(true)` with the ManagedIndicator badge.
    @Published var managedKeys: Set<String>

    /// Callback wired by `parleq-app/main.swift` to the bundled
    /// LocalASRClient's `reset()` method. Settings → Advanced
    /// exposes this as a "Reset speech model" button; the same
    /// closure was previously bound to the menu bar's "Reset ASR"
    /// item, removed in 0.13.0 as part of the menu-bar declutter.
    /// Nil-checked at call site so a non-bundled-ASR launch (custom
    /// asr.endpoint) leaves the button as a no-op rather than
    /// crashing — main.swift only sets this when LocalASRClient is
    /// actually in play.
    var onResetASR: (() -> Void)?

    // MARK: - Tier fields (cleanup + context independent provider+model)

    /// Cleanup tier: the provider used for normal dictation cleanup.
    /// Mirrors `config.llmProvider`. The Models tab's Cleanup row
    /// binds this directly; save() flushes it back to Config.
    @Published var cleanupProvider: String
    /// Cleanup tier model name. Mirrors `config.llmModel`.
    @Published var cleanupModelName: String
    /// Context tier provider. Defaults to the cleanup provider when
    /// `config.contextModel` is nil.
    @Published var contextProvider: String
    /// Context tier model name. Defaults to the cleanup model when
    /// `config.contextModel` is nil.
    @Published var contextModelName: String

    // MARK: - Provider option catalog

    struct ProviderOption: Identifiable {
        let id: String           // "gemini", "vertex", etc.
        let displayName: String  // shown in the tier provider picker
    }

    static let providerOptions: [ProviderOption] = [
        ProviderOption(id: "gemini",         displayName: "Gemini (Google API)"),
        ProviderOption(id: "vertex",         displayName: "Gemini (Vertex / Google Cloud)"),
        ProviderOption(id: "bedrock",        displayName: "Bedrock (AWS IAM)"),
        ProviderOption(id: "bedrock-bearer", displayName: "Bedrock (bearer token)"),
        ProviderOption(id: "azure",          displayName: "Azure OpenAI"),
        ProviderOption(id: "openai",         displayName: "OpenAI (direct API)"),
    ]

    /// Mirror of `KeychainStore.hasGeminiAPIKey` for SwiftUI.
    /// Updated when the user sets or removes the key via the Set
    /// Gemini API Key sheet.
    @Published var geminiKeyIsSet: Bool

    /// Snapshot of the usage ledger. Refreshed when the Settings
    /// window appears; we don't auto-refresh on every LLM call
    /// because the ledger is only interesting when the user opens
    /// this window. The user can also tap a "Refresh" button to
    /// re-read mid-session if dictating with the window open.
    @Published var usage: UsageAggregate = .empty

    /// Captured at init so we can detect "this setting needs a
    /// restart to apply" and surface the hint banner.
    private let initialHotkeyBinding: String
    private let initialLlmModel: String
    private let initialContinueOtherAudio: Bool
    private let initialAsrEndpoint: String
    private let initialLlmProvider: String
    private let initialAwsRegion: String
    private let initialAwsProfile: String
    private let initialAwsAuthMode: String
    private let initialVertexProject: String
    private let initialVertexRegion: String
    private let initialVertexAuthMode: String
    private let initialVertexAnthropicRegion: String
    private let initialAzureResource: String
    private let initialAzureDeployment: String
    private let initialAzureApiVersion: String
    private let initialAzureAuthMode: String
    private let initialContextModel: ModelIdentifier?

    init() {
        let (config, _) = Config.load()
        self.hotkeyBinding = config.hotkeyBinding
        self.autoAcceptSeconds = config.autoAcceptSeconds
        self.acousticFeedback = config.acousticFeedback
        self.continueOtherAudio = config.continueOtherAudio
        self.audioInputDeviceUID = config.audioInputDeviceUID
        self.trailingSpace = config.trailingSpace
        self.noTrailingSpaceAppsText = config.noTrailingSpaceAppBundleIDs.joined(separator: ", ")
        self.llmModel = config.llmModel
        self.llmProvider = config.llmProvider
        self.awsRegion = config.awsRegion
        self.awsProfile = config.awsProfile ?? ""
        self.awsAuthMode = config.awsAuthMode
        self.awsStaticCredentialsSet = KeychainStore.hasAWSStaticCredentials
        self.bedrockAPIKeySet = KeychainStore.hasBedrockAPIKey
        self.vertexProject = config.vertexProject
        self.vertexRegion = config.vertexRegion
        self.vertexAuthMode = config.vertexAuthMode
        self.vertexAnthropicRegion = config.vertexAnthropicRegion
        self.vertexServiceAccountJSONSet = KeychainStore.hasVertexServiceAccountJSON
        self.azureResource = config.azureResource
        self.azureDeployment = config.azureDeployment
        self.azureApiVersion = config.azureApiVersion
        self.azureAuthMode = config.azureAuthMode
        self.azureAPIKeySet = KeychainStore.hasAzureAPIKey
        self.openAIAPIKeySet = KeychainStore.hasOpenAIAPIKey
        self.asrEndpoint = config.asrEndpoint
        self.dictionaryEntries = config.customDictionary.map { entry in
            DictionaryEntryRow(
                term: entry.term,
                context: entry.context ?? "",
                aliases: entry.aliases.joined(separator: ", "),
                biasing: entry.biasing
            )
        }
        self.geminiKeyIsSet = KeychainStore.hasGeminiAPIKey
        self.contextModel = config.contextModel
        // Tier fields — derived from the flat config fields.
        self.cleanupProvider = config.llmProvider
        self.cleanupModelName = config.llmModel
        self.contextProvider = config.contextModel?.provider ?? config.llmProvider
        self.contextModelName = config.contextModel?.model ?? config.llmModel
        // Feature toggles (Phase 5).
        self.referenceWindowsEnabled = config.referenceWindowsEnabled
        self.clipboardReferenceEnabled = config.clipboardReferenceEnabled
        self.imageReferenceEnabled = config.imageReferenceEnabled
        self.fileReferenceEnabled = config.fileReferenceEnabled
        self.customDictionaryEnabled = config.customDictionaryEnabled
        self.customModelEntryEnabled = config.customModelEntryEnabled
        self.transcriptHistoryMaxEntries = config.transcriptHistoryMaxEntries
        self.transcriptHistoryRetentionHours = config.transcriptHistoryRetentionHours
        self.managedKeys = config.managedKeys
        self.initialHotkeyBinding = config.hotkeyBinding
        self.initialLlmModel = config.llmModel
        self.initialContinueOtherAudio = config.continueOtherAudio
        self.initialAsrEndpoint = config.asrEndpoint
        self.initialLlmProvider = config.llmProvider
        self.initialAwsRegion = config.awsRegion
        self.initialAwsProfile = config.awsProfile ?? ""
        self.initialAwsAuthMode = config.awsAuthMode
        self.initialVertexProject = config.vertexProject
        self.initialVertexRegion = config.vertexRegion
        self.initialVertexAuthMode = config.vertexAuthMode
        self.initialVertexAnthropicRegion = config.vertexAnthropicRegion
        self.initialAzureResource = config.azureResource
        self.initialAzureDeployment = config.azureDeployment
        self.initialAzureApiVersion = config.azureApiVersion
        self.initialAzureAuthMode = config.azureAuthMode
        self.initialContextModel = config.contextModel
        refreshUsage()
    }

    /// Re-read the usage ledger from disk and update the Usage
    /// section. Called automatically on init and via the "Refresh"
    /// button in the Usage section.
    func refreshUsage() {
        usage = UsageLedger.shared.aggregate()
    }

    /// Re-read the entire config + Keychain mirror state from disk.
    /// Called from `ParleqAppView` when the user navigates INTO the
    /// Settings sidebar section, so the form always reflects current
    /// disk state — handles the case where the wizard (or a manual
    /// config-file edit, or any other path) mutated the config while
    /// Settings was hidden but this model instance was kept around.
    ///
    /// Initial-state constants (initialHotkeyBinding et al) are
    /// intentionally NOT touched. They capture the launch-time
    /// state that the running app's pipeline is using; the
    /// restart-required banner correctly fires when a property
    /// has drifted from those values, regardless of whether the
    /// drift came from this Settings window or from somewhere
    /// else.
    func reload() {
        let (config, _) = Config.load()
        self.hotkeyBinding = config.hotkeyBinding
        self.autoAcceptSeconds = config.autoAcceptSeconds
        self.acousticFeedback = config.acousticFeedback
        self.continueOtherAudio = config.continueOtherAudio
        self.audioInputDeviceUID = config.audioInputDeviceUID
        self.trailingSpace = config.trailingSpace
        self.noTrailingSpaceAppsText = config.noTrailingSpaceAppBundleIDs.joined(separator: ", ")
        self.llmModel = config.llmModel
        self.llmProvider = config.llmProvider
        self.awsRegion = config.awsRegion
        self.awsProfile = config.awsProfile ?? ""
        self.awsAuthMode = config.awsAuthMode
        self.awsStaticCredentialsSet = KeychainStore.hasAWSStaticCredentials
        self.bedrockAPIKeySet = KeychainStore.hasBedrockAPIKey
        self.vertexProject = config.vertexProject
        self.vertexRegion = config.vertexRegion
        self.vertexAuthMode = config.vertexAuthMode
        self.vertexAnthropicRegion = config.vertexAnthropicRegion
        self.vertexServiceAccountJSONSet = KeychainStore.hasVertexServiceAccountJSON
        self.azureResource = config.azureResource
        self.azureDeployment = config.azureDeployment
        self.azureApiVersion = config.azureApiVersion
        self.azureAuthMode = config.azureAuthMode
        self.azureAPIKeySet = KeychainStore.hasAzureAPIKey
        self.openAIAPIKeySet = KeychainStore.hasOpenAIAPIKey
        self.asrEndpoint = config.asrEndpoint
        self.dictionaryEntries = config.customDictionary.map { entry in
            DictionaryEntryRow(
                term: entry.term,
                context: entry.context ?? "",
                aliases: entry.aliases.joined(separator: ", "),
                biasing: entry.biasing
            )
        }
        self.geminiKeyIsSet = KeychainStore.hasGeminiAPIKey
        self.contextModel = config.contextModel
        // Re-derive tier fields from the reloaded config.
        self.cleanupProvider = config.llmProvider
        self.cleanupModelName = config.llmModel
        self.contextProvider = config.contextModel?.provider ?? config.llmProvider
        self.contextModelName = config.contextModel?.model ?? config.llmModel
        // Feature toggles (Phase 5).
        self.referenceWindowsEnabled = config.referenceWindowsEnabled
        self.clipboardReferenceEnabled = config.clipboardReferenceEnabled
        self.imageReferenceEnabled = config.imageReferenceEnabled
        self.fileReferenceEnabled = config.fileReferenceEnabled
        self.customDictionaryEnabled = config.customDictionaryEnabled
        self.customModelEntryEnabled = config.customModelEntryEnabled
        self.transcriptHistoryMaxEntries = config.transcriptHistoryMaxEntries
        self.transcriptHistoryRetentionHours = config.transcriptHistoryRetentionHours
        self.managedKeys = config.managedKeys
        refreshUsage()
    }

    /// Drop the ledger file and reset the in-memory snapshot so the
    /// Usage section shows zeros immediately. Wired to the "Clear
    /// History" button.
    func clearUsage() {
        UsageLedger.shared.clear()
        usage = .empty
    }

    /// True when at least one setting that's only read at startup has
    /// been changed. The form shows a "restart required" banner in
    /// this case.
    ///
    /// Context-model changes also gate restart: main.swift constructs
    /// contextLLM once at startup with the configured provider + model
    /// + auth baked in. AppState.llmForInvocation routes reference-
    /// aware turns to that pre-built instance, so a mid-session
    /// contextModel switch wouldn't take effect (it'd silently fall
    /// back to llm or hit the wrong baked-in model). The user gets
    /// the same restart prompt cleanup-tier changes already trigger.
    var requiresRestart: Bool {
        hotkeyBinding != initialHotkeyBinding
            || llmModel != initialLlmModel
            || continueOtherAudio != initialContinueOtherAudio
            || asrEndpoint != initialAsrEndpoint
            || llmProvider != initialLlmProvider
            || contextModel != initialContextModel
            || awsRegion != initialAwsRegion
            || awsProfile != initialAwsProfile
            || awsAuthMode != initialAwsAuthMode
            || vertexProject != initialVertexProject
            || vertexRegion != initialVertexRegion
            || vertexAuthMode != initialVertexAuthMode
            || vertexAnthropicRegion != initialVertexAnthropicRegion
            || azureResource != initialAzureResource
            || azureDeployment != initialAzureDeployment
            || azureApiVersion != initialAzureApiVersion
            || azureAuthMode != initialAzureAuthMode
    }

    /// Persist current model values to ~/.parleq/config.json. Other
    /// fields (asr/llm modes, telemetry) are passed through from the
    /// loaded config so we don't accidentally clobber them when the
    /// user opens Settings on a config that has manual additions.
    func save() {
        let (existing, _) = Config.load()
        var c = existing
        c.hotkeyBinding = hotkeyBinding
        c.autoAcceptSeconds = autoAcceptSeconds
        c.acousticFeedback = acousticFeedback
        c.continueOtherAudio = continueOtherAudio
        c.audioInputDeviceUID = audioInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        c.trailingSpace = trailingSpace
        c.noTrailingSpaceAppBundleIDs = Self.parseBundleIDs(noTrailingSpaceAppsText)
        // Persist tier fields — these are the canonical source of truth
        // for cleanup provider/model; llmModel/llmProvider stay in sync.
        c.llmProvider = cleanupProvider
        c.llmModel = cleanupModelName.trimmingCharacters(in: .whitespaces)
        // Keep the legacy mirrors in sync so other code paths that read
        // llmModel/llmProvider directly stay consistent.
        llmProvider = cleanupProvider
        llmModel = cleanupModelName
        c.awsRegion = awsRegion.trimmingCharacters(in: .whitespaces)
        if c.awsRegion.isEmpty { c.awsRegion = "us-east-2" }
        let trimmedProfile = awsProfile.trimmingCharacters(in: .whitespaces)
        c.awsProfile = trimmedProfile.isEmpty ? nil : trimmedProfile
        c.awsAuthMode = ["sso", "static", "bedrockApiKey"].contains(awsAuthMode) ? awsAuthMode : "sso"
        c.vertexProject = vertexProject.trimmingCharacters(in: .whitespacesAndNewlines)
        c.vertexRegion = vertexRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.vertexRegion.isEmpty { c.vertexRegion = "us-central1" }
        c.vertexAuthMode = ["adc", "serviceAccount"].contains(vertexAuthMode) ? vertexAuthMode : "adc"
        c.vertexAnthropicRegion = vertexAnthropicRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.vertexAnthropicRegion.isEmpty { c.vertexAnthropicRegion = "us-east5" }
        c.azureResource = azureResource.trimmingCharacters(in: .whitespacesAndNewlines)
        c.azureDeployment = azureDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
        c.azureApiVersion = azureApiVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.azureApiVersion.isEmpty { c.azureApiVersion = "2024-08-01-preview" }
        c.azureAuthMode = ["apiKey", "azureAd"].contains(azureAuthMode) ? azureAuthMode : "apiKey"
        c.asrEndpoint = asrEndpoint.trimmingCharacters(in: .whitespaces)
        if c.asrEndpoint.isEmpty { c.asrEndpoint = Config.bundledASREndpoint }
        c.customDictionary = dictionaryEntries.compactMap { row -> DictionaryEntry? in
            let term = row.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            let ctx = row.context.trimmingCharacters(in: .whitespacesAndNewlines)
            let aliases = row.aliases
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return DictionaryEntry(
                term: term,
                context: ctx.isEmpty ? nil : ctx,
                aliases: aliases,
                biasing: row.biasing
            )
        }
        // Context tier: nil when context == cleanup so the resolver
        // short-circuits cleanly (nil means "same as cleanup" in Config).
        let contextId = ModelIdentifier(provider: contextProvider, model: contextModelName.trimmingCharacters(in: .whitespaces))
        let cleanupId = ModelIdentifier(provider: cleanupProvider, model: cleanupModelName.trimmingCharacters(in: .whitespaces))
        let resolvedContextModel: ModelIdentifier? = (contextId == cleanupId) ? nil : contextId
        c.contextModel = resolvedContextModel
        contextModel = resolvedContextModel
        // Feature toggles (Phase 5). Managed keys are already excluded
        // inside Config.save() via c.managedKeys, so we just set the
        // user-facing values unconditionally here — Config.save skips
        // the ones in managedKeys.
        c.referenceWindowsEnabled = referenceWindowsEnabled
        c.clipboardReferenceEnabled = clipboardReferenceEnabled
        c.imageReferenceEnabled = imageReferenceEnabled
        c.fileReferenceEnabled = fileReferenceEnabled
        c.customDictionaryEnabled = customDictionaryEnabled
        c.customModelEntryEnabled = customModelEntryEnabled
        c.transcriptHistoryMaxEntries = transcriptHistoryMaxEntries
        c.transcriptHistoryRetentionHours = transcriptHistoryRetentionHours
        c.managedKeys = managedKeys
        do {
            try Config.save(c)
            // 0.14.0 PR 6 (#221): push the new retention limits
            // into TranscriptHistory immediately so a save in
            // Settings → Privacy & Features takes effect without
            // waiting for the next dictation or an app restart.
            TranscriptHistory.shared.applyRetentionLimits(from: c)
        } catch {
            let msg = "[parleq] settings: save failed: \(error)\n"
            FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
        }
        // Apply live the changes that don't need a restart.
        Sounds.enabled = acousticFeedback
    }

    private static func parseBundleIDs(_ text: String) -> [String] {
        text.split(whereSeparator: { ",\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Persist a new Gemini API key to the macOS Keychain. Called
    /// by the Set Gemini API Key sheet on commit; clears whatever
    /// the user typed from in-memory state right after writing.
    func setGeminiAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.setGeminiAPIKey(trimmed) {
            geminiKeyIsSet = true
        }
    }

    /// Delete the Keychain-stored Gemini key. Subsequent dictations
    /// fall back to env / legacy file resolution; if neither is
    /// set, LLM cleanup disables and the raw ASR transcript is
    /// pasted (existing behavior).
    func removeGeminiAPIKey() {
        if KeychainStore.removeGeminiAPIKey() {
            geminiKeyIsSet = false
        }
    }

    /// Persist AWS static credentials to the macOS Keychain
    /// (#21 step 3). Called by the Set AWS Credentials sheet on
    /// commit; clears whatever the user typed from in-memory state
    /// right after writing. Trims the access key id; the secret is
    /// trimmed only on outer whitespace (interior whitespace is
    /// preserved since AWS secrets are base64-ish opaque strings).
    func setAWSStaticCredentials(accessKeyId: String, secretAccessKey: String, sessionToken: String?) {
        let id = accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return }
        let creds = KeychainStore.AWSStaticCredentials(
            accessKeyId: id,
            secretAccessKey: secret,
            sessionToken: (token?.isEmpty ?? true) ? nil : token
        )
        if KeychainStore.setAWSStaticCredentials(creds) {
            awsStaticCredentialsSet = true
        }
    }

    /// Delete Keychain-stored AWS static credentials. The Bedrock
    /// provider's static-mode init throws missingCredentials on the
    /// next launch if the user is still in static-mode without
    /// keys, falling through to "no LLM cleanup" cleanly.
    func removeAWSStaticCredentials() {
        if KeychainStore.removeAWSStaticCredentials() {
            awsStaticCredentialsSet = false
        }
    }

    /// Persist a Bedrock API key (#22) to the Keychain.
    func setBedrockAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.setBedrockAPIKey(trimmed) {
            bedrockAPIKeySet = true
        }
    }

    /// Delete the Keychain-stored Bedrock API key.
    func removeBedrockAPIKey() {
        if KeychainStore.removeBedrockAPIKey() {
            bedrockAPIKeySet = false
        }
    }

    /// Persist the Azure OpenAI resource API key to the Keychain
    /// (#21 step 5). Same flow as setGeminiAPIKey: write through to
    /// Keychain, drop the in-memory string, mirror via the
    /// `azureAPIKeySet` published flag.
    func setAzureAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.setAzureAPIKey(trimmed) {
            azureAPIKeySet = true
        }
    }

    /// Delete the Keychain-stored Azure OpenAI key. The provider's
    /// per-request resolve throws `missingCredentials`, falling
    /// through to raw-ASR paste if the user removes the key without
    /// re-setting it.
    func removeAzureAPIKey() {
        if KeychainStore.removeAzureAPIKey() {
            azureAPIKeySet = false
        }
    }

    /// Persist the OpenAI direct API key to the Keychain (#33).
    /// Same flow as setGeminiAPIKey / setAzureAPIKey: write through
    /// to Keychain, drop the in-memory string, mirror via the
    /// `openAIAPIKeySet` published flag.
    func setOpenAIAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.setOpenAIAPIKey(trimmed) {
            openAIAPIKeySet = true
        }
    }

    /// Delete the Keychain-stored OpenAI API key. The provider's
    /// per-request resolve throws `missingCredentials`, falling
    /// through to raw-ASR paste if the user removes the key without
    /// re-setting it.
    func removeOpenAIAPIKey() {
        if KeychainStore.removeOpenAIAPIKey() {
            openAIAPIKeySet = false
        }
    }

    /// Persist a Vertex AI service-account JSON to the Keychain
    /// (#23). Validates the JSON shape before storing so a paste of
    /// the wrong file fails fast with a friendly error instead of
    /// at first-dictation time. Returns nil on success, an error
    /// message on validation failure (the caller — typically the
    /// Set Service Account JSON sheet — surfaces it inline).
    @discardableResult
    func setVertexServiceAccountJSON(_ json: String) -> String? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "JSON is empty." }
        do {
            // Parse to validate; we don't keep the result — the
            // provider re-parses on demand from the Keychain copy
            // each session.
            _ = try ServiceAccountKey.parse(trimmed)
        } catch {
            return (error as NSError).localizedDescription
        }
        if KeychainStore.setVertexServiceAccountJSON(trimmed) {
            vertexServiceAccountJSONSet = true
            return nil
        } else {
            return "Could not write to Keychain. Check Console.app for details."
        }
    }

    /// Delete the Keychain-stored Vertex AI service-account JSON.
    /// The provider's token-mint flow then throws missingCredentials
    /// on the next launch, falling through to raw-ASR paste.
    func removeVertexServiceAccountJSON() {
        if KeychainStore.removeVertexServiceAccountJSON() {
            vertexServiceAccountJSONSet = false
        }
    }

    /// Append a new blank row at the bottom of the dictionary table
    /// and persist. The empty row is filtered out by save() until the
    /// user types something into it, so the on-disk file stays clean.
    func addDictionaryEntry() {
        dictionaryEntries.append(DictionaryEntryRow())
        save()
    }

    /// Remove the row with the given UI-side id and persist.
    func removeDictionaryEntry(id: UUID) {
        dictionaryEntries.removeAll { $0.id == id }
        save()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    /// User-visible labels paired with the strings HotkeyBinding.parse
    /// accepts. Keep this in sync with HotkeyListener.HotkeyBinding.parse —
    /// anything we offer here must round-trip through that parser.
    private static let hotkeyOptions: [(value: String, label: String)] = [
        ("option-right",  "Right Option (⌥)"),
        ("option-left",   "Left Option (⌥)"),
        ("control-right", "Right Control (⌃)"),
        ("control-left",  "Left Control (⌃)"),
        ("command-right", "Right Command (⌘)"),
        ("command-left",  "Left Command (⌘)"),
        ("shift-right",   "Right Shift (⇧)"),
        ("shift-left",    "Left Shift (⇧)"),
        ("fn",            "Fn"),
    ]

    /// Bedrock model picker options. First entry is the cleanup-tier
    /// default (fast / cheap); vision-capable Claude models follow.
    /// Values are exact Bedrock model IDs / inference-profile IDs.
    /// Custom IDs go through the `customModelTag`, which surfaces a
    /// free-form TextField.
    private static let bedrockModelOptions: [(value: String, label: String)] = [
        ("openai.gpt-oss-120b-1:0",
         "GPT-OSS 120B — fastest (cleanup default)"),
        ("us.anthropic.claude-haiku-4-5-20251001-v1:0",
         "Claude Haiku 4.5 👁 — balanced"),
        ("us.anthropic.claude-sonnet-4-5-20250929-v1:0",
         "Claude Sonnet 4.5 👁 — highest quality"),
        // Claude 3.5 Sonnet / Haiku removed: AWS marked them
        // end-of-life / legacy (the 3.5 Sonnet returns
        // "model version has reached the end of its life" and
        // 3.5 Haiku returns "access denied — model is marked
        // by provider as Legacy"). Users who specifically need
        // 3.5 can still enter the ID via Custom… on the picker.
        ("us.amazon.nova-pro-v1:0",
         "Amazon Nova Pro 👁 — multimodal"),
        ("us.amazon.nova-lite-v1:0",
         "Amazon Nova Lite 👁 — fast multimodal"),
        ("us.amazon.nova-micro-v1:0",
         "Amazon Nova Micro — text-only fastest"),
        ("us.meta.llama3-3-70b-instruct-v1:0",
         "Llama 3.3 70B Instruct — text-only"),
        // Mistral Large removed: the 2407 SKU returns
        // "ValidationException: invalid model identifier" — that
        // version was deprecated. Mistral Large on Bedrock has
        // cycled through several SKUs (2402, 2407, 2411); rather
        // than guess which is currently live, keep it out of the
        // curated list. Users who track Mistral on Bedrock can
        // type the current ID via Custom….
    ]

    /// Bedrock-bearer model options. Same model IDs as Bedrock (the
    /// bearer-token path speaks the same Converse API; only auth differs).
    private static let bedrockBearerModelOptions: [(value: String, label: String)] = [
        ("openai.gpt-oss-120b-1:0",
         "GPT-OSS 120B — fastest (cleanup default)"),
        ("us.anthropic.claude-haiku-4-5-20251001-v1:0",
         "Claude Haiku 4.5 👁 — balanced"),
        ("us.anthropic.claude-sonnet-4-5-20250929-v1:0",
         "Claude Sonnet 4.5 👁 — highest quality"),
        // Claude 3.5 removed — see bedrockModelOptions for why.
        ("us.amazon.nova-pro-v1:0",
         "Amazon Nova Pro 👁 — multimodal"),
        ("us.amazon.nova-lite-v1:0",
         "Amazon Nova Lite 👁 — fast multimodal"),
        ("us.amazon.nova-micro-v1:0",
         "Amazon Nova Micro — text-only fastest"),
        ("us.meta.llama3-3-70b-instruct-v1:0",
         "Llama 3.3 70B Instruct — text-only"),
        // Mistral Large removed — see bedrockModelOptions for why.
    ]

    /// Gemini model picker options (Google AI Studio direct API).
    /// Flash-Lite is first — it's the cleanup-tier default (fastest,
    /// cheapest). Flash and Pro follow for higher-quality / vision use.
    ///
    /// Gemini 1.5 family removed: Google retired it from the direct
    /// v1beta endpoint in 2025 (`models/gemini-1.5-pro is not found
    /// for API version v1beta`). 1.5 is also retired on Vertex. Users
    /// who need a 1.5 build can enter the ID via Custom… IF they have
    /// access to an older endpoint, but the curated list shouldn't
    /// imply 1.5 still works on shipped Google paths.
    private static let geminiModelOptions: [(value: String, label: String)] = [
        ("gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite — fastest (cleanup default)"),
        ("gemini-2.5-flash",      "Gemini 2.5 Flash 👁 — recommended"),
        ("gemini-2.5-pro",        "Gemini 2.5 Pro 👁 — highest quality"),
    ]

    /// Vertex AI model picker options. Includes both Gemini models
    /// (publishers/google endpoint) and Anthropic Claude models
    /// (publishers/anthropic endpoint).
    ///
    /// Claude entries are available now that `vertexAnthropicRegion`
    /// (issue #34) lets users keep their Gemini region (e.g. us-central1)
    /// and route Claude calls through a separate region (e.g. us-east5,
    /// europe-west1) that actually hosts the Anthropic publisher.
    ///
    /// Gemini 1.5 family (pro / flash, 002 or bare alias) was
    /// removed because Google retired it from Vertex in 2025.
    /// (Still works on the direct Gemini API as legacy — see
    /// geminiModelOptions.)
    private static let vertexModelOptions: [(value: String, label: String)] = [
        ("gemini-2.5-flash-lite",         "Gemini 2.5 Flash-Lite — fastest (cleanup default)"),
        ("gemini-2.5-flash",              "Gemini 2.5 Flash 👁 — recommended"),
        ("gemini-2.5-pro",                "Gemini 2.5 Pro 👁 — highest quality"),
        ("claude-haiku-4-5@20251001",     "Claude Haiku 4.5 👁 — balanced (Anthropic via Vertex)"),
        ("claude-sonnet-4-5@20250929",    "Claude Sonnet 4.5 👁 — highest quality (Anthropic via Vertex)"),
    ]

    /// Azure OpenAI model options. Azure routes by deployment, not
    /// model name on the wire — these IDs determine vision capability
    /// detection and the request-shape family heuristic only.
    ///
    /// gpt-4.1 family added April 2025; widely deployed on Azure
    /// OpenAI Service. Standard Chat Completions API — no reasoning-
    /// model parameter quirks. 4.1-nano marked text-only as a
    /// conservative default; if a specific deployment supports
    /// vision, the conflict warning will fire but the user can
    /// downgrade or pick 4.1-mini instead.
    ///
    /// gpt-4-turbo was removed: it's a legacy SKU that may not be
    /// deployable in all Azure regions any more, and gpt-4o is a
    /// strict superset replacement. Users who specifically need a
    /// gpt-4-turbo deployment can enter the ID via Custom….
    private static let azureModelOptions: [(value: String, label: String)] = [
        ("gpt-4o-mini",  "GPT-4o Mini 👁 — fastest (cleanup default)"),
        ("gpt-4o",       "GPT-4o 👁 — highest quality"),
        ("gpt-4.1",      "GPT-4.1 👁 — current"),
        ("gpt-4.1-mini", "GPT-4.1 Mini 👁 — current, cheaper"),
        ("gpt-4.1-nano", "GPT-4.1 Nano — text-only, smallest"),
        // o-series reasoning models — slower and more expensive than
        // standard GPT, but deeper analysis for context-tier use.
        ("o1",           "o1 👁 — reasoning, slower"),
        ("o1-mini",      "o1-mini — reasoning, text-only"),
        ("o3",           "o3 👁 — reasoning, slower"),
        ("o3-mini",      "o3-mini — reasoning, text-only"),
        ("o4-mini",      "o4-mini 👁 — reasoning"),
    ]

    /// OpenAI direct (api.openai.com) model options. Unlike Azure,
    /// there is no deployment-name indirection — the model ID in the
    /// request body is the routing key. The curated list mirrors Azure's
    /// set for the 4o and 4.1 families, plus o-series reasoning models
    /// which use a conditional parameter shape (max_completion_tokens,
    /// no temperature) handled in buildRequestBody via isOpenAIReasoningModel.
    private static let openAIModelOptions: [(value: String, label: String)] = [
        ("gpt-4o-mini",  "GPT-4o Mini 👁 — fastest (cleanup default)"),
        ("gpt-4o",       "GPT-4o 👁 — highest quality"),
        ("gpt-4.1",      "GPT-4.1 👁 — current"),
        ("gpt-4.1-mini", "GPT-4.1 Mini 👁 — current, cheaper"),
        ("gpt-4.1-nano", "GPT-4.1 Nano — text-only, smallest"),
        // o-series reasoning models — slower and more expensive than
        // standard GPT, but deeper analysis for context-tier use.
        ("o1",           "o1 👁 — reasoning, slower"),
        ("o1-mini",      "o1-mini — reasoning, text-only"),
        ("o3",           "o3 👁 — reasoning, slower"),
        ("o3-mini",      "o3-mini — reasoning, text-only"),
        ("o4-mini",      "o4-mini 👁 — reasoning"),
    ]

    /// Helper to return the canonical model list for a given provider.
    /// Used by both the tier model pickers and the onChange snap logic.
    /// Delegates to ModelCatalog (the single-source-of-truth for the
    /// value lists) so Config.load()'s defense-in-depth validation and
    /// this picker stay automatically consistent.
    func modelsAvailable(forProvider provider: String) -> [String] {
        ModelCatalog.models(forProvider: provider)
    }

    /// Sidebar sections in display order. Each maps to a single
    /// detail-pane view (`hotkeySection`, `audioSection`, …) and
    /// carries a label + SF Symbol for the sidebar List.
    private enum SettingsSection: String, Hashable, CaseIterable, Identifiable {
        case hotkey, audio, behavior, paste, cleanup, dictionary, usage, permissions, privacyFeatures, updates, advanced
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hotkey:          return "Hotkey"
            case .audio:           return "Audio"
            case .behavior:        return "Behavior"
            case .paste:           return "Paste"
            case .cleanup:         return "Cleanup"
            case .dictionary:      return "Dictionary"
            case .usage:           return "Usage"
            case .permissions:     return "Permissions"
            case .privacyFeatures: return "Privacy & Features"
            case .updates:         return "Updates"
            case .advanced:        return "Advanced"
            }
        }
        var icon: String {
            switch self {
            case .hotkey:          return "keyboard"
            case .audio:           return "speaker.wave.2"
            case .behavior:        return "slider.horizontal.3"
            case .paste:           return "doc.on.clipboard"
            case .cleanup:         return "wand.and.sparkles"
            case .dictionary:      return "character.book.closed"
            case .usage:           return "chart.bar"
            case .permissions:     return "lock.shield"
            case .privacyFeatures: return "person.badge.shield.checkmark"
            case .updates:         return "arrow.down.circle"
            case .advanced:        return "gearshape.2"
            }
        }
    }

    /// Brand accent color — matches the Parleq website's amber
    /// accent (Tailwind amber-600, #d97706). Used for the selected
    /// sidebar row, the restart banner, and primary buttons.
    /// Exposed (non-private) so the Setup Wizard can reuse it.
    static let brandAccent = Color(red: 0xd9 / 255.0, green: 0x77 / 255.0, blue: 0x06 / 255.0)

    /// Sidebar background — a slightly warmer / cooler tone than
    /// the detail pane so the two columns read as distinct surfaces
    /// without resorting to a hard divider line. Adapts to light
    /// and dark mode. Reused by the wizard's footer.
    static let sidebarBackground = Color(NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil {
            // Warm dark — slight brown undertone, not pure black.
            return NSColor(red: 0.115, green: 0.110, blue: 0.105, alpha: 1.0)
        }
        // Light: warm cream, slightly off-white.
        return NSColor(red: 0.974, green: 0.972, blue: 0.965, alpha: 1.0)
    })

    /// Detail-pane background. Matches the system's
    /// `windowBackgroundColor` semantics so the right pane feels
    /// like a normal app surface.
    static let detailBackground = Color(NSColor.windowBackgroundColor)

    /// Card background — sits one tone above the detail pane so
    /// grouped fields read as a clear visual block.
    static let cardBackground = Color(NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil {
            return NSColor(red: 0.156, green: 0.150, blue: 0.144, alpha: 1.0)
        }
        return NSColor.white.withAlphaComponent(0.6)
    })

    /// Card border — very subtle, just enough to separate from the
    /// background without competing for attention.
    static let cardBorder = Color(NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil {
            return NSColor.white.withAlphaComponent(0.06)
        }
        return NSColor.black.withAlphaComponent(0.08)
    })

    // Persisted via UserDefaults so (a) the selected tab survives a
    // normal quit + relaunch, and (b) the restart-initiated reopen
    // lands on the same tab the user was configuring. SettingsSection
    // is String-raw-valued so we store the rawValue directly.
    @AppStorage("parleq.settings.selection") private var selectionRaw: String = SettingsSection.hotkey.rawValue
    private var selection: SettingsSection {
        get { SettingsSection(rawValue: selectionRaw) ?? .hotkey }
        nonmutating set { selectionRaw = newValue.rawValue }
    }
    @State private var hoveredSection: SettingsSection? = nil

    var body: some View {
        VStack(spacing: 0) {
            if model.requiresRestart {
                RestartBanner(onRestart: { ParleqApp_relaunch() })
            }
            HStack(spacing: 0) {
                sidebar
                Divider()
                    .opacity(0.5)
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Self.detailBackground)
            }
        }
        .frame(minWidth: 860, idealWidth: 920, minHeight: 600, idealHeight: 660)
        .accentColor(Self.brandAccent)
        .onAppear { model.refreshUsage() }
    }

    /// Hand-rolled sidebar — fixed width, custom row styling. Going
    /// with this instead of NavigationSplitView + .listStyle(.sidebar)
    /// because (a) NavigationSplitView's auto-balancing was shrinking
    /// the sidebar visibly when navigating to wide-content sections
    /// (Dictionary in particular), and (b) the system sidebar List
    /// doesn't let us theme the selected-row background — it always
    /// uses NSColor.controlAccentColor at the AppKit level. With a
    /// hand-rolled HStack the column width is sticky and the brand
    /// accent applies cleanly to the selection.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                sidebarRow(section)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(width: 200, alignment: .leading)
        .background(Self.sidebarBackground)
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let isSelected = selection == section
        let isHovered = hoveredSection == section
        return Button {
            selection = section
        } label: {
            // Custom HStack rather than SwiftUI's `Label` — Label uses
            // each SF Symbol's intrinsic width, so text after a wide
            // icon (`keyboard`) shifts right relative to text after
            // a narrow one (`speaker.wave.2`), making the column
            // jitter. Pinning the icon to a fixed-width frame aligns
            // every label's leading edge to the same x.
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.callout)
                    .frame(width: 20, alignment: .center)
                Text(section.label)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
            }
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(rowBackground(isSelected: isSelected, isHovered: isHovered))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredSection = hovering ? section : (hoveredSection == section ? nil : hoveredSection)
        }
    }

    private func rowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return Self.brandAccent.opacity(0.85) }
        if isHovered  { return Color.primary.opacity(0.06) }
        return Color.clear
    }

    /// Right-pane content. Wraps each section view in a scrollable
    /// container with consistent padding + a section title at the
    /// top, so each section feels like its own page rather than a
    /// scroll position inside one long form. The inner content is
    /// capped at 720pt wide so very wide sections (Dictionary)
    /// can't push the sidebar around.
    @ViewBuilder
    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(selection.label)
                    .font(.title.weight(.semibold))
                    .padding(.bottom, 4)

                switch selection {
                case .hotkey:          hotkeySection
                case .audio:           audioSection
                case .behavior:        behaviorSection
                case .paste:           pasteSection
                case .cleanup:         cleanupSection
                case .dictionary:      dictionarySection
                case .usage:           usageSection
                case .permissions:     permissionsSection
                case .privacyFeatures: privacyFeaturesSection
                case .updates:         updatesSection
                case .advanced:        advancedSection
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Human-readable line about where the cost numbers in the
    /// Usage section came from. Shows "refreshed 3h ago" when
    /// LiteLLM data is current, falls back to the bundled-defaults
    /// message when we've never successfully fetched. Recomputed
    /// each time the Settings window appears.
    private var pricingFreshnessLine: String {
        guard let last = PricingCache.shared.lastRefresh else {
            return "Costs use bundled fallback rates (live pricing not yet fetched)."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let ago = formatter.localizedString(for: last, relativeTo: Date())
        return "Costs use LiteLLM live pricing, refreshed \(ago)."
    }

    // MARK: - Per-section detail views

    @ViewBuilder
    private var hotkeySection: some View {
        SettingsCard {
            HStack(alignment: .center) {
                Text("Binding")
                    .frame(minWidth: 120, alignment: .leading)
                Picker("", selection: bind(\.hotkeyBinding)) {
                    ForEach(Self.hotkeyOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
            }
            SettingsCaption("Press and hold to dictate; release to paste. Double-tap-and-hold is quick mode (no overlay).")
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        SettingsCard {
            HStack(alignment: .center) {
                Text("Microphone")
                    .frame(minWidth: 110, alignment: .leading)
                Picker("", selection: microphoneBinding) {
                    Text("System Default").tag("")
                    let devices = availableInputDevices()
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    if !devices.isEmpty {
                        Divider()
                        ForEach(devices, id: \.uid) { device in
                            let title = device.transportLabel.map { "\(device.name)  ·  \($0)" } ?? device.name
                            Text(title).tag(device.uid)
                        }
                    }
                    // If the saved UID isn't in the connected list,
                    // surface it as a disabled-looking trailer entry
                    // so the picker still has a value to display
                    // ("(unavailable)") rather than silently snapping
                    // back to System Default.
                    if !model.audioInputDeviceUID.isEmpty,
                       !devices.contains(where: { $0.uid == model.audioInputDeviceUID }) {
                        Divider()
                        Text("Selected microphone disconnected").tag(model.audioInputDeviceUID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
            }
            SettingsCaption("Picks the input device used for dictation. \"System Default\" defers to whatever you've set as your Mac's default input — with the auto-route below to keep Bluetooth headphones in A2DP. Also reachable from the menu-bar Microphone submenu for quick switching mid-session.")
        }
        SettingsCard {
            Toggle("Keep music playing while dictating", isOn: bind(\.continueOtherAudio))
            SettingsCaption("Only applies when Microphone is set to System Default. Forces input to the built-in mic when the system default is Bluetooth, so BT headphones stay in A2DP. Restart to apply.")
        }
        SettingsCard {
            Toggle("Acoustic feedback (Tink/Pop)", isOn: bind(\.acousticFeedback))
            SettingsCaption("Subtle sound cues when a dictation starts and ends.")
        }
    }

    /// Microphone picker binding. Wraps the model field with a
    /// setter that also posts `parleqMicrophoneSelectionChanged`
    /// so the AudioRecorder's runtime selection updates and the
    /// menu-bar's checkmark stays in sync.
    private var microphoneBinding: Binding<String> {
        Binding(
            get: { model.audioInputDeviceUID },
            set: { newUid in
                guard newUid != model.audioInputDeviceUID else { return }
                model.audioInputDeviceUID = newUid
                model.save()
                NotificationCenter.default.post(
                    name: .parleqMicrophoneSelectionChanged,
                    object: nil,
                    userInfo: ["uid": newUid]
                )
            }
        )
    }

    @ViewBuilder
    private var behaviorSection: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 8) {
                Text("Auto-accept after")
                TextField(
                    "0",
                    value: bind(\.autoAcceptSeconds),
                    format: .number.precision(.fractionLength(0...1))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                Text("seconds")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            SettingsCaption("Set to 0 to never auto-accept; press Enter to accept manually.")
        }
    }

    @ViewBuilder
    private var pasteSection: some View {
        SettingsCard {
            Toggle("Append trailing space after pasted text", isOn: bind(\.trailingSpace))
            SettingsCaption("Pastes \"Hello \" instead of \"Hello\" so back-to-back dictations are space-separated automatically.")
        }
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Skip trailing space in these apps")
                    .font(.callout.weight(.medium))
                TextField(
                    "com.googlecode.iterm2, com.apple.Terminal",
                    text: bind(\.noTrailingSpaceAppsText)
                )
                .textFieldStyle(.roundedBorder)
                SettingsCaption("Comma-separated bundle IDs. Useful for terminals and other apps that handle their own spacing.")
            }
        }
    }

    @ViewBuilder
    private var cleanupSection: some View {
        // Top toolbar: "Run Setup Again" link.
        HStack {
            Spacer()
            Button {
                NotificationCenter.default.post(
                    name: .parleqRunSetupAgain,
                    object: nil
                )
            } label: {
                Label("Run Setup Again…", systemImage: "wand.and.stars")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }

        // ── Tier configuration ──────────────────────────────────────────
        tierConfiguration

        // ── Provider Credentials ─────────────────────────────────────────
        HStack(alignment: .center) {
            VStack { Divider() }
            Text("Provider Credentials")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.horizontal, 6)
            VStack { Divider() }
        }
        .padding(.top, 4)

        providerCredentialsSection
    }

    // MARK: - Tier configuration (top of Cleanup section)

    @ViewBuilder
    private var tierConfiguration: some View {
        // Resolve MDM allowlist values once so the pickers can filter.
        let cleanupAllowedProviders = ManagedConfig.managedStringArray(forKey: "cleanupAllowedProviders")
        let cleanupAllowedModels    = ManagedConfig.managedStringArray(forKey: "cleanupAllowedModels")
        let contextAllowedProviders = ManagedConfig.managedStringArray(forKey: "contextAllowedProviders")
        let contextAllowedModels    = ManagedConfig.managedStringArray(forKey: "contextAllowedModels")

        return SettingsCard {
            VStack(alignment: .leading, spacing: 18) {
                // CLEANUP TIER
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cleanup")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Used for normal dictation cleanup.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    // .top alignment so the Provider and Model labels +
                    // pickers stay vertically aligned regardless of which
                    // column has a "Managed by your organization." caption
                    // below it (captions inflate VStack height; without
                    // .top the shorter column gets centered upward).
                    HStack(alignment: .top, spacing: 12) {
                        tierProviderPicker(
                            selection: Binding(
                                get: { model.cleanupProvider },
                                set: { newVal in
                                    guard newVal != model.cleanupProvider else { return }
                                    model.cleanupProvider = newVal
                                    let available = modelsAvailable(forProvider: newVal)
                                    if !available.contains(model.cleanupModelName) {
                                        model.cleanupModelName = available.first ?? ""
                                    }
                                    model.save()
                                }
                            ),
                            label: "Provider",
                            pinnedKey: "cleanupProvider",
                            allowlistKey: "cleanupAllowedProviders",
                            allowedValues: cleanupAllowedProviders,
                            modelAllowlist: cleanupAllowedModels
                        )
                        tierModelPicker(
                            forProvider: model.cleanupProvider,
                            selection: Binding(
                                get: { model.cleanupModelName },
                                set: { newVal in
                                    guard newVal != model.cleanupModelName else { return }
                                    model.cleanupModelName = newVal
                                    model.save()
                                }
                            ),
                            label: "Model",
                            pinnedKey: "cleanupModel",
                            allowlistKey: "cleanupAllowedModels",
                            allowedModels: cleanupAllowedModels
                        )
                    }
                }

                Divider()

                // CONTEXT TIER
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Context")
                            .font(.system(size: 13, weight: .semibold))
                        Text("(Advanced)")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    Text("Used when references are attached. Vision-capable models marked 👁.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 12) {
                        tierProviderPicker(
                            selection: Binding(
                                get: { model.contextProvider },
                                set: { newVal in
                                    guard newVal != model.contextProvider else { return }
                                    model.contextProvider = newVal
                                    let available = modelsAvailable(forProvider: newVal)
                                    if !available.contains(model.contextModelName) {
                                        model.contextModelName = available.first ?? ""
                                    }
                                    model.save()
                                }
                            ),
                            label: "Provider",
                            pinnedKey: "contextProvider",
                            allowlistKey: "contextAllowedProviders",
                            allowedValues: contextAllowedProviders,
                            modelAllowlist: contextAllowedModels
                        )
                        tierModelPicker(
                            forProvider: model.contextProvider,
                            selection: Binding(
                                get: { model.contextModelName },
                                set: { newVal in
                                    guard newVal != model.contextModelName else { return }
                                    model.contextModelName = newVal
                                    model.save()
                                }
                            ),
                            label: "Model",
                            pinnedKey: "contextModel",
                            allowlistKey: "contextAllowedModels",
                            allowedModels: contextAllowedModels
                        )
                    }
                }
            }
        }
    }

    /// Provider picker for a tier (cleanup or context).
    ///
    /// When `pinnedKey` is in `managedKeys` the picker is replaced by a
    /// fixed label (single value, disabled — the IT admin pinned it). The
    /// `ManagedIndicator` appears next to the picker in all managed cases.
    ///
    /// When `allowlistKey` is in `managedKeys` the picker is shown but only
    /// the allowed subset of providers is offered; the lock icon signals the
    /// restriction. If neither key is managed, all configured providers appear
    /// and the indicator is hidden.
    private func tierProviderPicker(
        selection: Binding<String>,
        label: String,
        pinnedKey: String? = nil,
        allowlistKey: String? = nil,
        allowedValues: [String]? = nil,
        modelAllowlist: [String]? = nil
    ) -> some View {
        let isPinned    = pinnedKey.map    { model.managedKeys.contains($0) } ?? false
        let isAllowlist = allowlistKey.map { model.managedKeys.contains($0) } ?? false
        let isManaged   = isPinned || isAllowlist

        return VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                if isPinned {
                    // Pinned — show as a disabled fixed-value control.
                    let displayName = SettingsModel.providerOptions
                        .first { $0.id == selection.wrappedValue }?.displayName
                        ?? selection.wrappedValue
                    Text(displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.1))
                        )
                        .frame(maxWidth: 220, alignment: .leading)
                } else {
                    // Allowlist or unrestricted.
                    let options: [SettingsModel.ProviderOption] = {
                        // Start with the provider allowlist filter (or all
                        // providers if no provider allowlist is active).
                        var filtered: [SettingsModel.ProviderOption]
                        if let allowed = allowedValues, isAllowlist {
                            filtered = SettingsModel.providerOptions.filter { allowed.contains($0.id) }
                        } else {
                            filtered = SettingsModel.providerOptions
                        }
                        // Additional filter: when a MODEL allowlist is active,
                        // hide providers that have no model compatible with the
                        // allowlist. Prevents the confusing UX where a user
                        // picks a provider, sees its full model list, picks one
                        // that's not in the allowlist, then has it silently
                        // reverted by Config.load on next launch. Providers
                        // with at least one compatible model stay visible.
                        if let allowedModels = modelAllowlist, !allowedModels.isEmpty {
                            filtered = filtered.filter { providerOption in
                                allowedModels.contains { modelID in
                                    ModelCatalog.isCanonical(provider: providerOption.id, model: modelID)
                                }
                            }
                        }
                        return filtered
                    }()
                    Picker(label, selection: selection) {
                        ForEach(options) { option in
                            HStack {
                                Text(option.displayName)
                                // Phase 5: annotate providers whose entire
                                // auth path is blocked by staticApiKeysAllowed=false.
                                // Mixed-auth providers (Azure, Bedrock IAM, Vertex)
                                // that still have a federated path are NOT annotated
                                // here — their credential card shows the blocked state
                                // for the static mode only. Only fully-blocked providers
                                // (no federated fallback) get the "(disabled by org)"
                                // tag in the picker so the user understands upfront
                                // that selecting them will produce a cleanup error.
                                if ManagedConfig.isProviderAuthPathBlocked(provider: option.id, authMode: authModeForProvider(option.id)) {
                                    Text("(disabled by your organization)")
                                        .foregroundStyle(.red.opacity(0.8))
                                } else if !ProviderRegistry.isConfigured(option.id) {
                                    Text("(not configured)")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    // Only disable on pin. Allowlist semantics let the user
                    // pick among the allowed values, so the picker stays
                    // interactive even when MDM has restricted the options.
                }
                ManagedIndicator(isManaged: isManaged)
            }
            // Phase 5: when the currently-selected provider is blocked,
            // show an actionable caption below the picker (in addition to
            // the "(disabled by your organization)" tag in the picker row).
            let selectedBlocked = ManagedConfig.isProviderAuthPathBlocked(
                provider: selection.wrappedValue,
                authMode: authModeForProvider(selection.wrappedValue)
            )
            if selectedBlocked {
                HStack(spacing: 4) {
                    ManagedIndicator(isManaged: true)
                    Text("Disabled by your organization (requires static API key). Select a federated-auth provider to restore cleanup.")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                }
            } else {
                ManagedCaption(isManaged: isManaged)
            }
        }
    }

    /// Returns the currently-configured auth mode string for a given
    /// provider, used by the picker to determine if the provider's
    /// auth path is blocked by staticApiKeysAllowed=false (Phase 5).
    /// Mixed-auth providers (Azure, Bedrock IAM, Vertex) return their
    /// stored auth mode; API-key-only providers return nil (the gate
    /// treats nil as the default static-key path and blocks it).
    private func authModeForProvider(_ providerID: String) -> String? {
        switch providerID {
        case "azure":          return model.azureAuthMode
        case "bedrock":        return model.awsAuthMode
        case "vertex":         return model.vertexAuthMode
        default:               return nil  // gemini, openai, bedrock-bearer: api-key only
        }
    }

    /// Sentinel tag used by the model picker to represent a
    /// user-entered free-form model ID. Won't collide with any real
    /// model ID since real IDs never start with underscores.
    private static let customModelTag = "__custom__"

    /// Model picker for a tier (cleanup or context).
    ///
    /// MDM semantics (same as provider picker):
    ///   - `pinnedKey` in managedKeys → fixed label, no picker, lock icon.
    ///   - `allowlistKey` in managedKeys → picker restricted to `allowedModels`,
    ///     lock icon, user can still choose among the allowed subset.
    ///   - Neither managed → curated list + "Custom…" (if enabled).
    private func tierModelPicker(
        forProvider provider: String,
        selection: Binding<String>,
        label: String,
        pinnedKey: String? = nil,
        allowlistKey: String? = nil,
        allowedModels: [String]? = nil
    ) -> some View {
        let allModels: [(value: String, label: String)]
        switch provider {
        case "gemini":         allModels = Self.geminiModelOptions
        case "vertex":         allModels = Self.vertexModelOptions
        case "bedrock":        allModels = Self.bedrockModelOptions
        case "bedrock-bearer": allModels = Self.bedrockBearerModelOptions
        case "azure":          allModels = Self.azureModelOptions
        case "openai":         allModels = Self.openAIModelOptions
        default:               allModels = []
        }

        let isPinned    = pinnedKey.map    { model.managedKeys.contains($0) } ?? false
        let isAllowlist = allowlistKey.map { model.managedKeys.contains($0) } ?? false
        let isManaged   = isPinned || isAllowlist

        // Compute the effective model list for this picker invocation.
        let models: [(value: String, label: String)] = {
            guard let allowed = allowedModels, isAllowlist else {
                return allModels
            }
            // Cross-provider allowlist safety: filter allowed IDs to those
            // that ARE canonical for the current provider. An admin who
            // pushes a cross-provider allowlist like
            // ["gemini-2.5-flash", "gpt-4o"] without a provider lockdown
            // gets per-provider filtering automatically — Gemini users
            // only see gemini-2.5-flash; OpenAI users only see gpt-4o.
            // Bare IDs not in any catalog are still passed through under
            // the current provider's umbrella (treated as a custom value
            // that the admin authorized).
            let mapped = allowed.compactMap { id -> (value: String, label: String)? in
                if let found = allModels.first(where: { $0.value == id }) {
                    return found
                }
                // If the ID is canonical for some OTHER provider, exclude
                // it from THIS provider's picker — it would produce an
                // invalid wire combination at runtime.
                let belongsToOtherProvider = ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"]
                    .filter { $0 != provider }
                    .contains { ModelCatalog.isCanonical(provider: $0, model: id) }
                if belongsToOtherProvider {
                    return nil
                }
                return (id, id) // bare ID not in any catalog — custom value
            }
            return mapped.isEmpty ? allModels : mapped
        }()

        // Build a picker binding that maps the sentinel "Custom…" tag
        // to/from the actual model-name string.
        let curatedValues = models.map(\.value)
        let pickerBinding = Binding<String>(
            get: {
                curatedValues.contains(selection.wrappedValue)
                    ? selection.wrappedValue
                    : Self.customModelTag
            },
            set: { newValue in
                if newValue == Self.customModelTag {
                    // Only blank the field when coming FROM a curated
                    // entry; if we're already in custom mode keep the
                    // in-progress typed value.
                    if curatedValues.contains(selection.wrappedValue) {
                        selection.wrappedValue = ""
                    }
                } else {
                    selection.wrappedValue = newValue
                }
            }
        )

        let isCustom = !curatedValues.contains(selection.wrappedValue)

        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            if isPinned {
                // Pinned — show the model value as a fixed disabled display.
                HStack(spacing: 4) {
                    let displayLabel = allModels.first { $0.value == selection.wrappedValue }?.label
                        ?? selection.wrappedValue
                    Text(displayLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.1))
                        )
                        .frame(maxWidth: 280, alignment: .leading)
                    ManagedIndicator(isManaged: true)
                }
                ManagedCaption(isManaged: true)
            } else {
                HStack(spacing: 4) {
                    Picker(label, selection: pickerBinding) {
                        ForEach(models, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                        if !models.isEmpty {
                            Divider()
                        }
                        if models.isEmpty {
                            Text("—").tag(selection.wrappedValue)
                        } else if model.customModelEntryEnabled && !isManaged {
                            // "Custom…" entry hidden when customModelEntryEnabled
                            // is false OR when the model list is MDM-managed.
                            Text("Custom…").tag(Self.customModelTag)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    // Only disable on pin or empty list. Allowlist semantics
                    // let the user pick among the allowed values, so the
                    // picker stays interactive when MDM has restricted the
                    // model set.
                    .disabled(models.isEmpty)
                    ManagedIndicator(isManaged: isManaged)
                }
                ManagedCaption(isManaged: isManaged)

                // Show the text field only when Custom is selected AND the
                // entry path is enabled. If the feature is disabled and a
                // custom model is already saved, the picker will still show
                // it as the current value (no forced sanitization) — the
                // field just can't be interacted with.
                if isCustom && model.customModelEntryEnabled && !isManaged {
                    TextField("Model ID", text: selection)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(maxWidth: 280)
                }
            }
        }
    }

    // MARK: - Credential-only provider cards (no model pickers)

    /// Header row shown at the top of each credential card.
    /// `activeBadge` is an optional "Used for Cleanup" / "Used for
    /// Labeled text-field row used across the credential cards. Renders
    /// a small caption-style label above the field so a populated /
    /// disabled / MDM-managed value still tells the user WHAT it is
    /// (without a label, a disabled "corp-openai" field is an
    /// uninterpretable string). When `isManaged` is true the field
    /// disables, the lock indicator appears alongside, and the "Managed
    /// by your organization" caption appears beneath.
    @ViewBuilder
    private func labeledField(
        label: String,
        placeholder: String,
        binding: Binding<String>,
        isManaged: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            HStack(alignment: .center, spacing: 6) {
                TextField(placeholder, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isManaged)
                ManagedIndicator(isManaged: isManaged)
            }
            ManagedCaption(isManaged: isManaged)
        }
    }

    /// Context" / "Used for Cleanup + Context" label rendered inline
    /// with the provider title when the provider is actively selected
    /// for at least one tier.
    /// `isAuthPathBlocked` (Phase 5) — when true, shows an
    /// "Auth disabled by org" badge alongside the configured status
    /// so the user knows the provider won't work even if credentials
    /// are stored.
    private func credentialCardHeader(
        title: String,
        isConfigured: Bool,
        activeBadge: String? = nil,
        isAuthPathBlocked: Bool = false
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let badge = activeBadge {
                Text(badge)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            if isAuthPathBlocked {
                // Phase 5: badge shown when staticApiKeysAllowed=false
                // and the provider has no usable federated auth path.
                Text("Auth disabled by org")
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.red.opacity(0.10))
                    )
            }
            Spacer()
            if isConfigured {
                Label("Configured", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            } else {
                Text("Not configured")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Returns a "Used for Cleanup", "Used for Context", or combined
    /// badge string for a provider that's active in at least one tier.
    /// Returns nil for inactive providers.
    private func activeBadge(for provider: String) -> String? {
        let isCleanup = model.cleanupProvider == provider
        let isContext = model.contextProvider == provider
        if isCleanup && isContext { return "Used for Cleanup + Context" }
        if isCleanup              { return "Used for Cleanup" }
        if isContext              { return "Used for Context" }
        return nil
    }

    /// The set of provider IDs currently selected for at least one
    /// tier. "none" (skip-cleanup) is not a real credentials provider
    /// and is excluded.
    private var activeProviderSet: Set<String> {
        var set: Set<String> = []
        if model.cleanupProvider != "none" { set.insert(model.cleanupProvider) }
        if model.contextProvider != "none" { set.insert(model.contextProvider) }
        return set
    }

    // MARK: - Provider credentials section (progressive disclosure)

    /// Ordered list of all provider IDs used for iteration.
    private static let allCredentialProviders = [
        "gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"
    ]

    /// The full credentials section rendered below the tier card.
    /// Active providers (those selected for Cleanup or Context) are
    /// always visible with a usage badge in the card header. All
    /// other providers are collapsed behind a DisclosureGroup so
    /// users who only configure one or two providers aren't overwhelmed
    /// by five credential forms.
    @ViewBuilder
    private var providerCredentialsSection: some View {
        let active = activeProviderSet
        let activeOrdered = Self.allCredentialProviders.filter { active.contains($0) }
        let inactiveOrdered = Self.allCredentialProviders.filter { !active.contains($0) }

        // Active providers — always visible.
        ForEach(activeOrdered, id: \.self) { p in
            credentialCard(forProvider: p, badge: activeBadge(for: p))
        }

        // Inactive providers — collapsed by default.
        if !inactiveOrdered.isEmpty {
            DisclosureGroup("Other providers") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(inactiveOrdered, id: \.self) { p in
                        credentialCard(forProvider: p, badge: nil)
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12))
        }
    }

    /// Dispatches to the appropriate per-provider credential card view.
    @ViewBuilder
    private func credentialCard(forProvider provider: String, badge: String?) -> some View {
        switch provider {
        case "gemini":         geminiCredentialsCard(badge: badge)
        case "vertex":         vertexCredentialsCard(badge: badge)
        case "bedrock":        bedrockCredentialsCard(badge: badge)
        case "bedrock-bearer": bedrockBearerCredentialsCard(badge: badge)
        case "azure":          azureCredentialsCard(badge: badge)
        case "openai":         openAICredentialsCard(badge: badge)
        default:               EmptyView()
        }
    }

    @ViewBuilder
    private func geminiCredentialsCard(badge: String?) -> some View {
        // Phase 4+5: staticApiKeysAllowed=false hides the API key entry
        // affordance AND marks the card as auth-path-blocked (Phase 5).
        // Gemini (direct API) is API-key only — no federated auth path.
        let apiKeysBlocked = ManagedConfig.isProviderAuthPathBlocked(provider: "gemini", authMode: nil)
        SettingsCard {
            credentialCardHeader(title: "Gemini (Google API)", isConfigured: model.geminiKeyIsSet, activeBadge: badge, isAuthPathBlocked: apiKeysBlocked)
            if apiKeysBlocked {
                HStack(spacing: 6) {
                    ManagedIndicator(isManaged: true)
                    Text("API key entry disabled by your organization.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                GeminiAPIKeyRow(model: model)
            }
            SettingsCaption("Auth uses the GEMINI_API_KEY environment variable, then the macOS Keychain (set via the button above). Restart to apply.")
        }
    }

    @ViewBuilder
    private func vertexCredentialsCard(badge: String?) -> some View {
        // Phase 4+5: staticApiKeysAllowed=false hides the service-account JSON
        // entry button. ADC (gcloud) auth is federated and stays available.
        // Phase 5: isAuthPathBlocked is false for Vertex (ADC is a valid
        // federated fallback) unless the user has selected serviceAccount mode
        // AND staticApiKeysAllowed=false — in that case the card shows the
        // "Auth disabled by org" badge so the user knows to switch to ADC.
        let apiKeysBlocked = ManagedConfig.isProviderAuthPathBlocked(provider: "vertex", authMode: model.vertexAuthMode)
        SettingsCard {
            credentialCardHeader(
                title: "Gemini (Vertex / Google Cloud)",
                isConfigured: model.vertexServiceAccountJSONSet,
                activeBadge: badge,
                isAuthPathBlocked: apiKeysBlocked
            )
            let vertexProjectManaged = model.managedKeys.contains("vertexProject")
            let vertexRegionManaged = model.managedKeys.contains("vertexRegion")
            let vertexAnthropicRegionManaged = model.managedKeys.contains("vertexAnthropicRegion")
            let vertexAuthModeManaged = model.managedKeys.contains("vertexAuthMode")
            labeledField(label: "GCP project ID",
                         placeholder: "e.g. my-gcp-project",
                         binding: bind(\.vertexProject),
                         isManaged: vertexProjectManaged)
            labeledField(label: "Region",
                         placeholder: "e.g. us-central1",
                         binding: bind(\.vertexRegion),
                         isManaged: vertexRegionManaged)
            SettingsCaption("Gemini calls use this region.")
            labeledField(label: "Anthropic region",
                         placeholder: "e.g. us-east5",
                         binding: bind(\.vertexAnthropicRegion),
                         isManaged: vertexAnthropicRegionManaged)
            SettingsCaption("Claude calls on Vertex use this region. us-east5 and europe-west1 are common; us-central1 doesn't host the Anthropic publisher.")
            HStack(alignment: .center) {
                Text("Auth mode")
                    .frame(minWidth: 90, alignment: .leading)
                // Three managed cases collapse onto the same fixed-label
                // rendering path:
                //   1. staticApiKeysAllowed=false (apiKeysBlocked) — auth
                //      path block forces ADC; serviceAccount is the
                //      blocked static-credential path.
                //   2. vertexAuthMode is pinned by MDM — render the
                //      pinned mode as a fixed label rather than a
                //      segmented picker, so the underlying stored value
                //      (which the save() path preserves on disk) isn't
                //      visually conflated with the effective MDM choice.
                // In either case we drop the segmented picker and the
                // ManagedIndicator marks the row as managed.
                if apiKeysBlocked || vertexAuthModeManaged {
                    let pinnedLabel: String = {
                        // When apiKeysBlocked forces ADC regardless of
                        // stored value (case 1), always show ADC.
                        // Otherwise show whichever mode is pinned.
                        if apiKeysBlocked { return "gcloud (ADC)" }
                        return model.vertexAuthMode == "serviceAccount"
                            ? "Service account JSON"
                            : "gcloud (ADC)"
                    }()
                    Text(pinnedLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.1))
                        )
                    ManagedIndicator(isManaged: true)
                } else {
                    Picker("", selection: bind(\.vertexAuthMode)) {
                        Text("gcloud (ADC)").tag("adc")
                        Text("Service account JSON").tag("serviceAccount")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
                Spacer()
            }
            if model.vertexAuthMode == "serviceAccount" && !apiKeysBlocked {
                VertexServiceAccountRow(model: model)
                SettingsCaption("Paste the JSON key file you downloaded from GCP IAM → Service Accounts → Keys → Add Key. The whole JSON is stored in the macOS Keychain, never in `~/.parleq/config.json`. Parleq mints short-lived OAuth tokens directly via the SA's RSA private key — no `gcloud` CLI required. Grant the SA the Vertex AI User role on this project.")
            } else {
                // Phase 7 fix for #196: when apiKeysBlocked forces the
                // fixed "gcloud (ADC)" label above, we previously also
                // rendered a separate "Service account JSON entry
                // disabled by your organization" HStack here. That read
                // as contradictory next to the ADC label — the user
                // would see "you're using ADC" plus "JSON is disabled"
                // and wonder which one applied. The fixed label + lock
                // icon already communicates "JSON not available";
                // dropping the redundant HStack collapses the card to a
                // single coherent state.
                SettingsCaption("Auth uses your local Application Default Credentials. Run `gcloud auth application-default login` once to sign in; Parleq calls `gcloud auth application-default print-access-token` per session to mint short-lived OAuth tokens (cached in memory). The `gcloud` CLI must be on PATH.")
            }
            SettingsCaption("Restart to apply.")
        }
    }

    @ViewBuilder
    private func bedrockCredentialsCard(badge: String?) -> some View {
        // Phase 4+5: bedrockAuthMode pins the auth mode picker (Bedrock IAM only).
        // staticApiKeysAllowed=false hides the "bedrockApiKey" and "static"
        // credential-entry controls (both involve user-supplied secrets).
        // Phase 5: isAuthPathBlocked is true only when the current awsAuthMode
        // is static or bedrockApiKey AND staticApiKeysAllowed=false. SSO stays
        // available. The "Auth disabled by org" badge in the card header signals
        // that the current mode is blocked; the auth-mode picker remains visible
        // so the user can switch to SSO to escape the blocked state.
        let bedrockModePinned = model.managedKeys.contains("bedrockAuthMode")
        let apiKeysBlocked = ManagedConfig.isProviderAuthPathBlocked(provider: "bedrock", authMode: model.awsAuthMode)
        SettingsCard {
            credentialCardHeader(
                title: "Bedrock (AWS IAM)",
                isConfigured: model.awsStaticCredentialsSet || model.bedrockAPIKeySet,
                activeBadge: badge,
                isAuthPathBlocked: apiKeysBlocked
            )
            let awsRegionManaged = model.managedKeys.contains("awsRegion")
            let awsProfileManaged = model.managedKeys.contains("awsProfile")
            labeledField(label: "Region",
                         placeholder: "e.g. us-east-2",
                         binding: bind(\.awsRegion),
                         isManaged: awsRegionManaged)
            HStack(alignment: .center) {
                Text("Auth mode")
                    .frame(minWidth: 90, alignment: .leading)
                if bedrockModePinned {
                    // Pinned — show as a fixed disabled label (same pattern as
                    // tier provider/model pickers). No interactive picker.
                    let modeLabel: String = {
                        switch model.awsAuthMode {
                        case "bedrockApiKey": return "Bedrock API key"
                        case "static":        return "Static credentials"
                        default:              return "AWS CLI session (SSO)"
                        }
                    }()
                    Text(modeLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))
                    ManagedIndicator(isManaged: true)
                } else {
                    Picker("", selection: bind(\.awsAuthMode)) {
                        Text("Bedrock API key").tag("bedrockApiKey")
                        Text("AWS CLI session").tag("sso")
                        Text("Static credentials").tag("static")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
                Spacer()
            }
            if bedrockModePinned {
                ManagedCaption(isManaged: true)
            }
            // Credential-entry controls shown only for the current auth mode,
            // and only when api keys are not blocked by staticApiKeysAllowed.
            switch model.awsAuthMode {
            case "bedrockApiKey":
                if apiKeysBlocked {
                    HStack(spacing: 6) {
                        ManagedIndicator(isManaged: true)
                        Text("API key entry disabled by your organization.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    BedrockAPIKeyRow(model: model)
                }
                SettingsCaption("Bedrock API keys are scoped to Bedrock specifically — no IAM policy understanding required. Generate one in the AWS Bedrock console → API keys → Create. Stored in the macOS Keychain. Restart to apply.")
            case "static":
                if apiKeysBlocked {
                    HStack(spacing: 6) {
                        ManagedIndicator(isManaged: true)
                        Text("Static credential entry disabled by your organization.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    AWSStaticCredentialsRow(model: model)
                }
                SettingsCaption("Long-lived AWS access keys stored in the macOS Keychain. Pasted keys never appear in `~/.parleq/config.json` or any plaintext file. Restart to apply.")
            default: // "sso"
                labeledField(label: "AWS profile (optional)",
                             placeholder: "e.g. work — leave empty to use AWS_PROFILE or default",
                             binding: bind(\.awsProfile),
                             isManaged: awsProfileManaged)
                SettingsCaption("Uses your local `aws sso login --profile <name>` session. Region defaults to us-east-2; Bedrock model availability varies by region. Restart to apply.")
            }
        }
    }

    @ViewBuilder
    private func bedrockBearerCredentialsCard(badge: String?) -> some View {
        // Phase 4+5: staticApiKeysAllowed=false hides the Bearer key entry
        // AND marks the card auth-path-blocked (Phase 5). Bedrock bearer uses
        // only API-key auth — no federated path — so the card is always
        // blocked when the master switch is off.
        let apiKeysBlocked = ManagedConfig.isProviderAuthPathBlocked(provider: "bedrock-bearer", authMode: nil)
        SettingsCard {
            credentialCardHeader(
                title: "Bedrock (bearer token)",
                isConfigured: model.bedrockAPIKeySet,
                activeBadge: badge,
                isAuthPathBlocked: apiKeysBlocked
            )
            if apiKeysBlocked {
                HStack(spacing: 6) {
                    ManagedIndicator(isManaged: true)
                    Text("API key entry disabled by your organization.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                BedrockAPIKeyRow(model: model)
            }
            SettingsCaption("Bedrock API keys provide a simpler auth path — no IAM policy work required. Generate one in the AWS Bedrock console → API keys → Create. Stored in the macOS Keychain. Restart to apply.")
        }
    }

    @ViewBuilder
    private func azureCredentialsCard(badge: String?) -> some View {
        // Phase 4+5: azureAuthMode pins the auth-mode picker.
        // staticApiKeysAllowed=false hides the "Set API key" button
        // (apiKey mode only). The azureAd controls (az login / Entra ID)
        // remain visible regardless of staticApiKeysAllowed.
        // Phase 5: isAuthPathBlocked when apiKey mode is selected AND the
        // master switch is off. The "Auth disabled by org" badge in the
        // header signals the current mode is blocked; the auth-mode picker
        // stays visible so the user can switch to azureAd to escape.
        let azureModePinned = model.managedKeys.contains("azureAuthMode")
        let apiKeysBlocked = ManagedConfig.isProviderAuthPathBlocked(provider: "azure", authMode: model.azureAuthMode)
        SettingsCard {
            credentialCardHeader(
                title: "Azure OpenAI",
                isConfigured: model.azureAPIKeySet,
                activeBadge: badge,
                isAuthPathBlocked: apiKeysBlocked
            )
            let azureResourceManaged = model.managedKeys.contains("azureResource")
            let azureDeploymentManaged = model.managedKeys.contains("azureDeployment")
            // Explicit field labels — once a value populates the TextField
            // (especially when disabled + MDM-managed) the placeholder is
            // hidden and the field becomes anonymous. The label sits above
            // each field in the same caption style as tierProviderPicker.
            labeledField(label: "Resource",
                         placeholder: "e.g. corp-openai or full hostname",
                         binding: bind(\.azureResource),
                         isManaged: azureResourceManaged)
            labeledField(label: "Deployment",
                         placeholder: "e.g. gpt-4o-mini",
                         binding: bind(\.azureDeployment),
                         isManaged: azureDeploymentManaged)
            labeledField(label: "API version",
                         placeholder: "e.g. 2025-04-01-preview",
                         binding: bind(\.azureApiVersion),
                         isManaged: false)
            HStack(alignment: .center) {
                Text("Auth mode")
                    .frame(minWidth: 110, alignment: .leading)
                if azureModePinned {
                    // Pinned — show as a fixed disabled label.
                    let modeLabel = model.azureAuthMode == "azureAd" ? "Microsoft Entra ID" : "API key"
                    Text(modeLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))
                    ManagedIndicator(isManaged: true)
                } else {
                    Picker("", selection: bind(\.azureAuthMode)) {
                        Text("API key").tag("apiKey")
                        Text("Microsoft Entra ID").tag("azureAd")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
                Spacer()
            }
            if azureModePinned {
                ManagedCaption(isManaged: true)
            }
            // Credential-entry controls:
            //   azureAd mode → az login / Entra ID caption (no API key needed)
            //   apiKey mode  → AzureAPIKeyRow, unless staticApiKeysAllowed=false
            if model.azureAuthMode == "azureAd" {
                SettingsCaption("Auth uses your local `az login` session. Parleq calls `az account get-access-token --resource https://cognitiveservices.azure.com/` per session to mint short-lived OAuth bearers (cached for 50 min in memory). The Azure CLI must be on PATH. Restart to apply.")
            } else {
                // apiKey mode
                if apiKeysBlocked {
                    HStack(spacing: 6) {
                        ManagedIndicator(isManaged: true)
                        Text("API key entry disabled by your organization.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    AzureAPIKeyRow(model: model)
                }
                SettingsCaption("Resource API key from the Keys and Endpoint page of your Azure OpenAI resource. Stored in the macOS Keychain. Restart to apply.")
            }
            SettingsCaption("Azure routes by deployment name, not model name — set the deployment to match what you created in the Azure portal. The Resource field accepts either a bare resource name (e.g. `my-openai`, builds the classic `*.openai.azure.com` URL) or a full hostname (e.g. `my-resource.cognitiveservices.azure.com` or `*.services.ai.azure.com` for newer Foundry resources). Bump the API version to a current preview (e.g. `2025-04-01-preview`) for gpt-5-series models.")
        }
    }

    @ViewBuilder
    private func openAICredentialsCard(badge: String?) -> some View {
        // Phase 4+5: staticApiKeysAllowed=false hides the API key entry
        // AND marks the card auth-path-blocked (Phase 5). OpenAI direct is
        // API-key only — no federated auth path — so always blocked when the
        // master switch is off.
        let apiKeysBlocked = ManagedConfig.isProviderAuthPathBlocked(provider: "openai", authMode: nil)
        SettingsCard {
            credentialCardHeader(
                title: "OpenAI (direct API)",
                isConfigured: model.openAIAPIKeySet,
                activeBadge: badge,
                isAuthPathBlocked: apiKeysBlocked
            )
            if apiKeysBlocked {
                HStack(spacing: 6) {
                    ManagedIndicator(isManaged: true)
                    Text("API key entry disabled by your organization.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                OpenAIAPIKeyRow(model: model)
            }
            SettingsCaption("API key from platform.openai.com → API keys → Create new secret key. Stored in the macOS Keychain — never written to ~/.parleq/config.json or any plaintext file. Restart to apply.")
            SettingsCaption("Routes directly to api.openai.com without any Azure intermediary. For data-residency requirements that mandate Azure infrastructure, use Azure OpenAI instead — the model quality is equivalent.")
        }
    }

    @ViewBuilder
    private var dictionarySection: some View {
        // When customDictionaryEnabled is off, the editor is visible
        // but disabled — the user can see their entries will be
        // restored when they re-enable the feature, but can't edit
        // while the feature is off.
        let isDictEnabled = model.customDictionaryEnabled
        return SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                if !isDictEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Text("Custom dictionary is disabled. Enable it in Settings → Privacy & Features.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                }
                SettingsCaption("Names and terms the speech model commonly mishears. List alternate spellings the recognizer usually emits (comma-separated) so they all map to the same word. An optional context blurb helps the AI judge whether the topic actually matches the term. Set Biasing to LLM only when a term causes false positives at the speech-recognition layer.")

                if model.dictionaryEntries.isEmpty {
                    Text("No entries yet. Click Add Term to define your first.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach($model.dictionaryEntries) { $row in
                        DictionaryRowView(
                            row: $row,
                            onChange: { model.save() },
                            onRemove: { model.removeDictionaryEntry(id: row.id) }
                        )
                    }
                }

                HStack {
                    Button {
                        model.addDictionaryEntry()
                    } label: {
                        Label("Add Term", systemImage: "plus")
                    }
                    Spacer()
                }
                .padding(.top, 2)

                SettingsCaption("Applied on the next dictation — no restart needed.")
            }
        }
        .disabled(!isDictEnabled)
    }

    @ViewBuilder
    private var usageSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                UsageRow(label: "Today",      bucket: model.usage.today)
                UsageRow(label: "This Month", bucket: model.usage.thisMonth)
                UsageRow(label: "All Time",   bucket: model.usage.allTime)
            }
        }
        if !model.usage.byModel.isEmpty {
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("By model (all time)")
                        .font(.callout.weight(.medium))
                    ForEach(model.usage.byModel) { breakdown in
                        UsageRow(
                            label: breakdown.displayName,
                            bucket: breakdown.bucket,
                            labelWidth: 200
                        )
                    }
                }
            }
        }
        SettingsCard {
            HStack(spacing: 12) {
                Button("Refresh") { model.refreshUsage() }
                Button("Clear History") { model.clearUsage() }
                    .foregroundColor(.red)
                Spacer()
            }
            SettingsCaption("Ledger lives at ~/.parleq/usage.jsonl. \(pricingFreshnessLine) Tiered context-length pricing isn't modeled yet — verify against the provider's pricing page if amounts feel off.")
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        PermissionsSectionContent()
    }

    @ViewBuilder
    private var privacyFeaturesSection: some View {
        PrivacyFeaturesSectionContent(model: model)
    }

    @ViewBuilder
    private var updatesSection: some View {
        UpdatesSectionContent()
    }

    @ViewBuilder
    private var advancedSection: some View {
        let asrEndpointManaged = model.managedKeys.contains("asrEndpoint")
        VStack(alignment: .leading, spacing: 14) {
            // Speech-recognition endpoint (existing card).
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Speech-recognition endpoint")
                        .font(.callout.weight(.medium))
                    HStack(alignment: .center, spacing: 6) {
                        TextField("Endpoint", text: bind(\.asrEndpoint))
                            .textFieldStyle(.roundedBorder)
                            .disabled(asrEndpointManaged)
                        ManagedIndicator(isManaged: asrEndpointManaged)
                    }
                    SettingsCaption("Default uses in-process FluidAudio (Parakeet TDT v3 on the Apple Neural Engine) — no network, no local listening socket. To swap in your own speech backend, point at any OpenAI-compatible /inference server (e.g. Sherpa-ONNX or faster-whisper running locally). The bundled FluidAudio is not initialized when this is non-default, so the model's ~1.5 GB resident cost is not paid. Use the “Reset to default” button to return to the bundled endpoint sentinel \(Config.bundledASREndpoint). Restart to apply.")
                    ManagedCaption(isManaged: asrEndpointManaged)
                    HStack(spacing: 8) {
                        Button("Reset to default") {
                            model.asrEndpoint = Config.bundledASREndpoint
                            model.save()
                        }
                        .disabled(model.asrEndpoint == Config.bundledASREndpoint || asrEndpointManaged)
                        Spacer()
                    }
                }
            }

            // Reset speech model card (#214). Moved here from the
            // menu bar's "Reset ASR" item in 0.13.0 as part of the
            // menu-bar declutter. The action force-reloads the
            // bundled FluidAudio model — useful when ASR is failing
            // or returning empty, but rarely needed in practice.
            //
            // Visibility is gated solely on whether main.swift wired
            // a reset closure. That wiring only fires when the
            // bundled ASR is running, so checking the closure is
            // equivalent to "the runtime is using bundled ASR" —
            // and is more reliable than inspecting model.asrEndpoint,
            // which is the editable *configuration* value (changes
            // require restart, so it can disagree with what's
            // actually loaded).
            if model.onResetASR != nil {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Speech model")
                            .font(.callout.weight(.medium))
                        SettingsCaption("Reload the bundled FluidAudio (Parakeet) speech model. Use this if dictation is hanging, returning empty transcripts, or you see a load-failure banner — the reset re-initializes the model on the Apple Neural Engine without restarting Parleq. Rarely needed; the model normally loads once at launch and stays warm.")
                        HStack(spacing: 8) {
                            Button("Reset speech model") {
                                model.onResetASR?()
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }


    /// Helper that wraps a @Published property in a Binding which
    /// also calls model.save() on every set, so the form auto-saves.
    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<SettingsModel, T>) -> Binding<T> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0; model.save() }
        )
    }
}

/// Card-style container used by every section in the redesigned
/// Settings window. Wraps its content in a rounded-corner panel
/// over the macOS control-background colour so groups of related
/// fields are visually grouped without relying on Form's default
/// ruled-line dividers. Default padding is 18 pt on all sides;
/// each card stacks its children vertically with 12 pt spacing.
///
/// Children typically include:
///   - A row of label + control (HStack with a fixed-min-width
///     leading label).
///   - A `SettingsCaption` for explanatory text below.
///   - Inline TextFields, Toggles, and the existing API-key /
///     credentials sheet rows from earlier.
/// Card-style container shared between the Settings window and
/// the Setup Wizard. Wraps content in a rounded panel over the
/// shared `cardBackground` color so grouped fields read as one
/// visual block. Default padding 18 pt; children stack with 12 pt
/// spacing.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(SettingsView.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(SettingsView.cardBorder, lineWidth: 0.5)
        )
    }
}

/// Secondary explanatory text used below a control in a
/// `SettingsCard`. Slightly looser leading and softer color than
/// .secondary on its own — easier to read in long captions.
/// Internal (not private) so detail-pane content views split out
/// of this file (e.g. `UpdatesSectionContent` in UpdatesView.swift)
/// can reuse the same styling.
struct SettingsCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row in the Custom Dictionary table: a term field, an optional
/// context field, and a trash button. Edits invoke `onChange` so the
/// One-row Gemini API key control inside the LLM section. Two
/// states: "Set Gemini API Key" when nothing's stored; "•••• in
/// Keychain · Replace… / Remove" when a key is present. Never
/// displays the actual key value after save — even via the
/// SettingsModel — to keep secrets out of any in-memory string
/// the SwiftUI debug surface or accessibility APIs could read.
private struct GeminiAPIKeyRow: View {
    @ObservedObject var model: SettingsModel
    @State private var sheetVisible = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("API Key")
            Spacer()
            if model.geminiKeyIsSet {
                Text("•••• stored in Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Replace…") { sheetVisible = true }
                Button("Remove") { model.removeGeminiAPIKey() }
                    .foregroundColor(.red)
            } else {
                Button("Set Gemini API Key…") { sheetVisible = true }
            }
        }
        .sheet(isPresented: $sheetVisible) {
            SetGeminiAPIKeySheet(model: model, isPresented: $sheetVisible)
        }
    }
}

/// Modal sheet for entering a new Gemini API key. The text field
/// is sized for the typical AIza... key shape and uses
/// `SecureField` so the value isn't shoulder-surfable. On Save
/// the value is written to Keychain via SettingsModel, and the
/// in-memory String is dropped when the sheet dismisses.
private struct SetGeminiAPIKeySheet: View {
    @ObservedObject var model: SettingsModel
    @Binding var isPresented: Bool
    @State private var pending = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Gemini API Key")
                .font(.title3)
            Text("Get a key from Google AI Studio (aistudio.google.com → Get API key). Stored in the macOS Keychain — never written to ~/.parleq/config.json or any plaintext file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("AIza…", text: $pending)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel") {
                    pending = ""
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setGeminiAPIKey(pending)
                    pending = ""
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Pinned banner shown above the Settings Form whenever a
/// restart-required setting has been edited. Lives outside the Form
/// so it stays visible even on a long form / when the user has
/// scrolled. Pressing the button calls `SettingsView.relaunch()`,
/// which spawns a `/bin/sh` helper that waits for this process to
/// exit and then reopens the app bundle. Cmd-R is the obvious
/// keyboard shortcut (matches the macOS "reload" idiom).
private struct RestartBanner: View {
    let onRestart: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restart required")
                    .font(.headline)
                Text("Some changes only take effect after Parleq is relaunched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRestart) {
                Label("Restart Now", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.15))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// One row in the Custom Dictionary table. Two visual lines per
/// entry: the top line carries Term + Aliases + Biasing picker +
/// trash (the high-frequency edits); the bottom line is Context (the
/// occasional one). Splitting onto two lines avoids fighting the
/// grouped Form's width constraints with four side-by-side fields,
/// and lets each TextField use its own placeholder as the label —
/// which is what `labelsHidden()` was always meant to enable here.
///
/// Aliases (issue #14) carry alternate spellings the ASR commonly
/// produces; the rescorer matches against any of them but always
/// emits the canonical `term`. Biasing (issue #15) lets the user opt
/// a term out of CTC keyword spotting when it triggers false
/// positives at the STT layer — the LLM cleanup hint still uses the
/// term either way.
private struct DictionaryRowView: View {
    @Binding var row: DictionaryEntryRow
    let onChange: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                TextField("Term", text: $row.term)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .labelsHidden()
                    .onChange(of: row.term) { _, _ in onChange() }
                TextField("Aliases (optional, comma-separated)", text: $row.aliases)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220, maxWidth: .infinity)
                    .labelsHidden()
                    .onChange(of: row.aliases) { _, _ in onChange() }
                Picker("", selection: $row.biasing) {
                    Text("ASR + LLM").tag(DictionaryBiasing.asrAndLLM)
                    Text("LLM only").tag(DictionaryBiasing.llmOnly)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("ASR + LLM: bias the speech recognizer toward this spelling and let the LLM cleanup pass nudge it too. LLM only: skip the speech-recognizer bias (use this if a term causes false positives at the STT layer); the LLM cleanup pass still applies it from the smart-vocab hint.")
                .onChange(of: row.biasing) { _, _ in onChange() }
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove this term")
            }
            TextField("Context (optional, e.g. \"finance app\")", text: $row.context)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280, maxWidth: .infinity)
                .labelsHidden()
                .onChange(of: row.context) { _, _ in onChange() }
        }
        .padding(.vertical, 2)
    }
}

/// One row in the Usage section: "Today: 12 calls · 4.2k in / 0.8k
/// out · ≈$0.0042". Compact-but-informative one-line summary that
/// matches macOS Form aesthetics. Numbers use 1k = 1000 (not 1024)
/// since these are token counts, not bytes.
private struct UsageRow: View {
    let label: String
    let bucket: UsageBucket
    /// How wide to reserve for the label column. Default fits the
    /// summary rows ("Today" / "This Month" / "All Time"); the
    /// per-model breakdown bumps this up to accommodate long
    /// friendly names like "Claude Haiku 4.5 (Bedrock)".
    var labelWidth: CGFloat = 96

    var body: some View {
        HStack {
            Text(label)
                .frame(width: labelWidth, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .foregroundColor(.secondary)
                .font(.system(size: 12, design: .monospaced))
            Spacer()
            Text(costString)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var detail: String {
        let calls = bucket.calls == 1 ? "1 call" : "\(bucket.calls) calls"
        return "\(calls) · \(format(bucket.inputTokens)) in / \(format(bucket.outputTokens)) out"
    }

    private var costString: String {
        if bucket.calls == 0 { return "—" }
        // Display to 4 decimal places so sub-cent costs (typical
        // for short cleanups on Flash) show as something other than
        // $0.00. Whole-cent rounding hides actual usage at this
        // app's scale.
        return String(format: "$%.4f", bucket.costUSD)
    }

    private func format(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}


/// Sub-panel rendered inside the LLM section when the user picks a
/// provider that's defined in the matrix but not yet wired to a
/// real LLMProvider implementation. Today: Vertex AI and Azure
/// OpenAI. Selecting a placeholder provider falls through to "no
/// LLM cleanup" at runtime — Parleq pastes raw ASR — but the user
/// sees an explicit panel explaining what the provider is and
/// which roadmap step delivers it.
private struct PlaceholderProviderPanel: View {
    let name: String
    let summary: String
    let roadmapStep: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge")
                    .foregroundColor(.orange)
                Text("\(name) — coming soon")
                    .font(.body)
                    .fontWeight(.semibold)
            }
            Text(summary)
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Tracking: \(roadmapStep). Until then, picking this provider is equivalent to selecting None — Parleq pastes the raw ASR transcript.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// One-row AWS credentials control inside the Bedrock sub-panel
/// when auth-mode is "static" (#21 step 3). Mirrors the
/// GeminiAPIKeyRow pattern: shows "stored in Keychain" + Replace
/// + Remove when set, "Set AWS Credentials…" otherwise. The actual
/// secret values never round-trip through SettingsModel — only the
/// hasAWSStaticCredentials boolean.
private struct AWSStaticCredentialsRow: View {
    @ObservedObject var model: SettingsModel
    @State private var sheetVisible = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("AWS Credentials")
            Spacer()
            if model.awsStaticCredentialsSet {
                Text("•••• stored in Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Replace…") { sheetVisible = true }
                Button("Remove") { model.removeAWSStaticCredentials() }
                    .foregroundColor(.red)
            } else {
                Button("Set AWS Credentials…") { sheetVisible = true }
            }
        }
        .sheet(isPresented: $sheetVisible) {
            SetAWSCredentialsSheet(model: model, isPresented: $sheetVisible)
        }
    }
}

/// Modal sheet for entering AWS static credentials. Three fields:
/// access key id, secret access key, optional session token (for
/// short-lived STS-issued credentials; left empty for long-lived
/// IAM user keys). Secret + token use SecureField so the values
/// aren't shoulder-surfable. On Save the values are written to
/// Keychain via SettingsModel and the in-memory strings are dropped
/// when the sheet dismisses.
private struct SetAWSCredentialsSheet: View {
    @ObservedObject var model: SettingsModel
    @Binding var isPresented: Bool
    @State private var pendingAccessKeyId = ""
    @State private var pendingSecret = ""
    @State private var pendingSessionToken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set AWS Credentials")
                .font(.title3)
            Text("Long-lived AWS access keys for Bedrock. Generate them in the IAM console (Users → your user → Security credentials → Create access key) or via your org's identity provider. Stored in the macOS Keychain — never written to any plaintext file. The IAM principal needs `bedrock:InvokeModelWithResponseStream` on the models you've configured.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Access Key ID")
                        .font(.callout)
                        .frame(width: 130, alignment: .trailing)
                    TextField("AKIA…", text: $pendingAccessKeyId)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Secret Access Key")
                        .font(.callout)
                        .frame(width: 130, alignment: .trailing)
                    SecureField("", text: $pendingSecret)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Session Token")
                        .font(.callout)
                        .frame(width: 130, alignment: .trailing)
                    SecureField("(optional, only for STS creds)", text: $pendingSessionToken)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(width: 460)
            HStack {
                Spacer()
                Button("Cancel") {
                    pendingAccessKeyId = ""
                    pendingSecret = ""
                    pendingSessionToken = ""
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setAWSStaticCredentials(
                        accessKeyId: pendingAccessKeyId,
                        secretAccessKey: pendingSecret,
                        sessionToken: pendingSessionToken.isEmpty ? nil : pendingSessionToken
                    )
                    pendingAccessKeyId = ""
                    pendingSecret = ""
                    pendingSessionToken = ""
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    pendingAccessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || pendingSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// One-row Azure OpenAI API key control inside the Azure
/// sub-panel (#21 step 5). Mirrors the GeminiAPIKeyRow pattern.
private struct AzureAPIKeyRow: View {
    @ObservedObject var model: SettingsModel
    @State private var sheetVisible = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("API Key")
            Spacer()
            if model.azureAPIKeySet {
                Text("•••• stored in Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Replace…") { sheetVisible = true }
                Button("Remove") { model.removeAzureAPIKey() }
                    .foregroundColor(.red)
            } else {
                Button("Set Azure API Key…") { sheetVisible = true }
            }
        }
        .sheet(isPresented: $sheetVisible) {
            SetAzureAPIKeySheet(model: model, isPresented: $sheetVisible)
        }
    }
}

private struct SetAzureAPIKeySheet: View {
    @ObservedObject var model: SettingsModel
    @Binding var isPresented: Bool
    @State private var pending = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Azure OpenAI API Key")
                .font(.title3)
            Text("Get the key from your Azure OpenAI resource: Azure portal → your resource → Keys and Endpoint → KEY 1 (or KEY 2). Stored in the macOS Keychain — never written to ~/.parleq/config.json or any plaintext file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("32-character hex string", text: $pending)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel") {
                    pending = ""
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setAzureAPIKey(pending)
                    pending = ""
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// One-row OpenAI direct API key control inside the OpenAI
/// sub-panel (#33). Mirrors the GeminiAPIKeyRow / AzureAPIKeyRow pattern.
private struct OpenAIAPIKeyRow: View {
    @ObservedObject var model: SettingsModel
    @State private var sheetVisible = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("API Key")
            Spacer()
            if model.openAIAPIKeySet {
                Text("•••• stored in Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Replace…") { sheetVisible = true }
                Button("Remove") { model.removeOpenAIAPIKey() }
                    .foregroundColor(.red)
            } else {
                Button("Set OpenAI API Key…") { sheetVisible = true }
            }
        }
        .sheet(isPresented: $sheetVisible) {
            SetOpenAIAPIKeySheet(model: model, isPresented: $sheetVisible)
        }
    }
}

private struct SetOpenAIAPIKeySheet: View {
    @ObservedObject var model: SettingsModel
    @Binding var isPresented: Bool
    @State private var pending = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set OpenAI API Key")
                .font(.title3)
            Text("Get a key from platform.openai.com → API keys → Create new secret key. Stored in the macOS Keychain — never written to ~/.parleq/config.json or any plaintext file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("sk-…", text: $pending)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel") {
                    pending = ""
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setOpenAIAPIKey(pending)
                    pending = ""
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// One-row Vertex AI service-account JSON control inside the
/// Vertex sub-panel (#23). Mirrors the GeminiAPIKeyRow pattern.
private struct VertexServiceAccountRow: View {
    @ObservedObject var model: SettingsModel
    @State private var sheetVisible = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Service Account JSON")
            Spacer()
            if model.vertexServiceAccountJSONSet {
                Text("•••• stored in Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Replace…") { sheetVisible = true }
                Button("Remove") { model.removeVertexServiceAccountJSON() }
                    .foregroundColor(.red)
            } else {
                Button("Set Service Account JSON…") { sheetVisible = true }
            }
        }
        .sheet(isPresented: $sheetVisible) {
            SetVertexServiceAccountSheet(model: model, isPresented: $sheetVisible)
        }
    }
}

/// Modal sheet for pasting a Vertex service-account JSON (#23).
/// The JSON contains an RSA private key. We use a multi-line
/// `TextEditor` rather than `SecureField`: the SA JSON has embedded
/// newlines inside the private_key string, and `NSSecureTextField`
/// (which `SecureField` bridges to on macOS) is a single-line cell
/// whose paste behavior for multi-line content isn't guaranteed to
/// preserve bytes. The shoulder-surfing risk during a brief modal
/// paste is small compared to silently corrupting the SA JSON. The
/// value is not displayed back after Save — the row collapses to
/// "•••• stored in Keychain".
private struct SetVertexServiceAccountSheet: View {
    @ObservedObject var model: SettingsModel
    @Binding var isPresented: Bool
    @State private var pending = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Vertex AI Service Account JSON")
                .font(.title3)
            Text("Paste the entire JSON file content. Get the file from GCP IAM → Service Accounts → your SA → Keys → Add Key → Create new key → JSON. The SA needs the Vertex AI User role on the configured project. Stored in the macOS Keychain — never written to `~/.parleq/config.json` or any plaintext file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $pending)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 540, height: 200)
                .border(Color.secondary.opacity(0.3))

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    pending = ""
                    error = nil
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let validationError = model.setVertexServiceAccountJSON(pending) {
                        error = validationError
                    } else {
                        pending = ""
                        error = nil
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580)
    }
}

/// One-row Bedrock API key control (#22) inside the Bedrock
/// sub-panel when auth-mode is "bedrockApiKey". Mirrors the
/// GeminiAPIKeyRow / AzureAPIKeyRow pattern.
private struct BedrockAPIKeyRow: View {
    @ObservedObject var model: SettingsModel
    @State private var sheetVisible = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Bedrock API Key")
            Spacer()
            if model.bedrockAPIKeySet {
                Text("•••• stored in Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Replace…") { sheetVisible = true }
                Button("Remove") { model.removeBedrockAPIKey() }
                    .foregroundColor(.red)
            } else {
                Button("Set Bedrock API Key…") { sheetVisible = true }
            }
        }
        .sheet(isPresented: $sheetVisible) {
            SetBedrockAPIKeySheet(model: model, isPresented: $sheetVisible)
        }
    }
}

private struct SetBedrockAPIKeySheet: View {
    @ObservedObject var model: SettingsModel
    @Binding var isPresented: Bool
    @State private var pending = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Bedrock API Key")
                .font(.title3)
            Text("Generate a Bedrock API key from the AWS Bedrock console → API keys → Create. The key is scoped to Bedrock specifically — no broader IAM permissions, no IAM policy work required. Stored in the macOS Keychain — never written to ~/.parleq/config.json or any plaintext file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Bedrock API key…", text: $pending)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel") {
                    pending = ""
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setBedrockAPIKey(pending)
                    pending = ""
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Restart Parleq.app in place. Top-level so non-private callers
/// (the setup wizard, future menu entries) can reach it without
/// SettingsView being internal-visible. Standard self-relaunch
/// trick on macOS: spawn a detached `/bin/sh` helper that polls
/// until the current process is gone (so the supervised sidecar's
/// terminationHandler has a chance to clean up), then re-opens the
/// bundle. We then call `NSApp.terminate` synchronously. Hardened
/// Runtime allows spawning `/bin/sh` without a new entitlement.
@MainActor
public func ParleqApp_relaunch() {
    // Signal the new process to reopen the Settings window. The flag
    // is one-shot: the new process reads it once on launch and
    // immediately clears it so a subsequent normal quit + manual
    // relaunch does NOT auto-open Settings. The sidebar tab and
    // window position are already persisted independently (@AppStorage
    // + setFrameAutosaveName), so this flag only controls whether the
    // window itself appears.
    UserDefaults.standard.set(true, forKey: "parleq.reopenSettingsOnLaunch")
    let bundlePath = Bundle.main.bundlePath
    let pid = ProcessInfo.processInfo.processIdentifier
    // Quote the bundle path inside the sh -c command. Bundle paths
    // can contain spaces (the standard "/Applications/Parleq.app"
    // doesn't, but a user could install it under "~/My Apps/...").
    let cmd = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"\(bundlePath)\""
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = ["-c", cmd]
    do {
        try helper.run()
    } catch {
        // If we can't spawn the helper, the user still gets a
        // clean quit — they re-launch by hand. Log and continue
        // so we don't block on an undocumented Process failure mode.
        let msg = "[parleq] relaunch helper spawn failed: \(error)\n"
        FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
    }
    NSApp.terminate(nil)
}
