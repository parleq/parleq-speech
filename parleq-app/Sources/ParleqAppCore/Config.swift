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
    /// Azure underlying-model family. "standard" (gpt-4o, gpt-4,
    /// gpt-3.5-turbo) uses `max_tokens` + arbitrary `temperature`;
    /// "reasoning" (gpt-5, o-series) uses `max_completion_tokens`
    /// and refuses non-default temperature. Declared explicitly
    /// because Azure routes by deployment name (user-chosen,
    /// arbitrary), so we can't infer the family from anything
    /// Parleq sees on the wire — the user has to tell us.
    public var azureFamily: String
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
        azureResource: "",
        azureDeployment: "",
        azureApiVersion: "2025-04-01-preview",
        azureAuthMode: "apiKey",
        azureFamily: "standard",
        wizardCompleted: false,
        trailingSpace: true,
        noTrailingSpaceAppBundleIDs: [],
        continueOtherAudio: true,
        audioInputDeviceUID: "",
        asrEndpoint: bundledASREndpoint,
        customDictionary: [],
        contextModel: nil,
        telemetryEnabled: false
    )

    public static func load() -> (config: Config, source: String) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".parleq/config.json")
        guard FileManager.default.fileExists(atPath: path) else {
            return (.default, "defaults (no config file at \(path))")
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let parsed = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dict = parsed as? [String: Any] else {
                return (.default, "defaults (config not a JSON object)")
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
                if let family = azure["family"] as? String,
                   ["standard", "reasoning"].contains(family) {
                    c.azureFamily = family
                } else {
                    // Backwards-compat: configs written before the
                    // family field existed inferred reasoning vs
                    // standard from the llmModel string. Keep that
                    // behavior on first load so users who already
                    // had gpt-5-mini etc. wired up don't see their
                    // setup silently regress to standard mode.
                    let lower = c.llmModel.lowercased()
                    if lower.hasPrefix("gpt-5") || lower.hasPrefix("o1")
                        || lower.hasPrefix("o3") || lower.hasPrefix("o4")
                        || lower.hasPrefix("o5") {
                        c.azureFamily = "reasoning"
                    }
                }
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
            return (c, "loaded \(path)")
        } catch {
            return (.default, "defaults (parse error: \(error))")
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
                "provider": config.llmProvider,
                "model": config.llmModel,
            ],
            "aws": [
                "region": config.awsRegion,
                "profile": config.awsProfile ?? "",
                "auth_mode": config.awsAuthMode,
            ],
            "vertex": [
                "project": config.vertexProject,
                "region": config.vertexRegion,
                "auth_mode": config.vertexAuthMode,
            ],
            "azure": [
                "resource": config.azureResource,
                "deployment": config.azureDeployment,
                "api_version": config.azureApiVersion,
                "auth_mode": config.azureAuthMode,
                "family": config.azureFamily,
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
            "context_model": config.contextModel.map { model in
                [
                    "provider": model.provider,
                    "model": model.model,
                ]
            } as Any? ?? NSNull(),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
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
