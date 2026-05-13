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
    /// Azure underlying-model family: "standard" or "reasoning".
    /// Drives which request shape Parleq sends — see
    /// `AzureOpenAIProvider.Family`.
    @Published var azureFamily: String
    /// Mirror of `KeychainStore.hasAzureAPIKey` for SwiftUI.
    @Published var azureAPIKeySet: Bool
    @Published var asrEndpoint: String
    /// Editable rows for the Custom Dictionary section. Each row is
    /// term + context fields; we strip empty terms on save and map
    /// empty context to nil. Identifiable IDs are UI-side only — they
    /// don't get persisted to disk, so they can be regenerated freely
    /// on each load.
    @Published var dictionaryEntries: [DictionaryEntryRow]

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
    private let initialAzureResource: String
    private let initialAzureDeployment: String
    private let initialAzureApiVersion: String
    private let initialAzureAuthMode: String
    private let initialAzureFamily: String

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
        self.vertexServiceAccountJSONSet = KeychainStore.hasVertexServiceAccountJSON
        self.azureResource = config.azureResource
        self.azureDeployment = config.azureDeployment
        self.azureApiVersion = config.azureApiVersion
        self.azureAuthMode = config.azureAuthMode
        self.azureFamily = config.azureFamily
        self.azureAPIKeySet = KeychainStore.hasAzureAPIKey
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
        self.initialAzureResource = config.azureResource
        self.initialAzureDeployment = config.azureDeployment
        self.initialAzureApiVersion = config.azureApiVersion
        self.initialAzureAuthMode = config.azureAuthMode
        self.initialAzureFamily = config.azureFamily
        refreshUsage()
    }

    /// Re-read the usage ledger from disk and update the Usage
    /// section. Called automatically on init and via the "Refresh"
    /// button in the Usage section.
    func refreshUsage() {
        usage = UsageLedger.shared.aggregate()
    }

    /// Re-read the entire config + Keychain mirror state from disk.
    /// Called when SettingsWindowController.show() runs so the
    /// window always reflects current disk state — handles the
    /// case where the wizard (or a manual config-file edit, or
    /// any other path) mutated the config while Settings was
    /// closed but this controller / model instance was kept
    /// around.
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
        self.vertexServiceAccountJSONSet = KeychainStore.hasVertexServiceAccountJSON
        self.azureResource = config.azureResource
        self.azureDeployment = config.azureDeployment
        self.azureApiVersion = config.azureApiVersion
        self.azureAuthMode = config.azureAuthMode
        self.azureFamily = config.azureFamily
        self.azureAPIKeySet = KeychainStore.hasAzureAPIKey
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
    var requiresRestart: Bool {
        hotkeyBinding != initialHotkeyBinding
            || llmModel != initialLlmModel
            || continueOtherAudio != initialContinueOtherAudio
            || asrEndpoint != initialAsrEndpoint
            || llmProvider != initialLlmProvider
            || awsRegion != initialAwsRegion
            || awsProfile != initialAwsProfile
            || awsAuthMode != initialAwsAuthMode
            || vertexProject != initialVertexProject
            || vertexRegion != initialVertexRegion
            || vertexAuthMode != initialVertexAuthMode
            || azureResource != initialAzureResource
            || azureDeployment != initialAzureDeployment
            || azureApiVersion != initialAzureApiVersion
            || azureAuthMode != initialAzureAuthMode
            || azureFamily != initialAzureFamily
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
        c.llmModel = llmModel.trimmingCharacters(in: .whitespaces)
        c.llmProvider = llmProvider
        c.awsRegion = awsRegion.trimmingCharacters(in: .whitespaces)
        if c.awsRegion.isEmpty { c.awsRegion = "us-east-2" }
        let trimmedProfile = awsProfile.trimmingCharacters(in: .whitespaces)
        c.awsProfile = trimmedProfile.isEmpty ? nil : trimmedProfile
        c.awsAuthMode = ["sso", "static", "bedrockApiKey"].contains(awsAuthMode) ? awsAuthMode : "sso"
        c.vertexProject = vertexProject.trimmingCharacters(in: .whitespacesAndNewlines)
        c.vertexRegion = vertexRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.vertexRegion.isEmpty { c.vertexRegion = "us-central1" }
        c.vertexAuthMode = ["adc", "serviceAccount"].contains(vertexAuthMode) ? vertexAuthMode : "adc"
        c.azureResource = azureResource.trimmingCharacters(in: .whitespacesAndNewlines)
        c.azureDeployment = azureDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
        c.azureApiVersion = azureApiVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.azureApiVersion.isEmpty { c.azureApiVersion = "2024-08-01-preview" }
        c.azureAuthMode = ["apiKey", "azureAd"].contains(azureAuthMode) ? azureAuthMode : "apiKey"
        c.azureFamily = ["standard", "reasoning"].contains(azureFamily) ? azureFamily : "standard"
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
        do {
            try Config.save(c)
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

    /// Sentinel string used as a Picker tag to reveal the
    /// free-form "Model ID" TextField. Same value across all four
    /// provider Pickers — picking it keeps the existing llmModel
    /// untouched (the binding's setter intentionally no-ops on this
    /// tag) so the user's in-progress custom entry isn't clobbered
    /// when they toggle the dropdown to "Custom (enter below)".
    static let customModelTag = "__custom__"

    /// Bedrock model picker options. The friendly labels reflect
    /// in-house benchmark results; values are the exact Bedrock
    /// model IDs / inference-profile IDs the runtime uses. Add new
    /// rows here when another candidate looks worth offering.
    /// Custom IDs go through the `customModelTag`, which surfaces a
    /// free-form TextField.
    private static let bedrockModelOptions: [(value: String, label: String)] = [
        ("openai.gpt-oss-120b-1:0",
         "GPT-OSS 120B (no thinking) — fastest"),
        ("us.anthropic.claude-haiku-4-5-20251001-v1:0",
         "Claude Haiku 4.5 — balanced"),
    ]

    /// Gemini model picker options (Google AI Studio direct API).
    /// `gemini-2.5-flash` is the default — fast enough that cleanup
    /// is barely perceptible; `flash-lite` shaves another 100–200 ms;
    /// `pro` is overkill for cleanup but exposed for users with
    /// specific accuracy needs on long technical transcripts.
    private static let geminiModelOptions: [(value: String, label: String)] = [
        ("gemini-2.5-flash",      "Gemini 2.5 Flash — recommended"),
        ("gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite — fastest"),
        ("gemini-2.5-pro",        "Gemini 2.5 Pro — highest quality"),
    ]

    /// Vertex AI model picker options. Same Gemini family as the
    /// direct API; identical IDs because Vertex's
    /// `streamGenerateContent` URL is keyed off the same model ID.
    private static let vertexModelOptions: [(value: String, label: String)] = [
        ("gemini-2.5-flash",      "Gemini 2.5 Flash — recommended"),
        ("gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite — fastest"),
        ("gemini-2.5-pro",        "Gemini 2.5 Pro — highest quality"),
    ]

    /// Sensible default model when the user toggles to a new
    /// provider — picked from the curated list above rather than
    /// leaving the previous provider's model ID stranded in the
    /// field. Azure has no model-id field at all (it routes by
    /// deployment name; only the request-shape family matters), so
    /// `azureFamily` is what changes there — `llmModel` is left
    /// as a descriptive label only.
    private static let defaultModelByProvider: [String: String] = [
        "gemini": "gemini-2.5-flash",
        "vertex": "gemini-2.5-flash",
        "bedrock": "openai.gpt-oss-120b-1:0",
        "azure": "azure",
        "none": "",
    ]

    /// Provider picker binding that resets the model field to a
    /// sensible default when the user switches between providers.
    /// Without this, switching from Gemini to Bedrock would leave
    /// `llmModel = "gemini-2.5-flash"`, which Bedrock would reject
    /// as an unknown model ID.
    private var providerBinding: Binding<String> {
        Binding(
            get: { model.llmProvider },
            set: { newValue in
                if newValue != model.llmProvider {
                    if let defaultModel = Self.defaultModelByProvider[newValue] {
                        model.llmModel = defaultModel
                    }
                    model.llmProvider = newValue
                    model.save()
                }
            }
        )
    }

    /// Build a curated-model Picker binding for the given options
    /// list. The "Custom (enter below)" picker row is mapped to
    /// `customModelTag`; selecting it transitions llmModel into a
    /// state outside the options list so SwiftUI re-evaluates the
    /// dependent `if !options.contains(...)` branch and reveals the
    /// free-form TextField.
    ///
    /// Transitions:
    ///   - User picks a curated option → set llmModel to that value.
    ///   - User picks "Custom" while llmModel is currently a curated
    ///     value → blank the model field. The picker now reports
    ///     `customModelTag` (since "" isn't in the options list), and
    ///     the surrounding view's `!options.contains(...)` branch
    ///     surfaces a TextField the user types their custom ID into.
    ///   - User picks "Custom" while already in custom mode → no-op
    ///     (don't clobber a custom entry the user just typed).
    ///
    /// One helper covers all four providers — Gemini, Vertex,
    /// Bedrock, Azure — since the dropdown shape is identical and
    /// only the options array differs.
    private func curatedModelBinding(
        options: [(value: String, label: String)]
    ) -> Binding<String> {
        Binding(
            get: {
                options.contains { $0.value == model.llmModel }
                    ? model.llmModel
                    : Self.customModelTag
            },
            set: { newValue in
                if newValue == Self.customModelTag {
                    // No-op when already in custom mode — preserves
                    // whatever the user has typed into the TextField.
                    if !options.contains(where: { $0.value == model.llmModel }) {
                        return
                    }
                    // Coming from a curated option. Blank the model
                    // so the picker actually flips to the Custom row
                    // and the TextField becomes visible.
                    model.llmModel = ""
                    model.save()
                    return
                }
                if newValue != model.llmModel {
                    model.llmModel = newValue
                    model.save()
                }
            }
        )
    }

    /// Sidebar sections in display order. Each maps to a single
    /// detail-pane view (`hotkeySection`, `audioSection`, …) and
    /// carries a label + SF Symbol for the sidebar List.
    private enum SettingsSection: String, Hashable, CaseIterable, Identifiable {
        case hotkey, audio, behavior, paste, cleanup, dictionary, usage, permissions, advanced
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hotkey:      return "Hotkey"
            case .audio:       return "Audio"
            case .behavior:    return "Behavior"
            case .paste:       return "Paste"
            case .cleanup:     return "Cleanup"
            case .dictionary:  return "Dictionary"
            case .usage:       return "Usage"
            case .permissions: return "Permissions"
            case .advanced:    return "Advanced"
            }
        }
        var icon: String {
            switch self {
            case .hotkey:      return "keyboard"
            case .audio:       return "speaker.wave.2"
            case .behavior:    return "slider.horizontal.3"
            case .paste:       return "doc.on.clipboard"
            case .cleanup:     return "wand.and.sparkles"
            case .dictionary:  return "character.book.closed"
            case .usage:       return "chart.bar"
            case .permissions: return "lock.shield"
            case .advanced:    return "gearshape.2"
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

    @State private var selection: SettingsSection = .hotkey
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
            Label(section.label, systemImage: section.icon)
                .font(.callout.weight(isSelected ? .semibold : .regular))
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
                case .hotkey:      hotkeySection
                case .audio:       audioSection
                case .behavior:    behaviorSection
                case .paste:       pasteSection
                case .cleanup:     cleanupSection
                case .dictionary:  dictionarySection
                case .usage:       usageSection
                case .permissions: permissionsSection
                case .advanced:    advancedSection
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

        SettingsCard {
            HStack(alignment: .center) {
                Text("Provider")
                    .frame(minWidth: 90, alignment: .leading)
                Picker("", selection: providerBinding) {
                    Text("Google Gemini (direct API)").tag("gemini")
                    Text("Google Vertex AI").tag("vertex")
                    Text("AWS Bedrock").tag("bedrock")
                    Text("Azure OpenAI").tag("azure")
                    Text("None — paste raw ASR (skip cleanup)").tag("none")
                }
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
            }
        }

        // Provider-specific configuration card.
        switch model.llmProvider {
        case "bedrock":   bedrockProviderCard
        case "vertex":    vertexProviderCard
        case "azure":     azureProviderCard
        case "none":      noneProviderCard
        default:          geminiProviderCard
        }
    }

    @ViewBuilder
    private var bedrockProviderCard: some View {
        SettingsCard {
            HStack(alignment: .center) {
                Text("Model")
                    .frame(minWidth: 90, alignment: .leading)
                Picker("", selection: curatedModelBinding(options: Self.bedrockModelOptions)) {
                    ForEach(Self.bedrockModelOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                    Text("Custom (enter below)").tag(Self.customModelTag)
                }
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
            }
            if !Self.bedrockModelOptions.contains(where: { $0.value == model.llmModel }) {
                TextField("Model ID", text: bind(\.llmModel))
                    .textFieldStyle(.roundedBorder)
            }
            TextField("Region", text: bind(\.awsRegion))
                .textFieldStyle(.roundedBorder)

            HStack(alignment: .center) {
                Text("Auth mode")
                    .frame(minWidth: 90, alignment: .leading)
                Picker("", selection: bind(\.awsAuthMode)) {
                    Text("Bedrock API key").tag("bedrockApiKey")
                    Text("AWS CLI session").tag("sso")
                    Text("Static credentials").tag("static")
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
            }

            switch model.awsAuthMode {
            case "bedrockApiKey":
                BedrockAPIKeyRow(model: model)
                SettingsCaption("Bedrock API keys are scoped to Bedrock specifically — no IAM policy understanding required, can be rotated independently from your IAM access keys. Generate one in the AWS Bedrock console → API keys → Create. Stored in the macOS Keychain. Restart to apply.")
            case "static":
                AWSStaticCredentialsRow(model: model)
                SettingsCaption("Long-lived AWS access keys stored in the macOS Keychain. Pasted keys never appear in `~/.parleq/config.json` or any plaintext file. AWS access keys don't expire on their own — rotate per your org's policy. Restart to apply.")
            default: // "sso"
                TextField("AWS profile (optional)", text: bind(\.awsProfile))
                    .textFieldStyle(.roundedBorder)
                SettingsCaption("Uses your local `aws sso login --profile <name>` session. If credentials are rejected, the cleanup overlay will surface the exact CLI command to re-login. Region defaults to us-east-2; Bedrock model availability varies by region. Restart to apply.")
            }
        }
    }

    @ViewBuilder
    private var vertexProviderCard: some View {
        SettingsCard {
            HStack(alignment: .center) {
                Text("Model")
                    .frame(minWidth: 90, alignment: .leading)
                Picker("", selection: curatedModelBinding(options: Self.vertexModelOptions)) {
                    ForEach(Self.vertexModelOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                    Text("Custom (enter below)").tag(Self.customModelTag)
                }
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
            }
            if !Self.vertexModelOptions.contains(where: { $0.value == model.llmModel }) {
                TextField("Model ID", text: bind(\.llmModel))
                    .textFieldStyle(.roundedBorder)
            }
            TextField("GCP project ID", text: bind(\.vertexProject))
                .textFieldStyle(.roundedBorder)
            TextField("Region (e.g. us-central1)", text: bind(\.vertexRegion))
                .textFieldStyle(.roundedBorder)

            HStack(alignment: .center) {
                Text("Auth mode")
                    .frame(minWidth: 90, alignment: .leading)
                Picker("", selection: bind(\.vertexAuthMode)) {
                    Text("gcloud (ADC)").tag("adc")
                    Text("Service account JSON").tag("serviceAccount")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Spacer()
            }

            if model.vertexAuthMode == "serviceAccount" {
                VertexServiceAccountRow(model: model)
                SettingsCaption("Paste the JSON key file you downloaded from GCP IAM → Service Accounts → Keys → Add Key. The whole JSON is stored in the macOS Keychain, never in `~/.parleq/config.json`. Parleq mints short-lived OAuth tokens directly via the SA's RSA private key — no `gcloud` CLI required. Grant the SA the Vertex AI User role on this project.")
            } else {
                SettingsCaption("Auth uses your local Application Default Credentials. Run `gcloud auth application-default login` once to sign in; Parleq calls `gcloud auth application-default print-access-token` per session to mint short-lived OAuth tokens (cached in memory). The `gcloud` CLI must be on PATH.")
            }
            SettingsCaption("Restart to apply.")
        }
    }

    @ViewBuilder
    private var azureProviderCard: some View {
        // Azure routes by deployment name, not model name — there
        // is no per-call model identifier on the wire. The only
        // thing Parleq needs to know is the request-shape family:
        // standard (gpt-4o etc.) vs reasoning (gpt-5, o-series).
        SettingsCard {
            HStack(alignment: .center) {
                Text("Model family")
                    .frame(minWidth: 110, alignment: .leading)
                Picker("", selection: bind(\.azureFamily)) {
                    Text("Standard (gpt-4o, gpt-4 family)").tag("standard")
                    Text("Reasoning (gpt-5, o-series)").tag("reasoning")
                }
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
            }
            TextField("Resource name or full hostname", text: bind(\.azureResource))
                .textFieldStyle(.roundedBorder)
            TextField("Deployment name", text: bind(\.azureDeployment))
                .textFieldStyle(.roundedBorder)
            TextField("API version", text: bind(\.azureApiVersion))
                .textFieldStyle(.roundedBorder)

            HStack(alignment: .center) {
                Text("Auth mode")
                    .frame(minWidth: 110, alignment: .leading)
                Picker("", selection: bind(\.azureAuthMode)) {
                    Text("API key").tag("apiKey")
                    Text("Microsoft Entra ID").tag("azureAd")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Spacer()
            }

            if model.azureAuthMode == "azureAd" {
                SettingsCaption("Auth uses your local `az login` session. Parleq calls `az account get-access-token --resource https://cognitiveservices.azure.com/` per session to mint short-lived OAuth bearers (cached for 50 min in memory). The Azure CLI must be on PATH. Restart to apply.")
            } else {
                AzureAPIKeyRow(model: model)
                SettingsCaption("Resource API key from the Keys and Endpoint page of your Azure OpenAI resource. Stored in the macOS Keychain. Restart to apply.")
            }

            SettingsCaption("Azure routes by deployment name, not model name — set the deployment to match what you created in the Azure portal. The Resource field accepts either a bare resource name (e.g. `my-openai`, builds the classic `*.openai.azure.com` URL) or a full hostname (e.g. `my-resource.cognitiveservices.azure.com` or `*.services.ai.azure.com` for newer Foundry resources). Bump the API version to a current preview (e.g. `2025-04-01-preview`) for gpt-5-series models.")
        }
    }

    @ViewBuilder
    private var noneProviderCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cleanup disabled.")
                    .font(.body.weight(.medium))
                SettingsCaption("Parleq pastes the raw transcript exactly as the on-device speech model emitted it — no punctuation cleanup, no filler removal, no spoken-numbers-to-digits, no custom-dictionary AI hint. Faster end-to-end (no cloud round-trip). Fully local. Best for privacy-strict environments where transcript content cannot leave the device, or when you want to manually edit the output before it pastes (custom dictionary's STT-side biasing still applies).")
            }
        }
    }

    @ViewBuilder
    private var geminiProviderCard: some View {
        SettingsCard {
            HStack(alignment: .center) {
                Text("Model")
                    .frame(minWidth: 90, alignment: .leading)
                Picker("", selection: curatedModelBinding(options: Self.geminiModelOptions)) {
                    ForEach(Self.geminiModelOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                    Text("Custom (enter below)").tag(Self.customModelTag)
                }
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
            }
            if !Self.geminiModelOptions.contains(where: { $0.value == model.llmModel }) {
                TextField("Model ID", text: bind(\.llmModel))
                    .textFieldStyle(.roundedBorder)
            }
            GeminiAPIKeyRow(model: model)
            SettingsCaption("Auth uses the GEMINI_API_KEY environment variable, then the macOS Keychain (set via the button above). Restart to apply.")
        }
    }

    @ViewBuilder
    private var dictionarySection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
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
    private var advancedSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Speech-recognition endpoint")
                    .font(.callout.weight(.medium))
                TextField("Endpoint", text: bind(\.asrEndpoint))
                    .textFieldStyle(.roundedBorder)
                SettingsCaption("Default uses in-process FluidAudio (Parakeet TDT v3 on the Apple Neural Engine) — no network, no local listening socket. To swap in your own speech backend, point at any OpenAI-compatible /inference server (e.g. Sherpa-ONNX or faster-whisper running locally). The bundled FluidAudio is not initialized when this is non-default, so the model's ~1.5 GB resident cost is not paid. Use the “Reset to default” button to return to the bundled endpoint sentinel \(Config.bundledASREndpoint). Restart to apply.")
                HStack(spacing: 8) {
                    Button("Reset to default") {
                        model.asrEndpoint = Config.bundledASREndpoint
                        model.save()
                    }
                    .disabled(model.asrEndpoint == Config.bundledASREndpoint)
                    Spacer()
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
private struct SettingsCaption: View {
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

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model = SettingsModel()

    /// Show the settings window, creating it on first call. Subsequent
    /// calls bring the existing window to front rather than spawning
    /// a second one. Always re-centers on the active screen so users
    /// who've moved the window or attached/detached an external
    /// display don't have to hunt for it.
    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Parleq Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.collectionBehavior = [.fullScreenAuxiliary]
            // Don't release when closed — we keep the controller
            // around so a re-open shows the same instance with its
            // model state intact.
            w.isReleasedWhenClosed = false
            // Set the content size explicitly BEFORE center() runs
            // below. Without this, the first open's center() runs
            // against a default tiny frame; SwiftUI then grows the
            // window to its real size anchored from the bottom-left
            // origin, pushing it up and to the right of where center
            // should have put it. Subsequent opens reuse the existing
            // window (already at its real size), so center() works
            // correctly. Setting an explicit content size first
            // makes the very first open behave the same way.
            w.setContentSize(NSSize(width: 920, height: 660))
            self.window = w
        }
        // Re-read disk state on every show. Without this, anything
        // that writes ~/.parleq/config.json or the macOS Keychain
        // outside the Settings UI (the setup wizard, manual
        // config-file edits, future Recents-clearing flows, etc.)
        // would leave the @Published fields stale until the user
        // quits and relaunches Parleq.
        model.reload()
        // Center on every show. We previously used setFrameAutosaveName
        // to remember position, but for a small focused utility
        // window the predictable behavior — "always pops up centered" —
        // is more useful than restoring the last position the user
        // dragged it to. SwiftUI .frame(idealWidth:) provides the
        // default size; manual user resizes don't persist across
        // re-opens (intentional simplification).
        window?.center()
        // For an LSUIElement app, NSApp.activate brings our windows
        // forward without adding a Dock icon (since LSUIElement
        // suppresses the icon regardless of activation policy).
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
/// Multiline TextEditor sized for a typical SA JSON (~2–3 KB). The
/// JSON contains an RSA private key, so it's effectively a secret;
/// the field uses a regular TextEditor for legibility while pasting
/// (SecureField doesn't support multiline) but the value isn't
/// displayed back after Save — the row collapses to "•••• stored
/// in Keychain" instead.
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
func ParleqApp_relaunch() {
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
