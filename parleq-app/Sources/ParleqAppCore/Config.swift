// Config — load runtime knobs from ~/.parleq/config.json.
//
// v0.1 uses JSON because Swift's Foundation can parse it without
// dependencies. The design doc names ~/.parleq/config.toml; we'll
// swap to TOML in M6 when we add a parser library to the .app
// bundle. The schema below is the same either way.
//
// Schema (every field optional, defaults applied for missing ones):
//
//   {
//     "hotkey":    { "binding": "option-right" },
//     "ui":        { "auto_accept_seconds": 6,
//                    "acoustic_feedback": true },
//     "audio":     { "continue_other_audio": true },
//     "asr":       { "mode": "default" },
//     "llm":       { "mode": "default",
//                    "provider": "gemini",
//                    "model": "gemini-2.5-flash" },
//     "aws":       { "region": "us-east-2",
//                    "profile": "work" },
//     "paste":     { "trailing_space": true,
//                    "no_trailing_space_apps": [
//                      "com.googlecode.iterm2",
//                      "com.apple.Terminal"
//                    ] },
//     "dictionary":{ "terms": [
//                      { "term": "Parleq" },
//                      { "term": "Acme",
//                        "context": "mobile finance app I'm building",
//                        "aliases": ["ackme", "ack me"],
//                        "biasing": "llmOnly" }
//                    ] },
//     "telemetry": { "enabled": false }
//   }
//
// Knobs wired in this round: ui.auto_accept_seconds,
// ui.acoustic_feedback, llm.model. The asr.mode / llm.mode
// provider-selection knobs are reserved for when we add multi-
// provider runtime support (M5.5+).
//
// Loading rules: if the file is missing or malformed, every default
// applies and a single warning is logged. We never abort startup
// over config — better to run with defaults than fail to launch.

import Foundation

/// A pairing of LLM provider and model name. Used to identify which
/// backend and model should handle a given phase of LLM work (cleanup,
/// context-aware turns with references, etc.).
public struct ModelIdentifier: Sendable, Equatable, Hashable, Codable {
    public var provider: String
    public var model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }
}

extension ModelIdentifier {
    /// Short display name for the ModelBadge and ModelPicker rows.
    /// Strips any leading provider prefix ("gemini-", "claude-",
    /// "gpt-") and Title-Cases the remainder so it reads naturally
    /// in the UI without duplicating the group header.
    public var displayShort: String {
        // Strip known provider prefixes so the badge reads
        // "2.5 Flash" (not "gemini-2.5-flash") or "Sonnet 4-5"
        // (not "claude-sonnet-4-5").
        let prefixes = ["gemini-", "claude-", "gpt-", "openai.", "anthropic."]
        var stripped = model
        for prefix in prefixes {
            if stripped.lowercased().hasPrefix(prefix) {
                stripped = String(stripped.dropFirst(prefix.count))
                break
            }
        }
        // Replace remaining hyphens/dots with spaces then title-case.
        let spaced = stripped
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        return spaced
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Which layers a custom-dictionary entry biases. ASR-side
/// biasing (`asrAndLLM`) is the default and works well for
/// distinctive proper nouns, but it can over-correct when a term
/// shares a phonetic tail with a common English word
/// (e.g. "ultrathink" replacing "everything"). `llmOnly` excludes
/// the term from the X-Parleq-Vocabulary header sent to the
/// sidecar, leaving the smart-vocabulary hint in the LLM cleanup
/// pass to do the work — slower but more contextually aware.
public enum DictionaryBiasing: String, Sendable, Equatable, Codable {
    case asrAndLLM
    case llmOnly
}

/// One entry in the user's custom dictionary. `term` is the canonical
/// spelling Parleq biases toward. `context` is an optional one-line
/// blurb describing what the term is, so the LLM cleanup pass can
/// judge whether the surrounding speech topic matches before
/// committing to a correction. `aliases` are alternate spellings
/// the ASR layer commonly produces (e.g. "Haagen-Dazs" → canonical
/// "Häagen-Dazs"); both layers match against the alias list and
/// emit the canonical form. `biasing` controls which layers
/// receive this entry; defaults to ASR + LLM.
public struct DictionaryEntry: Sendable, Equatable {
    public var term: String
    public var context: String?
    public var aliases: [String]
    public var biasing: DictionaryBiasing

    public init(
        term: String,
        context: String? = nil,
        aliases: [String] = [],
        biasing: DictionaryBiasing = .asrAndLLM
    ) {
        self.term = term
        self.context = context
        self.aliases = aliases
        self.biasing = biasing
    }
}

public struct Config: Sendable {
    public var hotkeyBinding: String
    public var autoAcceptSeconds: TimeInterval
    public var acousticFeedback: Bool
    public var asrMode: String
    public var llmMode: String
    public var llmModel: String
    /// Which LLM backend handles cleanup. One of:
    ///   - "gemini" — direct Google AI Studio API (default).
    ///   - "vertex" — Google Vertex AI (Gemini on GCP).
    ///   - "bedrock" — AWS Bedrock ConverseStream (or the
    ///     bearer-auth path for scoped Bedrock API keys).
    ///   - "azure"  — Azure OpenAI Chat Completions.
    ///   - "none"   — skip cleanup, paste the raw ASR transcript.
    public var llmProvider: String
    /// AWS region used when `llmProvider == "bedrock"`. Defaults to
    /// us-east-2 — the user's work-machine target region. Bedrock
    /// model availability varies by region; if a model isn't
    /// enabled in the configured region, the call returns a
    /// validation error.
    public var awsRegion: String
    /// AWS profile name from `~/.aws/config`, used when
    /// `llmProvider == "bedrock"` and `awsAuthMode == "sso"`.
    /// Empty/nil falls back to the default profile (or
    /// `AWS_PROFILE` env var). Ignored when `awsAuthMode == "static"`.
    public var awsProfile: String?
    /// Bedrock auth mode. Three options today:
    ///   - "sso" (default): user's AWS CLI session via Soto's
    ///     `.sso()` provider. Soto handles SigV4 + token refresh.
    ///   - "static": IAM access keys pasted into Settings. Stored
    ///     in the macOS Keychain. Soto's `.static()` provider.
    ///   - "bedrockApiKey" (#22): scoped Bedrock-only Bearer
    ///     token. Bypasses Soto entirely — the
    ///     `BedrockBearerProvider` does plain HTTP with
    ///     `Authorization: Bearer <key>` and an in-tree
    ///     event-stream parser.
    public var awsAuthMode: String
    /// Google Cloud project ID for Vertex AI (#21 step 4). Used as
    /// the `projects/{project}` segment in the streamGenerateContent
    /// URL when `llmProvider == "vertex"`.
    public var vertexProject: String
    /// Vertex AI location, e.g. "us-central1", "europe-west4". Used
    /// as both the regional subdomain and the
    /// `locations/{region}` segment.
    public var vertexRegion: String
    /// Vertex AI auth mode (#23). "adc" (default) shells out to
    /// gcloud; "serviceAccount" mints OAuth tokens from a pasted
    /// SA JSON stored in the Keychain.
    public var vertexAuthMode: String
    /// Region used for Anthropic publisher calls on Vertex AI (Claude
    /// models). Defaults to "us-east5" — one of the few regions where
    /// Vertex hosts the Anthropic publisher. Kept separate from
    /// `vertexRegion` (the Gemini-call region) so users can keep their
    /// primary Gemini region in us-central1 while routing Claude
    /// through us-east5 without affecting cost / latency / data
    /// residency for non-Claude calls.
    public var vertexAnthropicRegion: String
    /// Azure OpenAI resource name (#21 step 5) — the prefix in
    /// `https://{resource}.openai.azure.com/...`. From the "Keys
    /// and Endpoint" page of the resource in the Azure portal.
    public var azureResource: String
    /// Azure OpenAI deployment name. Each deployment binds a model
    /// (e.g. gpt-4o-mini) to a name you pick in the Azure portal.
    /// The API routes by deployment name, not model name.
    public var azureDeployment: String
    /// Azure OpenAI API version. Defaults to a recent stable
    /// preview; users can override if their deployment requires a
    /// specific version.
    public var azureApiVersion: String
    /// Azure OpenAI auth mode. "apiKey" (default) sends the
    /// resource API key in the `api-key` header. "azureAd" mints
    /// a Microsoft Entra ID OAuth bearer via the user's `az login`
    /// session and sends it in `Authorization: Bearer <token>`.
    public var azureAuthMode: String
    /// True after the user has finished (or explicitly skipped) the
    /// first-run setup wizard (#21 step 6). Drives whether the
    /// wizard auto-launches on app start. The user can re-run the
    /// wizard at any time from the menu bar or Settings — this flag
    /// only controls auto-launch.
    public var wizardCompleted: Bool
    /// When true, Paster appends a trailing space to the cleaned
    /// text before pasting (so back-to-back dictations are
    /// space-separated automatically). Apps in
    /// `noTrailingSpaceAppBundleIDs` opt out of this behavior.
    public var trailingSpace: Bool
    /// Bundle IDs where the trailing space should be SKIPPED. The
    /// canonical case is terminal-hosted TUI tools like Claude Code
    /// where trailing whitespace gets stripped or interpreted as a
    /// command argument. Default is empty — opt in by adding the
    /// app's bundle ID. Tier-2 auto-detection of TUI tools via
    /// process tree walk is filed as a separate issue.
    public var noTrailingSpaceAppBundleIDs: [String]
    /// When true, the recorder forces input to the built-in mic if
    /// the system's default input is Bluetooth, so BT headphones
    /// stay in A2DP (high-quality output) instead of being yanked
    /// into HFP/SCO (low-quality bidirectional) the moment we start
    /// capturing. This is the "music keeps playing while I dictate"
    /// behavior. Default true. Set false to use whatever input the
    /// user has selected as system default (e.g. for users with a
    /// USB mic or wired headset who want high-quality input
    /// regardless).
    public var continueOtherAudio: Bool
    /// User's explicit microphone choice, persisted as a Core Audio
    /// device UID (e.g. "BuiltInMicrophoneDevice", a USB mic's HAL
    /// UID, an AirPods address-keyed UID). Empty string means "use
    /// the System Default with the BT auto-route heuristic" (the
    /// pre-#25 behavior driven by `continueOtherAudio`).
    /// Set via the menu-bar Microphone submenu (#25). When the UID
    /// fails to resolve at app launch (e.g., the USB mic is
    /// unplugged), AudioRecorder silently falls through to System
    /// Default; the menu surfaces the saved selection as a
    /// disconnected placeholder until the device reconnects.
    public var audioInputDeviceUID: String
    /// HTTP endpoint Parleq's ASRClient POSTs WAV files to. The
    /// default value matches `Config.bundledASREndpoint`, which is
    /// a magic sentinel meaning "use in-process FluidAudio
    /// (Parakeet TDT v3 on the Apple Neural Engine)" — the literal
    /// URL string is the retired sidecar's old listen address,
    /// kept for back-compat with config files written by earlier
    /// builds. Override to any other value to swap in an
    /// OpenAI-compatible `/inference` server (e.g. a Sherpa-ONNX
    /// or faster-whisper server you're running locally); the
    /// bundled FluidAudio engine is then never initialized
    /// (saves ~1.5 GB of resident memory).
    public var asrEndpoint: String
    /// User-maintained list of names/terms ("Parleq", "Acme",
    /// "FluidAudio", …) that ASR commonly mis-transcribes. Each entry
    /// can carry an optional one-line context blurb so the LLM can
    /// judge whether the surrounding speech topic actually matches
    /// the term before correcting. Fed to the LLM cleanup pass as a
    /// smart hint, not a forced-replace rule. Empty by default.
    public var customDictionary: [DictionaryEntry]
    /// Model to use when references are attached to a dictation.
    /// nil means "fall back to the cleanup model" — that's the setup
    /// wizard's "Same as cleanup" default and the legacy behavior for
    /// pre-Phase-2 configs.
    public var contextModel: ModelIdentifier?
    public var telemetryEnabled: Bool

    // MARK: - Feature toggles (Phase 5 / Tier 1)
    //
    // Each toggle defaults to true. Users can flip them off in Settings
    // → Privacy & Features. IT admins can force them off (or on) via
    // /Library/Managed Preferences/com.parleq.app.plist — see
    // ManagedConfig.swift and docs/managed-configuration for the MDM
    // schema. The stored value in ~/.parleq/config.json is the user's
    // choice; Config.load() overrides it when an MDM-managed value is
    // present, and Config.save() skips managed keys so re-loading
    // without MDM falls back cleanly to the user-stored value.

    /// Master switch for the Reference Windows feature.
    /// When false: hides the overlay's reference-attach button, chip
    /// strip, and drop zone; ignores captureReferenceWindow calls; and
    /// falls through to standard cleanup even if references somehow
    /// exist in the session. Sub-toggles (clipboard/image/file) are
    /// gated by this first.
    public var referenceWindowsEnabled: Bool
    /// Sub-feature of referenceWindowsEnabled.
    /// When false: hides the "Add from clipboard" affordance in the
    /// overlay's + menu.
    public var clipboardReferenceEnabled: Bool
    /// Sub-feature of referenceWindowsEnabled.
    /// When false: hides the T/👁 mode-toggle on every ReferenceChip
    /// and forces all new captures to .text mode. Prevents screenshots
    /// being sent to the LLM. Existing image-mode references in the
    /// session fall back to text-mode for prompt-building.
    public var imageReferenceEnabled: Bool
    /// Sub-feature of referenceWindowsEnabled.
    /// When false: hides the "Add file…" picker and the drag-drop
    /// affordance. Window-capture and clipboard remain available.
    public var fileReferenceEnabled: Bool
    /// When false: hides the dictionary editor in Settings and passes
    /// an empty dictionary to the LLM cleanup prompt, regardless of
    /// what entries the user has stored. The stored entries survive
    /// the toggle — flipping back on restores them.
    public var customDictionaryEnabled: Bool
    /// When false: hides the "Custom…" entry in every provider's model
    /// picker. The toggle only hides the entry path; an already-saved
    /// custom model ID continues to work until the user picks a curated
    /// model. Prevents users from routing to arbitrary model endpoints
    /// in managed deployments.
    public var customModelEntryEnabled: Bool

    /// Keys whose effective values were sourced from MDM
    /// (/Library/Managed Preferences) rather than from the user's
    /// config file. Populated by Config.load(); never persisted to disk.
    /// Settings rows read this to call `.disabled(managedKeys.contains(key))`.
    /// The lock-icon badge UI (ManagedIndicator) also consumes this.
    public var managedKeys: Set<String>

    /// Sentinel value for `asr.endpoint` meaning "use in-process
    /// FluidAudio." The literal string is the retired bundled
    /// sidecar's old listen address — kept verbatim so config files
    /// written by 0.7.x / 0.8.x builds keep working on the in-
    /// process path without an explicit migration. ParleqApp.main
    /// constructs `LocalASR` only when `asr.endpoint` equals this
    /// value; anything else routes through `ASRClient`'s HTTP path.
    public static let bundledASREndpoint = "http://127.0.0.1:8767/inference"

    public static let `default` = Config(
        hotkeyBinding: "option-right",
        // Auto-accept defaults to OFF (0 means "never auto-accept";
        // user must press Enter to paste). The design-doc default
        // was 6 seconds, but real-world testing showed it surprises
        // the user mid-read of a longer transcript. Opt-in via
        // ~/.parleq/config.json `ui.auto_accept_seconds = 6` if you
        // want the auto behavior back.
        autoAcceptSeconds: 0,
        acousticFeedback: true,
        asrMode: "default",
        llmMode: "default",
        llmModel: "gemini-2.5-flash",
        llmProvider: "gemini",
        awsRegion: "us-east-2",
        awsProfile: nil,
        awsAuthMode: "sso",
        vertexProject: "",
        vertexRegion: "us-central1",
        vertexAuthMode: "adc",
        vertexAnthropicRegion: "us-east5",
        azureResource: "",
        azureDeployment: "",
        azureApiVersion: "2025-04-01-preview",
        azureAuthMode: "apiKey",
        wizardCompleted: false,
        trailingSpace: true,
        noTrailingSpaceAppBundleIDs: [],
        continueOtherAudio: true,
        audioInputDeviceUID: "",
        asrEndpoint: bundledASREndpoint,
        customDictionary: [],
        contextModel: nil,
        telemetryEnabled: false,
        referenceWindowsEnabled: true,
        clipboardReferenceEnabled: true,
        imageReferenceEnabled: true,
        fileReferenceEnabled: true,
        customDictionaryEnabled: true,
        customModelEntryEnabled: true,
        managedKeys: []
    )

    public static func load() -> (config: Config, source: String) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".parleq/config.json")
        // Fresh-install / missing-file path: there is no JSON to parse, but
        // an MDM-managed Mac may still have keys in /Library/Managed
        // Preferences. Apply the overlay to Config.default so a freshly
        // enrolled device honours the policy on first launch.
        guard FileManager.default.fileExists(atPath: path) else {
            var c = Config.default
            applyManagedOverlay(&c)
            return (c, "defaults (no config file at \(path))")
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let parsed = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = parsed as? [String: Any] else {
                var c = Config.default
                applyManagedOverlay(&c)
                return (c, "defaults (config not a JSON object)")
            }
            var c = Config.default
            if let hotkey = dict["hotkey"] as? [String: Any],
               let binding = hotkey["binding"] as? String {
                c.hotkeyBinding = binding
            }
            if let ui = dict["ui"] as? [String: Any] {
                if let secs = ui["auto_accept_seconds"] as? NSNumber {
                    c.autoAcceptSeconds = TimeInterval(truncating: secs)
                }
                if let aucousticFeedback = ui["acoustic_feedback"] as? Bool {
                    c.acousticFeedback = aucousticFeedback
                }
            }
            if let asr = dict["asr"] as? [String: Any] {
                if let mode = asr["mode"] as? String {
                    c.asrMode = mode
                }
                if let endpoint = asr["endpoint"] as? String, !endpoint.isEmpty {
                    c.asrEndpoint = endpoint
                }
            }
            if let llm = dict["llm"] as? [String: Any] {
                if let mode = llm["mode"] as? String {
                    c.llmMode = mode
                }
                if let model = llm["model"] as? String {
                    c.llmModel = model
                }
                if let provider = llm["provider"] as? String, !provider.isEmpty {
                    c.llmProvider = provider
                }
            }
            if let aws = dict["aws"] as? [String: Any] {
                if let region = aws["region"] as? String, !region.isEmpty {
                    c.awsRegion = region
                }
                if let profile = aws["profile"] as? String {
                    let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
                    c.awsProfile = trimmed.isEmpty ? nil : trimmed
                }
                // Auth mode is "sso" or "static" (#21 step 3).
                // Anything unrecognized falls back to the default
                // ("sso") so a config written by a newer build that
                // adds e.g. "bedrock-api-key" doesn't strand an
                // older build with no working mode.
                if let mode = aws["auth_mode"] as? String,
                   ["sso", "static", "bedrockApiKey"].contains(mode) {
                    c.awsAuthMode = mode
                }
            }
            if let vertex = dict["vertex"] as? [String: Any] {
                if let project = vertex["project"] as? String {
                    c.vertexProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let region = vertex["region"] as? String, !region.isEmpty {
                    c.vertexRegion = region
                }
                if let mode = vertex["auth_mode"] as? String,
                   ["adc", "serviceAccount"].contains(mode) {
                    c.vertexAuthMode = mode
                }
                if let anthropicRegion = vertex["anthropic_region"] as? String,
                   !anthropicRegion.isEmpty {
                    c.vertexAnthropicRegion = anthropicRegion
                }
            }
            if let azure = dict["azure"] as? [String: Any] {
                if let resource = azure["resource"] as? String {
                    c.azureResource = resource.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let deployment = azure["deployment"] as? String {
                    c.azureDeployment = deployment.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let version = azure["api_version"] as? String, !version.isEmpty {
                    c.azureApiVersion = version
                }
                if let mode = azure["auth_mode"] as? String,
                   ["apiKey", "azureAd"].contains(mode) {
                    c.azureAuthMode = mode
                }
                // "family" key in on-disk configs is silently ignored —
                // AzureOpenAIProvider.family is now a computed property
                // derived from isOpenAIReasoningModel(model). Old configs
                // that carry the key decode fine; Swift ignores unknown
                // keys in manual JSONSerialization parsing.
            }
            if let wizard = dict["wizard"] as? [String: Any],
               let completed = wizard["completed"] as? Bool {
                c.wizardCompleted = completed
            }
            if let audio = dict["audio"] as? [String: Any] {
                if let cont = audio["continue_other_audio"] as? Bool {
                    c.continueOtherAudio = cont
                }
                if let uid = audio["input_device_uid"] as? String {
                    c.audioInputDeviceUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let paste = dict["paste"] as? [String: Any] {
                if let trailing = paste["trailing_space"] as? Bool {
                    c.trailingSpace = trailing
                }
                if let denylist = paste["no_trailing_space_apps"] as? [String] {
                    c.noTrailingSpaceAppBundleIDs = denylist
                }
            }
            if let dictionary = dict["dictionary"] as? [String: Any],
               let raw = dictionary["terms"] as? [Any] {
                // Accept either bare strings ("Parleq") or objects
                // ({"term": "Acme", "context": "...", "aliases": [...],
                // "biasing": "asrAndLLM" | "llmOnly"}). Hand-edited
                // configs can mix the two; the UI always writes
                // objects. Missing fields fall back to the
                // DictionaryEntry defaults — backwards-compatible
                // with configs written before aliases / biasing
                // shipped.
                c.customDictionary = raw.compactMap { item -> DictionaryEntry? in
                    if let str = item as? String {
                        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : DictionaryEntry(term: trimmed)
                    }
                    if let obj = item as? [String: Any],
                       let term = obj["term"] as? String {
                        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedTerm.isEmpty else { return nil }
                        let ctx = (obj["context"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let aliases: [String] = {
                            guard let raw = obj["aliases"] as? [String] else { return [] }
                            return raw
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        }()
                        let biasing: DictionaryBiasing = {
                            guard let raw = obj["biasing"] as? String,
                                  let parsed = DictionaryBiasing(rawValue: raw)
                            else { return .asrAndLLM }
                            return parsed
                        }()
                        return DictionaryEntry(
                            term: trimmedTerm,
                            context: (ctx?.isEmpty ?? true) ? nil : ctx,
                            aliases: aliases,
                            biasing: biasing
                        )
                    }
                    return nil
                }
            }
            if let telemetry = dict["telemetry"] as? [String: Any],
               let enabled = telemetry["enabled"] as? Bool {
                c.telemetryEnabled = enabled
            }
            // Context model (Phase 2): optional model tier for
            // reference-aware turns. nil (missing from old configs)
            // means "same as cleanup".
            if let contextModel = dict["context_model"] as? [String: Any],
               let provider = contextModel["provider"] as? String,
               let model = contextModel["model"] as? String {
                let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedProvider.isEmpty && !trimmedModel.isEmpty {
                    c.contextModel = ModelIdentifier(provider: trimmedProvider, model: trimmedModel)
                }
            }
            // Feature toggles (Phase 5). All default to true; missing
            // keys from older configs leave the feature enabled, which
            // is the safe forward-compat behavior.
            if let features = dict["features"] as? [String: Any] {
                if let v = features["reference_windows_enabled"] as? Bool {
                    c.referenceWindowsEnabled = v
                }
                if let v = features["clipboard_reference_enabled"] as? Bool {
                    c.clipboardReferenceEnabled = v
                }
                if let v = features["image_reference_enabled"] as? Bool {
                    c.imageReferenceEnabled = v
                }
                if let v = features["file_reference_enabled"] as? Bool {
                    c.fileReferenceEnabled = v
                }
                if let v = features["custom_dictionary_enabled"] as? Bool {
                    c.customDictionaryEnabled = v
                }
                if let v = features["custom_model_entry_enabled"] as? Bool {
                    c.customModelEntryEnabled = v
                }
            }
            // MDM overlay: check the seven managed-eligible Bool keys.
            // If MDM has forced a value, it overrides the user-stored
            // value and the key is added to managedKeys so Settings
            // can disable the relevant row. Config.save() skips managed
            // keys so re-loading without MDM falls back to the JSON value.
            applyManagedOverlay(&c)

            return (c, "loaded \(path)")
        } catch {
            var c = Config.default
            applyManagedOverlay(&c)
            return (c, "defaults (parse error: \(error))")
        }
    }

    /// Apply the MDM overlay (Phase 1 toggles + Phase 2 provider/model
    /// lockdown) to a Config instance. Runs on every return path of
    /// `load()` including the fresh-install (no-config-file) and
    /// parse-error fallbacks, so an MDM-managed Mac honours its policy
    /// regardless of whether the user has a config file yet.
    private static func applyManagedOverlay(_ c: inout Config) {
        var managedKeys = Set<String>()

        // Bool-typed managed keys (Phase 1 user-feature toggles). Inline
        // if-let blocks rather than a closure table because closures can't
        // capture an inout parameter.
        if let v = ManagedConfig.managedBool(forKey: "referenceWindowsEnabled") {
            c.referenceWindowsEnabled = v
            managedKeys.insert("referenceWindowsEnabled")
        }
        if let v = ManagedConfig.managedBool(forKey: "clipboardReferenceEnabled") {
            c.clipboardReferenceEnabled = v
            managedKeys.insert("clipboardReferenceEnabled")
        }
        if let v = ManagedConfig.managedBool(forKey: "imageReferenceEnabled") {
            c.imageReferenceEnabled = v
            managedKeys.insert("imageReferenceEnabled")
        }
        if let v = ManagedConfig.managedBool(forKey: "fileReferenceEnabled") {
            c.fileReferenceEnabled = v
            managedKeys.insert("fileReferenceEnabled")
        }
        if let v = ManagedConfig.managedBool(forKey: "customDictionaryEnabled") {
            c.customDictionaryEnabled = v
            managedKeys.insert("customDictionaryEnabled")
        }
        if let v = ManagedConfig.managedBool(forKey: "customModelEntryEnabled") {
            c.customModelEntryEnabled = v
            managedKeys.insert("customModelEntryEnabled")
        }
        // autoUpdateEnabled is Sparkle-side only; we still record managedKeys
        // so UpdatesView can show the lock indicator.
        if ManagedConfig.managedBool(forKey: "autoUpdateEnabled") != nil {
            managedKeys.insert("autoUpdateEnabled")
        }

        // sparkleUpdateFeedURL is Sparkle-side only (wired in ParleqApp.main
        // before startUpdater()). We validate the format here and record
        // managedKeys so the Compliance Audit dialog and UpdatesView caption
        // can surface it. Validation mirrors the main.swift accept/reject
        // criteria: must be a non-empty https:// URL.
        if let rawFeedURL = ManagedConfig.managedString(forKey: "sparkleUpdateFeedURL") {
            // Centralized strict validation (see ManagedConfig.validateFeedURL):
            // scheme=https, non-empty host, no userinfo, no query. The shared
            // validator keeps main.swift, Config, and the audit view in sync.
            if ManagedConfig.validateFeedURL(rawFeedURL) != nil {
                managedKeys.insert("sparkleUpdateFeedURL")
            } else {
                configLogStderr("[parleq] sparkleUpdateFeedURL: rejected managed value — must be a valid https:// URL with non-empty host, no embedded credentials, no query parameters; using Info.plist SUFeedURL instead")
            }
        }

        // loggingMode — forward-compatibility hook for compliance-sensitive
        // deployments. Parleq does not have a verbose-logging mode today; all
        // logging is length-only by convention. This key records the IT
        // department's preferred policy in managedKeys so the Compliance Audit
        // dialog can surface it. The gate for an eventual future verbose mode
        // is already wired: when a verbose-logging feature is added, check
        // managedKeys.contains("loggingMode") and honour the stored value.
        //
        // Recognized values: "lengthOnly" (default) and "verbose" (anticipated
        // future). Any other value is rejected — the key is NOT added to
        // managedKeys so the audit shows it as Default rather than Managed.
        if let rawLoggingMode = ManagedConfig.managedString(forKey: "loggingMode") {
            let recognized = ["lengthOnly", "verbose"]
            if recognized.contains(rawLoggingMode) {
                managedKeys.insert("loggingMode")
            } else {
                configLogStderr("[parleq] loggingMode: rejected unrecognized managed value '\(rawLoggingMode)' — recognized values are \(recognized.joined(separator: ", ")); treating as unmanaged")
            }
        }

        // MDM overlay — Phase 4 + Phase 5: auth-mode restrictions.
        //
        // staticApiKeysAllowed (Bool) — master switch for both the credential-
        // entry UI (Phase 4) and runtime provider construction (Phase 5).
        //
        // When false:
        //   • Every "Set … API key" / "Set … Service Account JSON" /
        //     "Set … Bearer Key" affordance is hidden (Phase 4, UI gate).
        //   • makeProvider in main.swift REFUSES to construct any provider
        //     whose currently-configured auth path is static-key-based
        //     (Phase 5, runtime gate). The single source of truth for which
        //     provider/authMode combinations are blocked is
        //     ManagedConfig.isProviderAuthPathBlocked(provider:authMode:).
        //
        // This block records the key in managedKeys so Settings and main.swift
        // can consult it. The write side (UI) and runtime side (provider
        // construction) both read managedKeys before proceeding.
        if ManagedConfig.managedBool(forKey: "staticApiKeysAllowed") != nil {
            managedKeys.insert("staticApiKeysAllowed")
        }

        // azureAuthMode (String) — pin Azure auth mode.
        // Recognized values: "apiKey" (default), "azureAd".
        // When managed, the Azure auth-mode picker is replaced by a fixed
        // disabled label, and the credential controls that don't match the
        // pinned mode are hidden. Unrecognized values are rejected (key NOT
        // added to managedKeys). The stored config value is also overridden
        // so the runtime provider sees the correct mode.
        if let rawAzureAuthMode = ManagedConfig.managedString(forKey: "azureAuthMode") {
            let recognized = ["apiKey", "azureAd"]
            if recognized.contains(rawAzureAuthMode) {
                c.azureAuthMode = rawAzureAuthMode
                managedKeys.insert("azureAuthMode")
            } else {
                configLogStderr("[parleq] azureAuthMode: rejected unrecognized managed value '\(rawAzureAuthMode)' — recognized values are \(recognized.joined(separator: ", ")); treating as unmanaged")
            }
        }

        // bedrockAuthMode (String) — pin Bedrock IAM auth mode.
        // Recognized values: "sso" (default), "static", "bedrockApiKey".
        //   - "sso": AWS CLI session via Soto's .sso() provider.
        //   - "static": IAM access keys stored in the macOS Keychain.
        //   - "bedrockApiKey": scoped Bedrock-only Bearer token.
        // When managed, the Bedrock auth-mode picker is replaced by a fixed
        // disabled label, and credential controls that don't match the pinned
        // mode are hidden. Unrecognized values rejected (key NOT added to
        // managedKeys). Note: bedrockAuthMode applies only to the Bedrock IAM
        // provider ("bedrock"); the Bedrock bearer provider ("bedrock-bearer")
        // uses bedrockApiKey auth exclusively and is covered by
        // staticApiKeysAllowed instead.
        if let rawBedrockAuthMode = ManagedConfig.managedString(forKey: "bedrockAuthMode") {
            let recognized = ["sso", "static", "bedrockApiKey"]
            if recognized.contains(rawBedrockAuthMode) {
                c.awsAuthMode = rawBedrockAuthMode
                managedKeys.insert("bedrockAuthMode")
            } else {
                configLogStderr("[parleq] bedrockAuthMode: rejected unrecognized managed value '\(rawBedrockAuthMode)' — recognized values are \(recognized.joined(separator: ", ")); treating as unmanaged")
            }
        }

            // MDM overlay — Phase 2: provider/model lockdown (8 string/array keys).
            //
            // Pin semantics (single String):
            //   cleanupProvider / cleanupModel force the value; the picker is
            //   disabled and shows only the pinned entry.
            //
            // Allowlist semantics ([String]):
            //   cleanupAllowedProviders / cleanupAllowedModels curate the picker
            //   to a subset; the user can still pick among them. If the currently
            //   stored value isn't in the allowed list it is reset to the first
            //   allowed entry.
            //
            // Precedence when both pin + allowlist are set for the same tier:
            //   The pin wins (it is strictly more restrictive). The allowlist is
            //   effectively ignored because the picker is disabled.

            // CLEANUP TIER — provider
            if let pinnedProvider = ManagedConfig.managedString(forKey: "cleanupProvider") {
                c.llmProvider = pinnedProvider
                managedKeys.insert("cleanupProvider")
            } else if let allowedProviders = ManagedConfig.managedStringArray(forKey: "cleanupAllowedProviders") {
                if !allowedProviders.contains(c.llmProvider), let first = allowedProviders.first {
                    configLogStderr("[parleq] cleanupAllowedProviders: stored provider '\(c.llmProvider)' not in allowed list; reset to '\(first)'")
                    c.llmProvider = first
                    // Also reset model to the new provider's default when snapping provider.
                    c.llmModel = ModelCatalog.defaultModel(forProvider: first)
                }
                managedKeys.insert("cleanupAllowedProviders")
            }

            // CLEANUP TIER — model (evaluated after provider snap so the
            // model catalog lookup uses the correct provider)
            if let pinnedModel = ManagedConfig.managedString(forKey: "cleanupModel") {
                c.llmModel = pinnedModel
                managedKeys.insert("cleanupModel")
            } else if let allowedModels = ManagedConfig.managedStringArray(forKey: "cleanupAllowedModels") {
                // Cross-provider safety: filter the allowlist to models
                // compatible with the current (possibly pinned/snapped)
                // provider, mirroring the picker's per-provider filter.
                // Without this, an admin pushing a cross-provider list
                // like ["gemini-2.5-flash", "gpt-4o"] without a provider
                // lockdown could end up with provider=gemini + model=gpt-4o.
                let compatibleAllowed = allowedModels.filter { id in
                    if ModelCatalog.isCanonical(provider: c.llmProvider, model: id) {
                        return true
                    }
                    let belongsElsewhere = ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"]
                        .filter { $0 != c.llmProvider }
                        .contains { ModelCatalog.isCanonical(provider: $0, model: id) }
                    return !belongsElsewhere  // bare custom IDs allowed
                }
                if compatibleAllowed.isEmpty, let firstAllowed = allowedModels.first {
                    // No allowed model is compatible with the current
                    // provider. Provider policy takes precedence over the
                    // model allowlist: if cleanupProvider is pinned (or
                    // restricted by an allowlist), we must NOT snap the
                    // provider — that would override a stricter policy with
                    // a looser one. The admin's combined policy is
                    // contradictory; respect the provider directive, reset
                    // the model to the provider's default, and log loudly
                    // so the admin can fix the conflict.
                    let providerPinnedOrAllowlisted = managedKeys.contains("cleanupProvider")
                        || managedKeys.contains("cleanupAllowedProviders")
                    if providerPinnedOrAllowlisted {
                        let original = c.llmModel
                        c.llmModel = ModelCatalog.defaultModel(forProvider: c.llmProvider)
                        configLogStderr("[parleq] cleanupAllowedModels: contradictory policy — no allowed model compatible with managed provider '\(c.llmProvider)'. Keeping provider per directive and resetting model '\(original)' to default '\(c.llmModel)'. Fix the policy: either expand cleanupAllowedModels to include a '\(c.llmProvider)' model, or change cleanupProvider.")
                    } else {
                        // Provider is user-controlled. Snap to the
                        // owning provider so the policy + user produce
                        // a valid runtime config.
                        let owningProvider = ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"]
                            .first { ModelCatalog.isCanonical(provider: $0, model: firstAllowed) }
                        if let owning = owningProvider {
                            configLogStderr("[parleq] cleanupAllowedModels: no allowed model compatible with provider '\(c.llmProvider)'; snapping provider to '\(owning)' which owns '\(firstAllowed)'")
                            c.llmProvider = owning
                            c.llmModel = firstAllowed
                        } else {
                            let original = c.llmModel
                            c.llmModel = ModelCatalog.defaultModel(forProvider: c.llmProvider)
                            configLogStderr("[parleq] cleanupAllowedModels: empty allowlist for provider '\(c.llmProvider)' with no identifiable owning provider; reset model '\(original)' to '\(c.llmModel)'")
                        }
                    }
                } else if !compatibleAllowed.contains(c.llmModel), let first = compatibleAllowed.first {
                    configLogStderr("[parleq] cleanupAllowedModels: stored model '\(c.llmModel)' not in allowed list (filtered to provider '\(c.llmProvider)'); reset to '\(first)'")
                    c.llmModel = first
                }
                managedKeys.insert("cleanupAllowedModels")
            }

            // CLEANUP TIER — pinned-provider model-mismatch sanity check.
            // When MDM pins `cleanupProvider` without an accompanying
            // `cleanupModel` pin (or allowlist), the stored model may belong
            // to a *different* provider (e.g. user had gemini/gemini-2.5-flash;
            // MDM pinned openai). That combination produces invalid wire
            // requests at runtime. Only reset when the model is canonical for
            // some OTHER provider — if it's not canonical for anyone, it may
            // be a legitimate custom value (dated snapshot, third-party
            // deployment) the admin is happy to keep.
            if managedKeys.contains("cleanupProvider"),
               !managedKeys.contains("cleanupModel"),
               !managedKeys.contains("cleanupAllowedModels") {
                let modelMatchesCurrentProvider = ModelCatalog.isCanonical(provider: c.llmProvider, model: c.llmModel)
                if !modelMatchesCurrentProvider {
                    let otherProviders = ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"]
                        .filter { $0 != c.llmProvider }
                    let modelBelongsElsewhere = otherProviders.contains {
                        ModelCatalog.isCanonical(provider: $0, model: c.llmModel)
                    }
                    if modelBelongsElsewhere {
                        let original = c.llmModel
                        c.llmModel = ModelCatalog.defaultModel(forProvider: c.llmProvider)
                        configLogStderr("[parleq] cleanupProvider pin: stored model '\(original)' belongs to a different provider; reset to '\(c.llmModel)' for pinned provider '\(c.llmProvider)'")
                    }
                }
            }

            // CONTEXT TIER — provider
            let currentContextProvider = c.contextModel?.provider ?? c.llmProvider
            let currentContextModel    = c.contextModel?.model    ?? c.llmModel
            var contextProvider = currentContextProvider
            var contextModelName = currentContextModel

            if let pinnedProvider = ManagedConfig.managedString(forKey: "contextProvider") {
                contextProvider = pinnedProvider
                managedKeys.insert("contextProvider")
            } else if let allowedProviders = ManagedConfig.managedStringArray(forKey: "contextAllowedProviders") {
                if !allowedProviders.contains(contextProvider), let first = allowedProviders.first {
                    configLogStderr("[parleq] contextAllowedProviders: stored provider '\(contextProvider)' not in allowed list; reset to '\(first)'")
                    contextProvider = first
                    contextModelName = ModelCatalog.defaultModel(forProvider: first)
                }
                managedKeys.insert("contextAllowedProviders")
            }

            // CONTEXT TIER — model
            if let pinnedModel = ManagedConfig.managedString(forKey: "contextModel") {
                contextModelName = pinnedModel
                managedKeys.insert("contextModel")
            } else if let allowedModels = ManagedConfig.managedStringArray(forKey: "contextAllowedModels") {
                // Same cross-provider filter as the cleanup tier.
                let compatibleAllowed = allowedModels.filter { id in
                    if ModelCatalog.isCanonical(provider: contextProvider, model: id) {
                        return true
                    }
                    let belongsElsewhere = ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"]
                        .filter { $0 != contextProvider }
                        .contains { ModelCatalog.isCanonical(provider: $0, model: id) }
                    return !belongsElsewhere
                }
                if compatibleAllowed.isEmpty, let firstAllowed = allowedModels.first {
                    // Same precedence rule as cleanup tier: when context
                    // provider is itself managed, the provider directive
                    // wins. Don't snap to a different provider that would
                    // override the stricter policy.
                    let providerPinnedOrAllowlisted = managedKeys.contains("contextProvider")
                        || managedKeys.contains("contextAllowedProviders")
                    if providerPinnedOrAllowlisted {
                        let original = contextModelName
                        contextModelName = ModelCatalog.defaultModel(forProvider: contextProvider)
                        configLogStderr("[parleq] contextAllowedModels: contradictory policy — no allowed model compatible with managed provider '\(contextProvider)'. Keeping provider per directive and resetting model '\(original)' to default '\(contextModelName)'. Fix the policy: either expand contextAllowedModels to include a '\(contextProvider)' model, or change contextProvider.")
                    } else {
                        let owningProvider = ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"]
                            .first { ModelCatalog.isCanonical(provider: $0, model: firstAllowed) }
                        if let owning = owningProvider {
                            configLogStderr("[parleq] contextAllowedModels: no allowed model compatible with provider '\(contextProvider)'; snapping provider to '\(owning)' which owns '\(firstAllowed)'")
                            contextProvider = owning
                            contextModelName = firstAllowed
                        } else {
                            let original = contextModelName
                            contextModelName = ModelCatalog.defaultModel(forProvider: contextProvider)
                            configLogStderr("[parleq] contextAllowedModels: empty allowlist for provider '\(contextProvider)' with no identifiable owning provider; reset model '\(original)' to '\(contextModelName)'")
                        }
                    }
                } else if !compatibleAllowed.contains(contextModelName), let first = compatibleAllowed.first {
                    configLogStderr("[parleq] contextAllowedModels: stored model '\(contextModelName)' not in allowed list (filtered to provider '\(contextProvider)'); reset to '\(first)'")
                    contextModelName = first
                }
                managedKeys.insert("contextAllowedModels")
            }

            // CONTEXT TIER — pinned-provider model-mismatch sanity check
            // (mirror of the cleanup-tier check above). Only when context
            // provider was pinned without an accompanying model directive.
            if managedKeys.contains("contextProvider"),
               !managedKeys.contains("contextModel"),
               !managedKeys.contains("contextAllowedModels") {
                let modelMatchesCurrentProvider = ModelCatalog.isCanonical(provider: contextProvider, model: contextModelName)
                if !modelMatchesCurrentProvider {
                    let otherProviders = ["gemini", "vertex", "bedrock", "bedrock-bearer", "azure", "openai"]
                        .filter { $0 != contextProvider }
                    let modelBelongsElsewhere = otherProviders.contains {
                        ModelCatalog.isCanonical(provider: $0, model: contextModelName)
                    }
                    if modelBelongsElsewhere {
                        let original = contextModelName
                        contextModelName = ModelCatalog.defaultModel(forProvider: contextProvider)
                        configLogStderr("[parleq] contextProvider pin: stored model '\(original)' belongs to a different provider; reset to '\(contextModelName)' for pinned provider '\(contextProvider)'")
                    }
                }
            }

            // Rebuild contextModel from the (possibly MDM-snapped) tier values.
            // Preserve nil (= "same as cleanup") only when no context-tier MDM
            // key is active and the original config.contextModel was nil.
            let contextTierManaged = managedKeys.contains("contextProvider")
                || managedKeys.contains("contextAllowedProviders")
                || managedKeys.contains("contextModel")
                || managedKeys.contains("contextAllowedModels")
            if contextTierManaged {
                let cleanupId = ModelIdentifier(provider: c.llmProvider, model: c.llmModel)
                let contextId = ModelIdentifier(provider: contextProvider, model: contextModelName)
                c.contextModel = (contextId == cleanupId) ? nil : contextId
            }

            c.managedKeys = managedKeys

            // Defense-in-depth: when customModelEntryEnabled is off, a
            // non-canonical model name (whether MDM-pushed, manually
            // edited into config.json, or left over from before the
            // toggle flipped) must not be used at runtime. Reset to the
            // provider's curated default and log the rejection so the
            // user or admin can diagnose it via tail ~/.parleq/app.log.
            if !c.customModelEntryEnabled {
                // MDM-pinned or allowlisted model IDs are authorized by the
                // admin and bypass the customModelEntryEnabled scrub — the
                // admin explicitly set them, so we shouldn't second-guess
                // even if the value isn't in our curated catalog (could be a
                // dated snapshot, a deployment-specific model ID, etc.).
                let cleanupModelManaged = managedKeys.contains("cleanupModel")
                    || managedKeys.contains("cleanupAllowedModels")
                if !cleanupModelManaged,
                   !ModelCatalog.isCanonical(provider: c.llmProvider, model: c.llmModel) {
                    let original = c.llmModel
                    c.llmModel = ModelCatalog.defaultModel(forProvider: c.llmProvider)
                    configLogStderr("[parleq] customModelEntryEnabled=false: rejected non-canonical cleanup model '\(original)' (provider=\(c.llmProvider)); reset to '\(c.llmModel)'")
                }
                let contextModelManaged = managedKeys.contains("contextModel")
                    || managedKeys.contains("contextAllowedModels")
                if let ctx = c.contextModel,
                   !contextModelManaged,
                   !ModelCatalog.isCanonical(provider: ctx.provider, model: ctx.model) {
                    let original = ctx.model
                    let replacement = ModelCatalog.defaultModel(forProvider: ctx.provider)
                    c.contextModel = ModelIdentifier(provider: ctx.provider, model: replacement)
                    configLogStderr("[parleq] customModelEntryEnabled=false: rejected non-canonical context model '\(original)' (provider=\(ctx.provider)); reset to '\(replacement)'")
                }
            }
    }

    /// Write the config back to ~/.parleq/config.json. Used by the
    /// Settings window when the user changes a value. Creates the
    /// .parleq directory if needed. The on-disk schema mirrors the
    /// load() format (nested by section), so a manually-edited file
    /// and a Settings-edited file look identical.
    public static func save(_ config: Config) throws {
        let homeDir = NSHomeDirectory() as NSString
        let dir = homeDir.appendingPathComponent(".parleq")
        let path = (dir as NSString).appendingPathComponent("config.json")
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        // Read the existing on-disk config first so MDM-managed
        // provider/model values don't clobber the user's pre-MDM
        // fallback preference. When a key is managed, we write the
        // existing on-disk value (or skip writing if absent) rather
        // than the effective in-memory value — removing the MDM
        // profile later restores the user's prior choice. Bool toggles
        // use a different pattern (just skip writing managed keys);
        // for string fields we explicitly preserve the prior value so
        // the field stays present in the JSON for round-trip parity.
        let existingDict: [String: Any] = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dict = parsed as? [String: Any]
            else {
                return [:]
            }
            return dict
        }()
        let existingLLM = (existingDict["llm"] as? [String: Any]) ?? [:]
        let existingContextModel = (existingDict["context_model"] as? [String: Any]) ?? [:]

        // Effective values to write: preserve on-disk ONLY when the
        // corresponding key is PINNED (single value forced) — the user
        // can't change it, so writing the effective MDM value would
        // clobber their pre-MDM fallback. Under ALLOWLIST the user CAN
        // pick among the allowed values, and that choice must persist
        // (otherwise the picker would silently snap back on every restart).
        let providerPinned = config.managedKeys.contains("cleanupProvider")
        let modelPinned    = config.managedKeys.contains("cleanupModel")
        let modelAllowlist = config.managedKeys.contains("cleanupAllowedModels")
        let ctxProviderPinned = config.managedKeys.contains("contextProvider")
        let ctxModelPinned    = config.managedKeys.contains("contextModel")
        let ctxModelAllowlist = config.managedKeys.contains("contextAllowedModels")
        let ctxTierPinned = ctxProviderPinned || ctxModelPinned

        let llmProviderToWrite: String = providerPinned
            ? ((existingLLM["provider"] as? String) ?? config.llmProvider)
            : config.llmProvider
        // Model preservation logic:
        // - modelPinned → preserve on-disk (user can't change anyway).
        // - providerPinned + model totally unmanaged → preserve on-disk
        //   (pair-as-unit; user has no agency over model and the
        //   in-memory value is a runtime auto-snap, not their choice).
        // - providerPinned + model has ALLOWLIST → write user's choice
        //   (user actively picks within the allowed set; that choice
        //   must persist). This is the case I missed initially —
        //   under provider pin + model allowlist, my preservation was
        //   silently clobbering the user's picker choice.
        let preserveModelOnDisk = modelPinned || (providerPinned && !modelAllowlist)
        let llmModelToWrite: String = preserveModelOnDisk
            ? ((existingLLM["model"] as? String) ?? config.llmModel)
            : config.llmModel
        // Feature-toggle values: for unmanaged keys, write the current
        // in-memory value. For MDM-managed keys, carry forward the
        // existing on-disk value (if any) so removing the MDM profile
        // restores the user's pre-MDM fallback. Symmetric with the
        // provider/model preservation above.
        let existingFeatures = (existingDict["features"] as? [String: Any]) ?? [:]
        var featuresDict: [String: Any] = [:]
        // referenceWindowsEnabled
        if !config.managedKeys.contains("referenceWindowsEnabled") {
            featuresDict["reference_windows_enabled"] = config.referenceWindowsEnabled
        } else if let existing = existingFeatures["reference_windows_enabled"] {
            featuresDict["reference_windows_enabled"] = existing
        }
        // clipboardReferenceEnabled
        if !config.managedKeys.contains("clipboardReferenceEnabled") {
            featuresDict["clipboard_reference_enabled"] = config.clipboardReferenceEnabled
        } else if let existing = existingFeatures["clipboard_reference_enabled"] {
            featuresDict["clipboard_reference_enabled"] = existing
        }
        // imageReferenceEnabled
        if !config.managedKeys.contains("imageReferenceEnabled") {
            featuresDict["image_reference_enabled"] = config.imageReferenceEnabled
        } else if let existing = existingFeatures["image_reference_enabled"] {
            featuresDict["image_reference_enabled"] = existing
        }
        // fileReferenceEnabled
        if !config.managedKeys.contains("fileReferenceEnabled") {
            featuresDict["file_reference_enabled"] = config.fileReferenceEnabled
        } else if let existing = existingFeatures["file_reference_enabled"] {
            featuresDict["file_reference_enabled"] = existing
        }
        // customDictionaryEnabled
        if !config.managedKeys.contains("customDictionaryEnabled") {
            featuresDict["custom_dictionary_enabled"] = config.customDictionaryEnabled
        } else if let existing = existingFeatures["custom_dictionary_enabled"] {
            featuresDict["custom_dictionary_enabled"] = existing
        }
        // customModelEntryEnabled
        if !config.managedKeys.contains("customModelEntryEnabled") {
            featuresDict["custom_model_entry_enabled"] = config.customModelEntryEnabled
        } else if let existing = existingFeatures["custom_model_entry_enabled"] {
            featuresDict["custom_model_entry_enabled"] = existing
        }

        let dict: [String: Any] = [
            "hotkey": [
                "binding": config.hotkeyBinding,
            ],
            "ui": [
                "auto_accept_seconds": config.autoAcceptSeconds,
                "acoustic_feedback": config.acousticFeedback,
            ],
            "audio": [
                "continue_other_audio": config.continueOtherAudio,
                "input_device_uid": config.audioInputDeviceUID,
            ],
            "asr": [
                "mode": config.asrMode,
                "endpoint": config.asrEndpoint,
            ],
            "llm": [
                "mode": config.llmMode,
                "provider": llmProviderToWrite,
                "model": llmModelToWrite,
            ],
            "aws": [
                "region": config.awsRegion,
                "profile": config.awsProfile ?? "",
                // Phase 5: when bedrockAuthMode is managed, preserve the
                // existing on-disk auth_mode so removing the MDM profile
                // restores the user's pre-MDM choice. Symmetric with the
                // provider/model preservation logic above.
                "auth_mode": config.managedKeys.contains("bedrockAuthMode")
                    ? ((existingDict["aws"] as? [String: Any])?["auth_mode"] as? String ?? config.awsAuthMode)
                    : config.awsAuthMode,
            ],
            "vertex": [
                "project": config.vertexProject,
                "region": config.vertexRegion,
                "auth_mode": config.vertexAuthMode,
                "anthropic_region": config.vertexAnthropicRegion,
            ],
            "azure": [
                "resource": config.azureResource,
                "deployment": config.azureDeployment,
                "api_version": config.azureApiVersion,
                // Phase 5: preserve on-disk azure.auth_mode when
                // azureAuthMode is managed (same rationale as aws.auth_mode).
                "auth_mode": config.managedKeys.contains("azureAuthMode")
                    ? ((existingDict["azure"] as? [String: Any])?["auth_mode"] as? String ?? config.azureAuthMode)
                    : config.azureAuthMode,
            ],
            "wizard": [
                "completed": config.wizardCompleted,
            ],
            "paste": [
                "trailing_space": config.trailingSpace,
                "no_trailing_space_apps": config.noTrailingSpaceAppBundleIDs,
            ],
            "dictionary": [
                "terms": config.customDictionary.map { entry -> [String: Any] in
                    var obj: [String: Any] = ["term": entry.term]
                    if let ctx = entry.context, !ctx.isEmpty {
                        obj["context"] = ctx
                    }
                    if !entry.aliases.isEmpty {
                        obj["aliases"] = entry.aliases
                    }
                    if entry.biasing != .asrAndLLM {
                        // Skip the field when it's the default —
                        // keeps existing on-disk configs visually
                        // unchanged for users who never touch the
                        // biasing toggle.
                        obj["biasing"] = entry.biasing.rawValue
                    }
                    return obj
                },
            ],
            "telemetry": [
                "enabled": config.telemetryEnabled,
            ],
            "context_model": {
                // Preserve on-disk context_model only when context tier is
                // PINNED (single value forced). Under allowlist the user can
                // pick among allowed values so the chosen value must persist.
                // Per-field preservation: provider and model are tracked
                // separately, so a pinned-provider-only case writes the user's
                // current model alongside the preserved provider.
                if ctxTierPinned {
                    let existingProvider = (existingContextModel["provider"] as? String) ?? ""
                    let existingModel    = (existingContextModel["model"] as? String) ?? ""
                    // Provider preservation: pinned → preserve on-disk.
                    let provider = ctxProviderPinned && !existingProvider.isEmpty
                        ? existingProvider
                        : (config.contextModel?.provider ?? "")
                    // Model preservation: pinned → preserve. Provider pinned
                    // + model totally unmanaged → preserve (pair-as-unit).
                    // Provider pinned + model allowlist → write user's
                    // current choice (allowlist lets user pick within set).
                    let preserveModel = ctxModelPinned
                        || (ctxProviderPinned && !ctxModelAllowlist)
                    let model = preserveModel && !existingModel.isEmpty
                        ? existingModel
                        : (config.contextModel?.model ?? "")
                    if !provider.isEmpty || !model.isEmpty {
                        return ["provider": provider, "model": model] as Any
                    }
                    return NSNull() as Any
                }
                if let model = config.contextModel {
                    return [
                        "provider": model.provider,
                        "model": model.model,
                    ] as Any
                }
                return NSNull() as Any
            }(),
            "features": featuresDict,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// File-scoped logger matching the `logStderr` pattern used in
// Permissions.swift, LocalASR.swift, and similar files. Prefixed
// differently to avoid a symbol collision if the two files are ever
// in the same module link unit — the `config` prefix makes the origin
// clear in grep output as well.
private func configLogStderr(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

extension Config {
    /// Resolve which model should service a dictation given the
    /// current state. Override (set by the in-overlay ModelPicker)
    /// beats Context, which beats Cleanup. nil overrides fall
    /// through.
    public func modelForInvocation(
        hasReferences: Bool,
        override: ModelIdentifier? = nil
    ) -> ModelIdentifier {
        if let override { return override }
        if hasReferences, let context = contextModel { return context }
        return ModelIdentifier(provider: llmProvider, model: llmModel)
    }
}
