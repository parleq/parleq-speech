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

/// Provenance of a dictionary entry. `user` = hand-authored in
/// Settings (the only kind before "learn from corrections"). `learned`
/// = auto-applied by the learning analyzer; visibly distinguishable in
/// the dictionary UI, revertible, and never silently overwritten by a
/// later learned proposal touching the same term.
public enum DictionarySource: String, Sendable, Equatable, Codable {
    case user
    case learned
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
    public var source: DictionarySource

    public init(
        term: String,
        context: String? = nil,
        aliases: [String] = [],
        biasing: DictionaryBiasing = .asrAndLLM,
        source: DictionarySource = .user
    ) {
        self.term = term
        self.context = context
        self.aliases = aliases
        self.biasing = biasing
        self.source = source
    }
}

/// A user-defined one-tap transform: `name` is the overlay chip label,
/// `prompt` is the generalized refine instruction it runs ("Rewrite the
/// text to be as concise as possible…"). Invoked two ways with the same
/// stored prompt: tapped manually in the overlay (a refine pass on the
/// shown text) or assigned as a per-app default (folded into that app's
/// cleanup prompt — see SystemPrompts.transformHint).
public struct TransformPreset: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var prompt: String

    public init(id: String = UUID().uuidString, name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}

public struct Config: Sendable {
    public var hotkeyBinding: String
    public var autoAcceptSeconds: TimeInterval
    /// Delay in milliseconds after hotkey-down before the dictation
    /// overlay appears for a fresh capture (#56). Default 200. Also
    /// the threshold for the hold-hotkey+P "Show Parleq" gesture —
    /// HotkeyListener reads the same value so the two cues stay in
    /// lockstep ("hold until the overlay appears, then press P").
    /// Clamped to 0...2000 on load.
    public var overlayShowDelayMs: Int
    public var acousticFeedback: Bool
    /// Show a near-transparent floating "recording pulse" during quick
    /// (double-tap-hold) dictation, which otherwise shows no overlay —
    /// the visual analog of the start sound for audio-off users.
    /// Default true.
    public var recordingPulse: Bool
    /// Per-cue sound choices for acoustic feedback. Each is a macOS
    /// system-sound name (e.g. "Tink", "Bottle") or "Off" to silence
    /// just that cue. Both are gated together by `acousticFeedback`.
    /// Inline defaults so the explicit init / Config.default need no
    /// change; only load/save plumbing is added.
    public var startSound: String = "Tink"
    public var endSound: String = "Bottle"
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
    /// User-defined transform presets (overlay chips). Empty by default —
    /// the feature is inert until the user creates one.
    public var transformPresets: [TransformPreset]
    /// Per-app default preset assignments: target app bundle ID → preset
    /// id. When a dictation's paste target matches, that preset's prompt
    /// is folded into the cleanup pass (one LLM call) and the overlay
    /// shows "Styled with <name> · Undo".
    public var presetAppDefaults: [String: String]
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

    // 0.14.0 PR 6 (#221) — transcript-history retention.
    //
    // Both default to nil (unlimited; the in-memory invariant
    // bounds the storage to the running process, so unlimited is
    // a sane default). MDM admins set one or both via the
    // managed keys transcriptHistoryMaxEntries +
    // transcriptHistoryRetentionHours; whichever triggers first
    // drops entries from TranscriptHistory. 0 means "disable
    // history entirely" — a zero-retention deployment lever for
    // highly-regulated fleets.

    /// Maximum count of in-memory dictation history entries.
    /// nil = unlimited. 0 = disable history entirely. Values
    /// must be non-negative; MDM Int parsing rejects negatives.
    public var transcriptHistoryMaxEntries: Int?

    /// Maximum age (in hours) of in-memory dictation history
    /// entries. Entries older than this drop on a periodic
    /// sweep. nil = unlimited. 0 = disable history entirely.
    public var transcriptHistoryRetentionHours: Int?

    /// Opt-in master switch for "learn from corrections" (#TBD). Off by
    /// default: enabling consents to holding correction snippets in memory
    /// (in-session only, never written to disk) AND sending them to the
    /// configured cleanup LLM during periodic off-path analysis. Re-read
    /// per utterance at the capture site.
    public var learnFromCorrectionsEnabled: Bool
    /// Count cap on the correction journal. nil = unlimited (default).
    /// 0 = disable journal entirely (compliance lever; nothing written,
    /// existing file removed) — same semantics as the transcript-history
    /// retention knobs.
    public var learnedCorrectionsMaxEntries: Int?
    /// Age cap (hours) on the correction journal. nil = unlimited. 0 =
    /// disable entirely.
    public var learnedCorrectionsRetentionHours: Int?

    /// Master switch for transform presets. No Settings toggle (the
    /// feature is inert with no presets defined); exists so MDM can pin
    /// it off fleet-wide — chips hidden, per-app defaults not applied.
    public var transformPresetsEnabled: Bool

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
        overlayShowDelayMs: 200,
        acousticFeedback: true,
        recordingPulse: true,
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
        transformPresets: [],
        presetAppDefaults: [:],
        contextModel: nil,
        telemetryEnabled: false,
        referenceWindowsEnabled: true,
        clipboardReferenceEnabled: true,
        imageReferenceEnabled: true,
        fileReferenceEnabled: true,
        customDictionaryEnabled: true,
        customModelEntryEnabled: true,
        transcriptHistoryMaxEntries: nil,
        transcriptHistoryRetentionHours: nil,
        learnFromCorrectionsEnabled: false,
        learnedCorrectionsMaxEntries: nil,
        learnedCorrectionsRetentionHours: nil,
        transformPresetsEnabled: true,
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
            // Delegate all field parsing to the single-source-of-truth
            // seam. load() owns only file I/O, error/fallback handling,
            // and the MDM managed-overlay block that runs after parsing.
            var c = Config.parseForTesting(dict)
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
        // 0.14.0 PR 6 (#221) — transcript-history retention.
        // managedInt rejects negative values; 0 is meaningful and
        // means "disable history entirely". A non-Int (e.g. a
        // fat-fingered String that doesn't parse) leaves the
        // config field at its user-set value AND doesn't mark
        // the key as managed — same fail-open posture as other
        // managed keys with invalid payloads.
        if let v = ManagedConfig.managedInt(forKey: "transcriptHistoryMaxEntries") {
            c.transcriptHistoryMaxEntries = v
            managedKeys.insert("transcriptHistoryMaxEntries")
        }
        if let v = ManagedConfig.managedInt(forKey: "transcriptHistoryRetentionHours") {
            c.transcriptHistoryRetentionHours = v
            managedKeys.insert("transcriptHistoryRetentionHours")
        }
        if let v = ManagedConfig.managedBool(forKey: "learnFromCorrectionsEnabled") {
            c.learnFromCorrectionsEnabled = v
            managedKeys.insert("learnFromCorrectionsEnabled")
        }
        if let v = ManagedConfig.managedInt(forKey: "learnedCorrectionsMaxEntries") {
            c.learnedCorrectionsMaxEntries = v
            managedKeys.insert("learnedCorrectionsMaxEntries")
        }
        if let v = ManagedConfig.managedInt(forKey: "learnedCorrectionsRetentionHours") {
            c.learnedCorrectionsRetentionHours = v
            managedKeys.insert("learnedCorrectionsRetentionHours")
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

        // MDM overlay — Phase 7: destination pins. Close the
        // "MDM pins provider+model+auth-mode but the user retargets
        // the data at a personal cloud account or attacker ASR
        // server" exfiltration class. Pin-only semantics (no
        // allowlist) — orgs typically have ONE Vertex project, ONE
        // Azure resource, etc.; allowlist support can be added
        // later if a deployment asks for it.
        //
        // vertexAuthMode (String) — symmetric with azureAuthMode + bedrockAuthMode.
        // Recognized values: "adc" (default), "serviceAccount".
        // Unrecognized values rejected (key NOT added to
        // managedKeys) so a typo doesn't silently lock the user out.
        if let rawVertexAuthMode = ManagedConfig.managedString(forKey: "vertexAuthMode") {
            let recognized = ["adc", "serviceAccount"]
            if recognized.contains(rawVertexAuthMode) {
                c.vertexAuthMode = rawVertexAuthMode
                managedKeys.insert("vertexAuthMode")
            } else {
                configLogStderr("[parleq] vertexAuthMode: rejected unrecognized managed value '\(rawVertexAuthMode)' — recognized values are \(recognized.joined(separator: ", ")); treating as unmanaged")
            }
        }

        // #196 option 2: auto-coerce vertexAuthMode to "adc" when the
        // stored SA path would be blocked at runtime. Without this, the
        // UI shows the fixed "gcloud (ADC)" label + ADC instructions
        // but the runtime keeps reading config.vertexAuthMode = "serviceAccount"
        // and hits BlockedProvider — dictation fails even though the
        // card says ADC is the path. After this coercion:
        //   - Runtime uses ADC (matches the UI message)
        //   - "Auth disabled by org" badge no longer fires (effective
        //     mode isn't blocked anymore — isProviderAuthPathBlocked
        //     for vertex+adc is false)
        //   - Card body's ADC instructions become actionable
        //
        // We add vertexAuthMode to managedKeys so save() preserves the
        // user's on-disk "serviceAccount" choice via the standard
        // preservation pattern. Removing the MDM profile restores SA
        // selection on the next launch.
        //
        // Skip when vertexAuthMode is ALREADY explicitly managed — an
        // admin deliberately pinning to "serviceAccount" alongside
        // staticApiKeysAllowed=false is a contradictory admin config
        // we honor by leaving SA in place. Runtime then fails and the
        // admin fixes their policy.
        if !managedKeys.contains("vertexAuthMode")
           && ManagedConfig.managedBool(forKey: "staticApiKeysAllowed") == false
           && c.vertexAuthMode == "serviceAccount" {
            c.vertexAuthMode = "adc"
            managedKeys.insert("vertexAuthMode")
            configLogStderr("[parleq] vertexAuthMode: auto-coerced from 'serviceAccount' to 'adc' (staticApiKeysAllowed=false blocks the SA path). On-disk value preserved by save() — removing the MDM profile restores your stored choice.")
        }

        // asrEndpoint (String) — pin the ASR HTTP destination.
        // The unmanaged code path accepts any http(s) URL so a user
        // can plug in their own local Sherpa / faster-whisper server
        // (raw audio stays on the user's box). When IT wants to
        // enforce "audio MUST go to bundled FluidAudio or our
        // corporate Whisper at https://asr.corp.example", they pin
        // here. Validation requires https (the unmanaged http://
        // local-dev affordance does not extend to MDM pushes —
        // pushing audio off-box must travel over TLS) or the bundled
        // sentinel verbatim.
        if let rawASREndpoint = ManagedConfig.managedString(forKey: "asrEndpoint") {
            if let validated = ManagedConfig.validateASREndpoint(rawASREndpoint) {
                c.asrEndpoint = validated
                managedKeys.insert("asrEndpoint")
            } else {
                configLogStderr("[parleq] asrEndpoint: rejected managed value — must be either the bundled-FluidAudio sentinel (\(Config.bundledASREndpoint)) or an https:// URL with a non-empty host, no embedded credentials, and no query parameters; using user/default value instead")
            }
        }

        // Cloud-account destination pins. Each closes one variant of
        // "use the allowed provider but route to my personal tenant
        // / account / region." vertexProject + azureResource +
        // azureDeployment are non-empty pin-required; awsProfile
        // accepts an empty pin (meaning "use AWS_PROFILE env var or
        // default profile"). Region identifiers (vertexRegion,
        // vertexAnthropicRegion, awsRegion) accept any non-empty
        // value — region naming is loosely structured and we don't
        // want to lag behind new regions the cloud provider rolls
        // out.
        if let raw = ManagedConfig.managedString(forKey: "vertexProject") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                c.vertexProject = trimmed
                managedKeys.insert("vertexProject")
            } else {
                configLogStderr("[parleq] vertexProject: rejected managed value — empty string is not a valid GCP project ID; treating as unmanaged")
            }
        }
        if let raw = ManagedConfig.managedString(forKey: "vertexRegion") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                c.vertexRegion = trimmed
                managedKeys.insert("vertexRegion")
            } else {
                configLogStderr("[parleq] vertexRegion: rejected managed value — empty string is not a valid region; treating as unmanaged")
            }
        }
        if let raw = ManagedConfig.managedString(forKey: "vertexAnthropicRegion") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                c.vertexAnthropicRegion = trimmed
                managedKeys.insert("vertexAnthropicRegion")
            } else {
                configLogStderr("[parleq] vertexAnthropicRegion: rejected managed value — empty string is not a valid region; treating as unmanaged")
            }
        }
        if let raw = ManagedConfig.managedString(forKey: "awsRegion") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                c.awsRegion = trimmed
                managedKeys.insert("awsRegion")
            } else {
                configLogStderr("[parleq] awsRegion: rejected managed value — empty string is not a valid region; treating as unmanaged")
            }
        }
        if let raw = ManagedConfig.managedString(forKey: "awsProfile") {
            // awsProfile may legitimately be empty (means "use
            // AWS_PROFILE env var or default"). Accept any string;
            // store nil for empty so the runtime code path consults
            // the env-var fallback.
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            c.awsProfile = trimmed.isEmpty ? nil : trimmed
            managedKeys.insert("awsProfile")
        }
        if let raw = ManagedConfig.managedString(forKey: "azureResource") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                c.azureResource = trimmed
                managedKeys.insert("azureResource")
            } else {
                configLogStderr("[parleq] azureResource: rejected managed value — empty string is not a valid Azure OpenAI resource name; treating as unmanaged")
            }
        }
        if let raw = ManagedConfig.managedString(forKey: "azureDeployment") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                c.azureDeployment = trimmed
                managedKeys.insert("azureDeployment")
            } else {
                configLogStderr("[parleq] azureDeployment: rejected managed value — empty string is not a valid deployment name; treating as unmanaged")
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

    // MARK: - Test seams

    /// Parse a Config from a raw JSON dictionary (the same logic used
    /// by `load()`, but without filesystem I/O or MDM overlay).
    /// Internal so tests can call it via `@testable import`.
    static func parseForTesting(_ parsed: [String: Any]) -> Config {
        var c = Config.default
        if let hotkey = parsed["hotkey"] as? [String: Any],
           let binding = hotkey["binding"] as? String {
            c.hotkeyBinding = binding
        }
        if let ui = parsed["ui"] as? [String: Any] {
            if let secs = ui["auto_accept_seconds"] as? NSNumber {
                c.autoAcceptSeconds = TimeInterval(truncating: secs)
            }
            if let delay = ui["overlay_show_delay_ms"] as? NSNumber {
                c.overlayShowDelayMs = min(2000, max(0, delay.intValue))
            }
            if let v = ui["acoustic_feedback"] as? Bool { c.acousticFeedback = v }
            if let v = ui["recording_pulse"] as? Bool { c.recordingPulse = v }
            if let v = ui["start_sound"] as? String, !v.isEmpty { c.startSound = v }
            if let v = ui["end_sound"] as? String, !v.isEmpty { c.endSound = v }
        }
        if let asr = parsed["asr"] as? [String: Any] {
            if let v = asr["mode"] as? String { c.asrMode = v }
            if let v = asr["endpoint"] as? String, !v.isEmpty { c.asrEndpoint = v }
        }
        if let llm = parsed["llm"] as? [String: Any] {
            if let v = llm["mode"] as? String { c.llmMode = v }
            if let v = llm["model"] as? String { c.llmModel = v }
            if let v = llm["provider"] as? String, !v.isEmpty { c.llmProvider = v }
        }
        if let aws = parsed["aws"] as? [String: Any] {
            if let v = aws["region"] as? String, !v.isEmpty { c.awsRegion = v }
            if let v = aws["profile"] as? String {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                c.awsProfile = t.isEmpty ? nil : t
            }
            if let v = aws["auth_mode"] as? String,
               ["sso", "static", "bedrockApiKey"].contains(v) { c.awsAuthMode = v }
        }
        if let vertex = parsed["vertex"] as? [String: Any] {
            if let v = vertex["project"] as? String {
                c.vertexProject = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let v = vertex["region"] as? String, !v.isEmpty { c.vertexRegion = v }
            if let v = vertex["auth_mode"] as? String,
               ["adc", "serviceAccount"].contains(v) { c.vertexAuthMode = v }
            if let v = vertex["anthropic_region"] as? String, !v.isEmpty {
                c.vertexAnthropicRegion = v
            }
        }
        if let azure = parsed["azure"] as? [String: Any] {
            if let v = azure["resource"] as? String {
                c.azureResource = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let v = azure["deployment"] as? String {
                c.azureDeployment = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let v = azure["api_version"] as? String, !v.isEmpty { c.azureApiVersion = v }
            if let v = azure["auth_mode"] as? String,
               ["apiKey", "azureAd"].contains(v) { c.azureAuthMode = v }
        }
        if let wizard = parsed["wizard"] as? [String: Any],
           let completed = wizard["completed"] as? Bool {
            c.wizardCompleted = completed
        }
        if let audio = parsed["audio"] as? [String: Any] {
            if let v = audio["continue_other_audio"] as? Bool { c.continueOtherAudio = v }
            if let v = audio["input_device_uid"] as? String {
                c.audioInputDeviceUID = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let paste = parsed["paste"] as? [String: Any] {
            if let v = paste["trailing_space"] as? Bool { c.trailingSpace = v }
            if let v = paste["no_trailing_space_apps"] as? [String] {
                c.noTrailingSpaceAppBundleIDs = v
            }
        }
        if let dictionary = parsed["dictionary"] as? [String: Any],
           let raw = dictionary["terms"] as? [Any] {
            c.customDictionary = raw.compactMap { item -> DictionaryEntry? in
                if let str = item as? String {
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : DictionaryEntry(term: trimmed)
                }
                if let obj = item as? [String: Any], let term = obj["term"] as? String {
                    let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedTerm.isEmpty else { return nil }
                    let ctx = (obj["context"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let aliases: [String] = {
                        guard let raw = obj["aliases"] as? [String] else { return [] }
                        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }()
                    let biasing: DictionaryBiasing = {
                        guard let raw = obj["biasing"] as? String,
                              let parsed = DictionaryBiasing(rawValue: raw)
                        else { return .asrAndLLM }
                        return parsed
                    }()
                    let source: DictionarySource = {
                        guard let raw = obj["source"] as? String,
                              let parsed = DictionarySource(rawValue: raw)
                        else { return .user }
                        return parsed
                    }()
                    return DictionaryEntry(
                        term: trimmedTerm,
                        context: (ctx?.isEmpty ?? true) ? nil : ctx,
                        aliases: aliases,
                        biasing: biasing,
                        source: source
                    )
                }
                return nil
            }
        }
        if let telemetry = parsed["telemetry"] as? [String: Any],
           let enabled = telemetry["enabled"] as? Bool {
            c.telemetryEnabled = enabled
        }
        if let contextModel = parsed["context_model"] as? [String: Any],
           let provider = contextModel["provider"] as? String,
           let model = contextModel["model"] as? String {
            let tp = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            let tm = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tp.isEmpty && !tm.isEmpty {
                c.contextModel = ModelIdentifier(provider: tp, model: tm)
            }
        }
        if let features = parsed["features"] as? [String: Any] {
            if let v = features["reference_windows_enabled"] as? Bool { c.referenceWindowsEnabled = v }
            if let v = features["clipboard_reference_enabled"] as? Bool { c.clipboardReferenceEnabled = v }
            if let v = features["image_reference_enabled"] as? Bool { c.imageReferenceEnabled = v }
            if let v = features["file_reference_enabled"] as? Bool { c.fileReferenceEnabled = v }
            if let v = features["custom_dictionary_enabled"] as? Bool { c.customDictionaryEnabled = v }
            if let v = features["custom_model_entry_enabled"] as? Bool { c.customModelEntryEnabled = v }
            if let v = features["transcript_history_max_entries"] as? Int, v >= 0 {
                c.transcriptHistoryMaxEntries = v
            }
            if let v = features["transcript_history_retention_hours"] as? Int, v >= 0 {
                c.transcriptHistoryRetentionHours = v
            }
            if let v = features["learn_from_corrections_enabled"] as? Bool {
                c.learnFromCorrectionsEnabled = v
            }
            if let v = features["learned_corrections_max_entries"] as? Int, v >= 0 {
                c.learnedCorrectionsMaxEntries = v
            }
            if let v = features["learned_corrections_retention_hours"] as? Int, v >= 0 {
                c.learnedCorrectionsRetentionHours = v
            }
            if let v = features["transform_presets_enabled"] as? Bool {
                c.transformPresetsEnabled = v
            }
        }
        // Transform presets — top-level "presets" array.
        if let raw = parsed["presets"] as? [Any] {
            c.transformPresets = raw.compactMap { item -> TransformPreset? in
                guard let obj = item as? [String: Any],
                      let id = obj["id"] as? String,
                      !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let name = (obj["name"] as? String)?
                          .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                      let prompt = (obj["prompt"] as? String)?
                          .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty
                else { return nil }
                return TransformPreset(id: id.trimmingCharacters(in: .whitespacesAndNewlines), name: name, prompt: prompt)
            }
        }
        // Per-app default mapping — top-level "preset_app_defaults".
        if let raw = parsed["preset_app_defaults"] as? [String: Any] {
            c.presetAppDefaults = raw.compactMapValues { $0 as? String }
                .filter { !$0.key.isEmpty && !$0.value.isEmpty }
        }
        return c
    }

    /// Serialize a Config to a JSON dictionary (the same structure that
    /// `save()` writes, minus filesystem I/O and MDM preservation).
    /// Internal so tests can call it via `@testable import`.
    static func serializeForTesting(_ config: Config) -> [String: Any] {
        var featuresDict: [String: Any] = [
            "reference_windows_enabled": config.referenceWindowsEnabled,
            "clipboard_reference_enabled": config.clipboardReferenceEnabled,
            "image_reference_enabled": config.imageReferenceEnabled,
            "file_reference_enabled": config.fileReferenceEnabled,
            "custom_dictionary_enabled": config.customDictionaryEnabled,
            "custom_model_entry_enabled": config.customModelEntryEnabled,
            "learn_from_corrections_enabled": config.learnFromCorrectionsEnabled,
            "transform_presets_enabled": config.transformPresetsEnabled,
        ]
        if let v = config.transcriptHistoryMaxEntries { featuresDict["transcript_history_max_entries"] = v }
        if let v = config.transcriptHistoryRetentionHours { featuresDict["transcript_history_retention_hours"] = v }
        if let v = config.learnedCorrectionsMaxEntries { featuresDict["learned_corrections_max_entries"] = v }
        if let v = config.learnedCorrectionsRetentionHours { featuresDict["learned_corrections_retention_hours"] = v }

        var dict: [String: Any] = [
            "hotkey": ["binding": config.hotkeyBinding],
            "ui": [
                "auto_accept_seconds": config.autoAcceptSeconds,
                "overlay_show_delay_ms": config.overlayShowDelayMs,
                "acoustic_feedback": config.acousticFeedback,
                "recording_pulse": config.recordingPulse,
                "start_sound": config.startSound,
                "end_sound": config.endSound,
            ],
            "audio": [
                "continue_other_audio": config.continueOtherAudio,
                "input_device_uid": config.audioInputDeviceUID,
            ],
            "asr": ["mode": config.asrMode, "endpoint": config.asrEndpoint],
            "llm": ["mode": config.llmMode, "provider": config.llmProvider, "model": config.llmModel],
            "aws": ["region": config.awsRegion, "profile": config.awsProfile ?? "", "auth_mode": config.awsAuthMode],
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
                "auth_mode": config.azureAuthMode,
            ],
            "wizard": ["completed": config.wizardCompleted],
            "paste": [
                "trailing_space": config.trailingSpace,
                "no_trailing_space_apps": config.noTrailingSpaceAppBundleIDs,
            ],
            "dictionary": [
                "terms": config.customDictionary.map { entry -> [String: Any] in
                    var obj: [String: Any] = ["term": entry.term]
                    if let ctx = entry.context, !ctx.isEmpty { obj["context"] = ctx }
                    if !entry.aliases.isEmpty { obj["aliases"] = entry.aliases }
                    if entry.biasing != .asrAndLLM { obj["biasing"] = entry.biasing.rawValue }
                    if entry.source != .user { obj["source"] = entry.source.rawValue }
                    return obj
                },
            ],
            "telemetry": ["enabled": config.telemetryEnabled],
            "features": featuresDict,
        ]
        if let model = config.contextModel {
            dict["context_model"] = ["provider": model.provider, "model": model.model]
        }
        if !config.transformPresets.isEmpty {
            dict["presets"] = config.transformPresets.map { preset -> [String: Any] in
                ["id": preset.id, "name": preset.name, "prompt": preset.prompt]
            }
        }
        if !config.presetAppDefaults.isEmpty {
            dict["preset_app_defaults"] = config.presetAppDefaults
        }
        return dict
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
        // 0.14.0 PR 6 (#221) — transcript-history retention. Same
        // pattern: write the user-set value when unmanaged, preserve
        // the on-disk existing value when MDM is overriding (so
        // removing the MDM profile restores the user's pre-MDM
        // setting). nil = unlimited, written as no key in JSON.
        if !config.managedKeys.contains("transcriptHistoryMaxEntries") {
            if let v = config.transcriptHistoryMaxEntries {
                featuresDict["transcript_history_max_entries"] = v
            } else {
                featuresDict.removeValue(forKey: "transcript_history_max_entries")
            }
        } else if let existing = existingFeatures["transcript_history_max_entries"] {
            featuresDict["transcript_history_max_entries"] = existing
        }
        if !config.managedKeys.contains("transcriptHistoryRetentionHours") {
            if let v = config.transcriptHistoryRetentionHours {
                featuresDict["transcript_history_retention_hours"] = v
            } else {
                featuresDict.removeValue(forKey: "transcript_history_retention_hours")
            }
        } else if let existing = existingFeatures["transcript_history_retention_hours"] {
            featuresDict["transcript_history_retention_hours"] = existing
        }
        if !config.managedKeys.contains("learnFromCorrectionsEnabled") {
            featuresDict["learn_from_corrections_enabled"] = config.learnFromCorrectionsEnabled
        } else if let existing = existingFeatures["learn_from_corrections_enabled"] {
            featuresDict["learn_from_corrections_enabled"] = existing
        }
        if !config.managedKeys.contains("learnedCorrectionsMaxEntries") {
            if let v = config.learnedCorrectionsMaxEntries {
                featuresDict["learned_corrections_max_entries"] = v
            } else {
                featuresDict.removeValue(forKey: "learned_corrections_max_entries")
            }
        } else if let existing = existingFeatures["learned_corrections_max_entries"] {
            featuresDict["learned_corrections_max_entries"] = existing
        }
        if !config.managedKeys.contains("learnedCorrectionsRetentionHours") {
            if let v = config.learnedCorrectionsRetentionHours {
                featuresDict["learned_corrections_retention_hours"] = v
            } else {
                featuresDict.removeValue(forKey: "learned_corrections_retention_hours")
            }
        } else if let existing = existingFeatures["learned_corrections_retention_hours"] {
            featuresDict["learned_corrections_retention_hours"] = existing
        }
        if !config.managedKeys.contains("transformPresetsEnabled") {
            featuresDict["transform_presets_enabled"] = config.transformPresetsEnabled
        } else if let existing = existingFeatures["transform_presets_enabled"] {
            featuresDict["transform_presets_enabled"] = existing
        }

        // Phase 7 destination-pin preservation. When a destination
        // pin is active, the user can't change the field in
        // Settings, so writing the effective MDM value would clobber
        // their pre-MDM fallback. We preserve the on-disk value
        // (when present) so removing the MDM profile restores their
        // earlier choice — exact same rationale as the cleanup-tier
        // provider/model preservation above.
        let existingASR = (existingDict["asr"] as? [String: Any]) ?? [:]
        let existingAWS = (existingDict["aws"] as? [String: Any]) ?? [:]
        let existingVertex = (existingDict["vertex"] as? [String: Any]) ?? [:]
        let existingAzure = (existingDict["azure"] as? [String: Any]) ?? [:]

        let asrEndpointToWrite: String = config.managedKeys.contains("asrEndpoint")
            ? ((existingASR["endpoint"] as? String) ?? config.asrEndpoint)
            : config.asrEndpoint
        let awsRegionToWrite: String = config.managedKeys.contains("awsRegion")
            ? ((existingAWS["region"] as? String) ?? config.awsRegion)
            : config.awsRegion
        let awsProfileToWrite: String = config.managedKeys.contains("awsProfile")
            ? ((existingAWS["profile"] as? String) ?? (config.awsProfile ?? ""))
            : (config.awsProfile ?? "")
        let vertexProjectToWrite: String = config.managedKeys.contains("vertexProject")
            ? ((existingVertex["project"] as? String) ?? config.vertexProject)
            : config.vertexProject
        let vertexRegionToWrite: String = config.managedKeys.contains("vertexRegion")
            ? ((existingVertex["region"] as? String) ?? config.vertexRegion)
            : config.vertexRegion
        let vertexAnthropicRegionToWrite: String = config.managedKeys.contains("vertexAnthropicRegion")
            ? ((existingVertex["anthropic_region"] as? String) ?? config.vertexAnthropicRegion)
            : config.vertexAnthropicRegion
        let vertexAuthModeToWrite: String = config.managedKeys.contains("vertexAuthMode")
            ? ((existingVertex["auth_mode"] as? String) ?? config.vertexAuthMode)
            : config.vertexAuthMode
        let azureResourceToWrite: String = config.managedKeys.contains("azureResource")
            ? ((existingAzure["resource"] as? String) ?? config.azureResource)
            : config.azureResource
        let azureDeploymentToWrite: String = config.managedKeys.contains("azureDeployment")
            ? ((existingAzure["deployment"] as? String) ?? config.azureDeployment)
            : config.azureDeployment

        // Start from the single-source-of-truth base serialization, then
        // apply save()'s extra semantics on top: MDM managed-key
        // preservation and the context_model CTX-pinning logic.
        var dict = Config.serializeForTesting(config)

        // Patch ASR, LLM, AWS, Vertex, Azure sections with the
        // managed-override values computed above. These overwrite the
        // naive per-field values that serializeForTesting put in.
        dict["asr"] = [
            "mode": config.asrMode,
            "endpoint": asrEndpointToWrite,
        ]
        dict["llm"] = [
            "mode": config.llmMode,
            "provider": llmProviderToWrite,
            "model": llmModelToWrite,
        ]
        dict["aws"] = [
            "region": awsRegionToWrite,
            "profile": awsProfileToWrite,
            // Phase 5: when bedrockAuthMode is managed, preserve the
            // existing on-disk auth_mode so removing the MDM profile
            // restores the user's pre-MDM choice. Symmetric with the
            // provider/model preservation logic above.
            "auth_mode": config.managedKeys.contains("bedrockAuthMode")
                ? ((existingAWS["auth_mode"] as? String) ?? config.awsAuthMode)
                : config.awsAuthMode,
        ]
        dict["vertex"] = [
            "project": vertexProjectToWrite,
            "region": vertexRegionToWrite,
            "auth_mode": vertexAuthModeToWrite,
            "anthropic_region": vertexAnthropicRegionToWrite,
        ]
        dict["azure"] = [
            "resource": azureResourceToWrite,
            "deployment": azureDeploymentToWrite,
            "api_version": config.azureApiVersion,
            // Phase 5: preserve on-disk azure.auth_mode when
            // azureAuthMode is managed (same rationale as aws.auth_mode).
            "auth_mode": config.managedKeys.contains("azureAuthMode")
                ? ((existingAzure["auth_mode"] as? String) ?? config.azureAuthMode)
                : config.azureAuthMode,
        ]

        // Patch features with the MDM-aware featuresDict computed above.
        dict["features"] = featuresDict

        // Patch context_model: preserve on-disk when context tier is
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
                dict["context_model"] = ["provider": provider, "model": model]
            } else {
                dict.removeValue(forKey: "context_model")
            }
        } else if config.contextModel == nil {
            // serializeForTesting omits context_model when nil; keep
            // it absent (remove in case it was set by a prior code path).
            dict.removeValue(forKey: "context_model")
        }
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
        // Cleanup disabled ("none") is a GLOBAL off switch. The Context
        // tier is a sub-feature of cleanup, so when the user has opted
        // out of cleanup entirely, reference-aware turns must NOT route
        // to a (possibly still-configured) context_model — otherwise
        // "skip cleanup, paste raw" would silently keep sending the
        // transcript + reference content to the context provider.
        // Returning the cleanup identifier makes the call path resolve
        // to the nil cleanup provider and paste the raw ASR transcript.
        if llmProvider == "none" {
            return ModelIdentifier(provider: llmProvider, model: llmModel)
        }
        if hasReferences, let context = contextModel { return context }
        return ModelIdentifier(provider: llmProvider, model: llmModel)
    }
}
