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
//     "hotkey":    { "binding": "option-right",
//                    "gestures": { "double-tap-hold": "quick",       // quick|continuous|dictate|disabled
//                                  "double-tap-release": "continuous" } },
//     "ui":        { "auto_accept_seconds": 6,
//                    "acoustic_feedback": true },
//     "audio":     { "continue_other_audio": true },
//     "asr":       { "mode": "default" },
//     "llm":       { "mode": "default",
//                    // CLEANUP config. Derives cleanupType: "none"→Raw,
//                    // "concord"→Instant (on-device), generative→Polished.
//                    "provider": "gemini",
//                    "model": "gemini-2.5-flash",
//                    // GLOBAL refinement TYPE: "raw"|"instant"|"polished".
//                    "refinement": "polished",
//                    // Refinement's Polished provider (used when refinement
//                    // == "polished" and cleanup isn't itself that provider).
//                    // With llm.provider (if generative) it forms the ONE
//                    // shared Polished provider (Config.polishedProvider).
//                    "refine": { "provider": "vertex", "model": "…" },
//                    // Advanced request tuning (#55) — config-file
//                    // only, no Settings UI, omit-when-default. All
//                    // values clamped on load; restart required:
//                    "tuning": {
//                      // null = built-in 0/128 split (Flash/Pro);
//                      // when set, sent verbatim (Pro rejects < 128):
//                      "thinking_budget": null,        // 0...32768
//                      // raised from the historical 1024 so long
//                      // dictations don't truncate at ~750 words:
//                      "max_output_tokens": 2048,      // 64...65536
//                      "temperature": 0,               // 0...2
//                      "ttft_deadline_seconds": [5.5, 8.0],
//                      "ttft_deadline_thinking_seconds": [25.0],
//                      "request_timeout_seconds": 60   // 5...300
//                    },
//                    // On-device cleanup tier (local provider). Omit
//                    // when every field is default (omit-when-default):
//                    "local": {
//                      // Model residency policy once loaded:
//                      //   "auto"  — unload after idle_unload_minutes
//                      //             (default; threshold varies by RAM tier)
//                      //   "keep"  — keep loaded between dictations
//                      //   "idle"  — always unload immediately after use
//                      "residency": "auto",
//                      // Override idle-unload timeout (minutes). null
//                      // means "use the RAM-tier default" (3 min on
//                      // cautioned / 30 min on comfortable).
//                      "idle_unload_minutes": null,
//                      // Allow local provider on < 12 GB RAM machines
//                      // despite thrash risk. Default false.
//                      "allow_unsupported_ram": false
//                    } },
//     "aws":       { "region": "us-east-2",
//                    "profile": "work",
//                    // Enterprise OIDC federation (omit-when-default):
//                    "role_arn": "arn:aws:iam::1:role/Parleq",
//                    "session_duration_seconds": 3600 },
//     "vertex":    { "project": "my-proj", "region": "us-central1",
//                    // Enterprise OIDC federation (omit-when-default):
//                    "workforce_provider":
//                      "locations/global/workforcePools/p/providers/v" },
//     // Enterprise OIDC federation — shared corporate sign-in. The
//     // whole section is omitted when every field is default; the AWS
//     // leg (aws.role_arn + aws.auth_mode="oidc") and the GCP leg
//     // (vertex.workforce_provider + vertex.auth_mode="oidcFederation")
//     // both ride this single sign-in:
//     "oidc":      { "issuer": "https://acme.okta.com",
//                    "client_id": "0oa1",
//                    "scopes": ["openid","profile","email","offline_access"],
//                    "ephemeral_browser": false,
//                    // generic-OP knobs (omit-when-default):
//                    // redirect_uri: custom scheme (ASWebAuthenticationSession)
//                    // OR http loopback (Google "Desktop app"; port ignored,
//                    // ephemeral 127.0.0.1 listener answers the callback).
//                    "redirect_uri": "parleq-auth://oidc/callback",
//                    "extra_auth_params": {} },
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
//                        "spoken_forms": ["acme finance app"],
//                        "biasing": "llmOnly" }
//                    ] },
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
        // Provider-level tiers carry no model name (empty `model` field) — the
        // on-device Concord "Lightweight" corrector is the main one. Fall back
        // to a human provider name so the ModelBadge / picker row never renders
        // blank (which read as a nameless checked item + an icon-only badge).
        if model.trimmingCharacters(in: .whitespaces).isEmpty {
            switch provider.lowercased() {
            case "concord": return "Lightweight"
            case "local":   return "On-device"
            case "none", "": return "None"
            default:        return provider.prefix(1).uppercased() + provider.dropFirst()
            }
        }
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
/// receive this entry; defaults to ASR + LLM. `spokenForms` are
/// distinctive MULTI-WORD "say-as" phrases the on-device corrector
/// (Concord) matches as a whole run and rewrites to the canonical
/// term, consuming the extra disambiguator words (e.g. spoken form
/// "iterm terminal" → "open item terminal" becomes "open iTerm");
/// Concord ignores phrases with fewer than two words (those belong
/// in `aliases`).
public struct DictionaryEntry: Sendable, Equatable {
    public var term: String
    public var context: String?
    public var aliases: [String]
    public var spokenForms: [String]
    public var biasing: DictionaryBiasing
    public var source: DictionarySource

    public init(
        term: String,
        context: String? = nil,
        aliases: [String] = [],
        spokenForms: [String] = [],
        biasing: DictionaryBiasing = .asrAndLLM,
        source: DictionarySource = .user
    ) {
        self.term = term
        self.context = context
        self.aliases = aliases
        self.spokenForms = spokenForms
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

// MARK: - On-device (local) LLM cleanup tier types

/// Model residency policy once the local model is loaded.
/// - `auto`: Unload after the RAM-tier idle-unload timeout (default).
/// - `keep`: Keep the model loaded between dictations.
/// - `idle`: Always unload immediately after each use.
public enum LocalResidency: String, Codable, Sendable {
    case auto, keep, idle
}

/// Machine RAM tier, used to gate and tune the local cleanup provider.
/// Based on physical memory reported by `ProcessInfo.processInfo.physicalMemory`.
public enum RAMTier: Equatable, Sendable {
    /// < 12 GB: local card not selectable (wired ~6 GB = thrash risk).
    case unsupported
    /// 12 GB – <24 GB: allowed with strong caution and aggressive idle-unload.
    case cautioned
    /// >= 24 GB: comfortable fit for the ~6 GB resident model.
    case comfortable

    public static func forPhysicalMemory(_ bytes: UInt64) -> RAMTier {
        let gb = Double(bytes) / Double(1 << 30)
        if gb < 12 { return .unsupported }
        if gb < 24 { return .cautioned }
        return .comfortable
    }

    public static var current: RAMTier {
        forPhysicalMemory(ProcessInfo.processInfo.physicalMemory)
    }
}

/// Static defaults for the on-device cleanup tier. Single source of truth
/// referenced by LocalModelStore, ResidencyManager, and the setup wizard.
public enum LocalModelDefaults {
    public static let checkpoint = "mlx-community/gemma-4-E4B-it-qat-4bit"
    public static let approxDownloadGB = 4.2
    public static let approxResidentGB = 6.0
    public static let idleUnloadMinutesCautioned = 3
    public static let idleUnloadMinutesComfortable = 30
    public static let maxTokens = 1024
    public static let contextLength = 8192
    /// LRU capacity for the on-device KV system-prefix cache (Task 9). Small:
    /// per-app preset transforms vary the prefix suffix so a handful of distinct
    /// prefixes can be live, but the working set is tiny and each entry holds
    /// GPU memory (the full system-prompt KV state).
    public static let prefixCacheCapacity = 4
    /// Upper bound (bytes) on MLX's retained Metal free-buffer pool while the
    /// model stays loaded. MLX keeps freed GPU scratch buffers in a reuse pool;
    /// left unbounded it balloons to ~4 GB above the ~5.5 GB E4B weights floor
    /// during a generation peak and stays there until idle-unload, so
    /// phys_footprint (GPU buffers count against it on unified memory) reads
    /// ~10 GB in Activity Monitor — alarming to users and security reviewers
    /// even though the true hot working set is a few GB. Capping the pool keeps
    /// loaded footprint near the honest weights floor (~6–7 GB) without
    /// unloading. NOT zero: a tiny pool forces every scratch buffer back to
    /// Metal each generation (allocation churn → latency); a moderate cap keeps
    /// enough warm buffers for back-to-back dictations. Distinct from
    /// idle-unload + `clearCache()`, which fully releases the pool when the
    /// model is dropped; this only bounds it while loaded.
    ///
    /// Value chosen from a measured sweep (heavy ~1.8k-prompt-token cleanup
    /// workload, Gemma 4 E4B QAT): peak phys_footprint was ~9.9 GB uncapped,
    /// ~7.5 GB at 1024 MB, ~7.0 GB at 512 MB. 1024 MB keeps ~80% of the
    /// footprint win while its TTFT tracked the uncapped baseline in both cold
    /// and hot runs (512 MB showed a small, possibly-thermal TTFT bump), so it
    /// is the choice that best preserves the "stay fast" invariant. Override at
    /// runtime with `PARLEQ_GPU_CACHE_MB` (MB) to re-tune without a rebuild.
    public static let gpuCacheLimitBytes = 1024 * 1024 * 1024
    public static let modelsDirectory: URL = {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            // Extreme edge (corrupt user dir): Application Support is
            // unavailable. Don't crash the whole app at launch — fall back to a
            // temp-dir path. The on-device model just won't persist across this
            // session, but every other code path (cloud providers, dictation)
            // keeps working.
            configLogStderr("[config] WARNING: Application Support directory unavailable — falling back to temporary directory for on-device model path")
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Parleq/models", isDirectory: true)
        }
        return base.appendingPathComponent("Parleq/models", isDirectory: true)
    }()
}

/// How Parleq's cleanup pipeline is routed for a given paste target.
/// The only genuinely new routing primitive is `.instant` (a forced
/// on-device Concord override); `.polished` is today's pipeline unchanged
/// and `.raw` is the existing `none` (paste as transcribed).
public enum TargetMode: String, Codable, Sendable {
    case instant
    case polished
    case raw
}

/// The resolved per-app cleanup behavior: a `TargetMode` plus, for the
/// `.polished` mode only, an optional tone preset id. (`presetID` is
/// meaningless for `.instant`/`.raw`.)
public struct AppBehavior: Equatable, Codable, Sendable {
    public var mode: TargetMode
    public var presetID: String?

    public init(mode: TargetMode, presetID: String? = nil) {
        self.mode = mode
        self.presetID = presetID
    }
}

public struct Config: Sendable {
    public var hotkeyBinding: String
    /// #84: raw `hotkey.gestures` map (gesture key → action token) for the
    /// configurable double-tap entry gestures. Empty = all defaults. Parse via
    /// `hotkeyGestureMap`.
    public var hotkeyGestures: [String: String]
    /// Resolved gesture→action map (defaults applied for unset/unknown entries).
    public var hotkeyGestureMap: GestureMap { GestureMap.parse(hotkeyGestures) }
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
    ///   - "concord" — "Lightweight (on-device)" 2nd-pass corrector
    ///     (the private Concord engine: deterministic numbers/compounds
    ///     + confidence-gated dictionary correction). In-process, ~0 ms,
    ///     no network boundary, no auth, no model download.
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

    // MARK: - Enterprise OIDC federation (Company Account)
    //
    // A single corporate sign-in (ASWebAuthenticationSession against the
    // org's OIDC IdP) that federates into the configured cloud provider:
    // AWS via AssumeRoleWithWebIdentity, GCP via Workforce Identity. The
    // fields below are all org-config strings safe to keep in
    // ~/.parleq/config.json; the identity snapshot (name/email) and the
    // refresh token stay Keychain-only and never touch this struct.

    /// OIDC issuer URL (e.g. "https://acme.okta.com"). Empty when the
    /// Company Account feature isn't configured. Drives OIDC discovery.
    public var oidcIssuer: String
    /// OIDC public client ID registered with the IdP for Parleq.
    public var oidcClientID: String
    /// Scopes requested at sign-in. Defaults include offline_access so a
    /// refresh token is issued for silent re-authentication.
    public var oidcScopes: [String]
    /// When true, the sign-in web session uses an ephemeral browser
    /// (no shared cookies / persistent session). Default false.
    public var oidcEphemeralBrowser: Bool
    /// OAuth redirect URI used in the authorization request and the
    /// token-exchange `redirect_uri`. Two shapes are accepted:
    ///   - A custom scheme (`parleq-auth://oidc/callback`, or a Google native
    ///     client's reversed-client-ID scheme) — the browser callback scheme is
    ///     derived from this and intercepted by ASWebAuthenticationSession.
    ///   - An http:// LOOPBACK redirect (`http://127.0.0.1[:port]/path`) —
    ///     Google's "Desktop app" client guidance. The configured PORT is
    ///     IGNORED (a transient 127.0.0.1-only listener binds an ephemeral port
    ///     at sign-in time); the PATH is preserved.
    /// Default the fixed custom scheme `parleq-auth://oidc/callback`. Parse
    /// rejects https:// and non-loopback http:// (keeps the default).
    public var oidcRedirectURI: String
    /// Extra query parameters appended to the authorization request (e.g.
    /// `access_type=offline`, `prompt=consent` to force a refresh token on
    /// every interactive sign-in). Reserved OIDC params are ignored. Default
    /// empty.
    public var oidcExtraAuthParams: [String: String]
    /// AWS IAM role ARN assumed via AssumeRoleWithWebIdentity when
    /// `awsAuthMode == "oidc"`. Empty disables the AWS federation leg.
    public var awsRoleArn: String
    /// Requested STS session duration in seconds for the federated AWS
    /// credentials. Default 3600 (1 h). Parse clamps to STS's
    /// 900...43200 (15 min … 12 h) window.
    public var awsSessionDurationSeconds: Int
    /// GCP Workforce Identity provider resource name
    /// ("locations/global/workforcePools/<pool>/providers/<provider>")
    /// used when `vertexAuthMode == "oidcFederation"`. Empty disables
    /// the GCP federation leg.
    public var vertexWorkforceProvider: String

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

    /// Per-app cleanup MODE overrides: target app bundle ID → `AppBehavior`.
    /// In v1 this stores the per-app MODE (`.instant`/`.polished`/`.raw`);
    /// the per-app *preset* remains in `presetAppDefaults` (the single source
    /// of truth that the Settings UI / LearnedStore mutate), resolved via
    /// `presetForApp`, so the two maps cannot drift. Empty by default; curated
    /// smart defaults live in code (`CuratedAppDefaults`), not here, so this
    /// map stores only explicit user overrides. (`AppBehavior.presetID` is
    /// reserved for a later unification of the two maps; it is unused in v1.)
    public var appBehaviors: [String: AppBehavior]

    /// Resolve the per-app default preset for a paste target. nil when
    /// the feature is disabled (MDM), the bundle is unmapped, or the
    /// mapped preset id no longer exists (deleted preset → dangling map
    /// entry resolves safely to nil).
    public func presetForApp(_ bundleID: String?) -> TransformPreset? {
        guard transformPresetsEnabled,
              let bundleID, !bundleID.isEmpty,
              let presetID = presetAppDefaults[bundleID]
        else { return nil }
        return transformPresets.first { $0.id == presetID }
    }

    /// Resolve the cleanup behavior for a paste target. Resolution order:
    /// user override (`appBehaviors`) → curated default mode
    /// (`CuratedAppDefaults`) → `cleanupDefaultLevel` (the global default). A
    /// `nil`/empty bundle resolves to `cleanupDefaultLevel`. Exception: when
    /// cleanup is globally off ("none" → `cleanupDefaultLevel == .raw`),
    /// curated defaults are skipped so an opted-out user keeps Raw everywhere;
    /// only an explicit `appBehaviors` override lifts an app out of Raw.
    ///
    /// Curated *suggested tones* are intentionally NOT applied here — this
    /// returns only the user's explicit preset (which can only come from an
    /// `appBehaviors` override). Suggestions stay off until the user accepts
    /// them in the App-behavior editor.
    public func behaviorForApp(_ bundleID: String?) -> AppBehavior {
        guard let bundleID else { return AppBehavior(mode: cleanupType) }
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AppBehavior(mode: cleanupType) }
        // Mode: explicit override → curated default → global cleanup type.
        //   • "none" (cleanupType == .raw): curated defaults are skipped
        //     entirely — a user who opted out of cleanup keeps Raw everywhere;
        //     only an explicit override lifts them out.
        //   • A curated `.polished` upgrade is applied ONLY when the user's
        //     CLEANUP is itself Polished (cleanupType == .polished). Otherwise
        //     it falls back to the user's cleanup type. This is load-bearing:
        //     a concord (Instant) cleanup user who configured a cloud provider
        //     for REFINEMENT has a non-nil `polishedProvider`, so without this
        //     guard curated comms/email/browser apps would route their CLEANUP
        //     to the refinement provider — cloud — even though the user chose
        //     on-device cleanup. Curated `.instant` always applies (on-device
        //     is always available); explicit overrides are always honored.
        let mode: TargetMode
        if let override = appBehaviors[trimmed]?.mode {
            mode = override
        } else if cleanupType == .raw {
            mode = .raw
        } else if let curated = CuratedAppDefaults.mode(for: trimmed) {
            mode = (curated == .polished && cleanupType != .polished) ? cleanupType : curated
        } else {
            mode = cleanupType
        }
        // Preset is sourced from presetForApp — the single source of truth
        // (`presetAppDefaults`) plus the MDM gate — so the two maps can never
        // drift. Only Polished carries a preset; suggested tones are never
        // auto-applied.
        let presetID = mode == .polished ? presetForApp(trimmed)?.id : nil
        return AppBehavior(mode: mode, presetID: presetID)
    }

    /// Model to use when references are attached to a dictation.
    /// nil means "fall back to the cleanup model" — that's the setup
    /// wizard's "Same as cleanup" default and the legacy behavior for
    /// pre-Phase-2 configs.
    public var contextModel: ModelIdentifier?

    /// Model to use for REFINE-shaped operations: hotkey voice-refine,
    /// quick-refinement chips, and first-pass cleanup that folds a
    /// per-app default preset (a "style"). These are operations the
    /// on-device Concord cleanup tier cannot perform (it no-ops refine
    /// turns and can't apply a style), so this tier lets the user route
    /// them to a cloud provider while keeping plain first-pass cleanup
    /// on Concord. nil means "fall back to the context model, then the
    /// cleanup model" (see Config.modelForInvocation) — the default and
    /// the legacy behavior for configs that don't set it. Serialized as
    /// the top-level `llm.refine` object (`{provider, model}`), mirroring
    /// the `context_model` shape.
    ///
    /// Reframe (v2): reinterpreted as the REFINEMENT's Polished provider —
    /// used when `refinementType == .polished`. It is one half of the shared
    /// `polishedProvider` (the other being `llmProvider` when cleanup is
    /// generative). Still serialized as `llm.refine` so an older build reads it
    /// as its refine tier (downgrade-faithful).
    public var refineModel: ModelIdentifier?

    /// GLOBAL refinement type (reframe v2): how a hotkey voice-refine / quick
    /// chip is handled.
    ///   - `.polished` → interpret + carry out the command via `polishedProvider`
    ///     (real rewriting).
    ///   - `.instant`  → append-only: the new dictation is cleaned on-device
    ///     (Concord) and appended to the prior text.
    ///   - `.raw`      → append-only: the new dictation is appended verbatim.
    /// Serialized as `llm.refinement`; migrated from the legacy refine tier
    /// when the key is absent. Not per-app in v1 (refinement is global).
    public var refinementType: TargetMode

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
    /// One-time consent for voice enrollment (the acoustic-disambiguation
    /// wizard). Off by default: enabling consents to recording short clips of
    /// the user speaking a term, processed on-device — only a derived
    /// voiceprint (biometric data; persisted encrypted-at-rest on this device,
    /// deletable anytime) is kept. When clip storage is enabled
    /// (`voiceprintClipStorageEnabled`), the enrollment audio clips are also
    /// kept encrypted on-device so the voiceprint can survive future model
    /// updates without re-enrollment; clip storage can be turned off
    /// independently by the user or via MDM. Set once when the user enables
    /// the feature.
    public var voiceEnrollmentConsented: Bool
    /// Master switch for the voice enrollment feature (acoustic-disambiguation).
    /// Default on; MDM-disable-able. When false, enrollment UI is suppressed and
    /// voiceprint matching is disabled fleet-wide.
    public var voiceEnrollmentEnabled: Bool
    /// Store enrollment audio clips encrypted on-device to enable automatic
    /// voiceprint migration across model updates. Default on;
    /// user/MDM-disable-able (fail-closed).
    public var voiceprintClipStorageEnabled: Bool
    /// Whether the user has explicitly consented to storing enrollment audio
    /// clips on-device. Default false; set true on explicit user consent in
    /// the clip-storage consent UI.
    public var voiceClipStorageConsented: Bool
    /// Kill-switch for correction-time negative auto-harvest: when the user
    /// undoes a dictionary-term over-fire (per-correction undo, or an E-edit
    /// changing an enrolled term back to a common word), Parleq pools the
    /// corrected word's audio-span embedding and attaches it as a negative
    /// prototype to that term's voiceprint. Default ON — harvesting is the
    /// feature's entire value and only activates for terms the user explicitly
    /// enrolled under biometric consent. User/MDM-disable-able (fail-closed,
    /// same resolver as `voiceprintClipStorageEnabled`). No new consent flag:
    /// harvest is the same embeddings-not-audio data class the enrollment
    /// consent already governs (see SECURITY_REVIEW §5.4).
    public var voiceprintHarvestEnabled: Bool
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

    /// Exact acknowledgment phrase that arms the (hidden, undocumented)
    /// flywheel contribution-capture mode. A bare `true` or any other
    /// value does NOT arm it — the enabling gesture must be deliberate
    /// and informed. Documented ONLY in docs/SECURITY_REVIEW.md, never
    /// in user-facing surfaces. See ContributionRecorder.swift.
    public static let contributionCaptureAck =
        "i-understand-this-writes-my-audio-and-transcripts-to-disk"

    /// Armed contribution mode (flywheel capture). Off unless the user
    /// hand-edits config.json with the exact `contribution.capture`
    /// acknowledgment phrase above. Never surfaced in Settings/wizard;
    /// this is the opt-in carve-out to invariants #1/#2/#7 (durable
    /// audio + transcripts on disk). Default false; the app never
    /// transmits the captured corpus. Defaulted so it stays out of the
    /// memberwise init and Settings serialization.
    public var contributionCaptureArmed: Bool = false

    /// Advanced LLM-request tuning from the `llm.tuning` config section
    /// (#55): thinking budget, max output tokens, temperature, the TTFT
    /// watchdog deadlines, and the request timeout. Config-file only —
    /// no Settings UI, no MDM key. Launch-read: `main.swift` copies this
    /// into `LLMTuning.current` before any provider is built, so changes
    /// require a restart. Defaults to `.init()` (built-in behavior,
    /// modulo the documented maxOutputTokens 1024 → 2048 raise). See
    /// LLMTuning.swift for field semantics and clamping.
    public var llmTuning: LLMTuning

    // MARK: - On-device (local) LLM cleanup tier

    /// Model residency policy for the local cleanup provider.
    /// Decoded from `llm.local.residency`. Default `.auto`.
    public var localResidency: LocalResidency
    /// Override for the idle-unload timeout (minutes) when
    /// `localResidency == .auto`. nil means "use the RAM-tier
    /// default" (`LocalModelDefaults.idleUnloadMinutesCautioned`
    /// or `…Comfortable`). Decoded from `llm.local.idle_unload_minutes`.
    public var localIdleUnloadMinutes: Int?
    /// When true, allow the local provider even on machines with
    /// < 12 GB RAM where the ~6 GB resident model will likely
    /// cause thrashing. Default false; gated by `RAMTier.current`.
    /// Decoded from `llm.local.allow_unsupported_ram`.
    public var localAllowUnsupportedRAM: Bool

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
        hotkeyGestures: [:],
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
        oidcIssuer: "",
        oidcClientID: "",
        oidcScopes: ["openid", "profile", "email", "offline_access"],
        oidcEphemeralBrowser: false,
        oidcRedirectURI: "parleq-auth://oidc/callback",
        oidcExtraAuthParams: [:],
        awsRoleArn: "",
        awsSessionDurationSeconds: 3600,
        vertexWorkforceProvider: "",
        wizardCompleted: false,
        trailingSpace: true,
        noTrailingSpaceAppBundleIDs: [],
        continueOtherAudio: true,
        audioInputDeviceUID: "",
        asrEndpoint: bundledASREndpoint,
        // Ship the app's own name as a built-in dictionary term so ASR
        // biasing emits "Parleq" out of the box instead of common
        // mis-hearings ("Parlek", "Parlay", …). Source .user so it shows in
        // the dictionary editor and can be edited/removed like any term.
        // (New configs only — existing users keep their saved dictionary.)
        customDictionary: [
            DictionaryEntry(
                term: "Parleq",
                context: "the name of this dictation app",
                // "Parlock" added from observed real FluidAudio mishearings of
                // the app name. (A real-word mishear like "Parlour" is left out
                // of the defaults so it can't over-fire on natural speech;
                // users can still add such aliases to their own dictionary.)
                aliases: ["Parlek", "Parlay", "Parlez", "Parlec", "Parlock"],
                biasing: .asrAndLLM,
                source: .user)
        ],
        transformPresets: [],
        presetAppDefaults: [:],
        appBehaviors: [:],
        contextModel: nil,
        refineModel: nil,
        refinementType: .polished,
        referenceWindowsEnabled: true,
        clipboardReferenceEnabled: true,
        imageReferenceEnabled: true,
        fileReferenceEnabled: true,
        customDictionaryEnabled: true,
        customModelEntryEnabled: true,
        transcriptHistoryMaxEntries: nil,
        transcriptHistoryRetentionHours: nil,
        learnFromCorrectionsEnabled: false,
        voiceEnrollmentConsented: false,
        voiceEnrollmentEnabled: true,
        voiceprintClipStorageEnabled: true,
        voiceClipStorageConsented: false,
        voiceprintHarvestEnabled: true,
        learnedCorrectionsMaxEntries: nil,
        learnedCorrectionsRetentionHours: nil,
        transformPresetsEnabled: true,
        llmTuning: LLMTuning(),
        localResidency: .auto,
        localIdleUnloadMinutes: nil,
        localAllowUnsupportedRAM: false,
        managedKeys: []
    )

    /// Alias for `default`. The built-in member name `default` is a Swift
    /// keyword requiring backticks at the call site; `defaults` reads more
    /// naturally in test code and matches the convention used by the
    /// enterprise-OIDC test suite.
    public static let defaults = Config.default

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
            var c = Config.parse(fromDictionary: dict)
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
        if let v = ManagedConfig.managedBool(forKey: "transformPresetsEnabled") {
            c.transformPresetsEnabled = v
            managedKeys.insert("transformPresetsEnabled")
        }
        if let v = ManagedConfig.managedInt(forKey: "learnedCorrectionsMaxEntries") {
            c.learnedCorrectionsMaxEntries = v
            managedKeys.insert("learnedCorrectionsMaxEntries")
        }
        if let v = ManagedConfig.managedInt(forKey: "learnedCorrectionsRetentionHours") {
            c.learnedCorrectionsRetentionHours = v
            managedKeys.insert("learnedCorrectionsRetentionHours")
        }
        // Phase 10 — voiceprint MDM controls.
        //
        // voiceEnrollmentEnabled (Bool) — fleet-wide master switch for the
        // voice-enrollment / acoustic-disambiguation feature. Normal Bool key:
        // managed false disables enrollment UI and voiceprint matching fleet-wide;
        // managed true explicitly re-enables it. A malformed forced value leaves
        // the field at its user/default (same fail-open posture as other toggles).
        if let v = ManagedConfig.managedBool(forKey: "voiceEnrollmentEnabled") {
            c.voiceEnrollmentEnabled = v
            managedKeys.insert("voiceEnrollmentEnabled")
        }
        // voiceprintClipStorageEnabled (Bool) — kill-switch for on-device
        // enrollment-clip persistence (SI-2: FAIL CLOSED). A present-but-
        // malformed forced value (e.g. the string "false") cannot be bridged
        // to Bool by managedBool — it returns nil. If we treated nil the same
        // as "not managed" the kill-switch would silently fail open. Instead,
        // managedValuePresent detects that the key IS managed (regardless of
        // parse success) and resolveClipStorage maps any non-true forced value
        // — including malformed/nil — to off. Only an explicit managed true
        // enables clip storage; anything else disables it.
        let clipResult = ManagedConfig.resolveClipStorage(
            present: ManagedConfig.managedValuePresent(forKey: "voiceprintClipStorageEnabled"),
            parsed: ManagedConfig.managedBool(forKey: "voiceprintClipStorageEnabled")
        )
        if clipResult.managed {
            c.voiceprintClipStorageEnabled = clipResult.value
            managedKeys.insert("voiceprintClipStorageEnabled")
        }
        // voiceprintHarvestEnabled (Bool) — kill-switch for correction-time
        // negative auto-harvest (FAIL CLOSED, same truth table as the clip-
        // storage kill-switch above): only an explicit managed true enables
        // harvesting; a present-but-malformed forced value disables it.
        let harvestResult = ManagedConfig.resolveClipStorage(
            present: ManagedConfig.managedValuePresent(forKey: "voiceprintHarvestEnabled"),
            parsed: ManagedConfig.managedBool(forKey: "voiceprintHarvestEnabled")
        )
        if harvestResult.managed {
            c.voiceprintHarvestEnabled = harvestResult.value
            managedKeys.insert("voiceprintHarvestEnabled")
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
            let recognized = ["sso", "static", "bedrockApiKey", "oidc"]
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
        // Recognized values: "adc" (default), "serviceAccount",
        // "oidcFederation" (Workforce Identity Federation), "googleOAuth"
        // (native Google sign-in via the OIDC engine; the access token is a
        // direct Vertex bearer — no exchanger/STS hop).
        // Unrecognized values rejected (key NOT added to
        // managedKeys) so a typo doesn't silently lock the user out.
        if let rawVertexAuthMode = ManagedConfig.managedString(forKey: "vertexAuthMode") {
            let recognized = ["adc", "serviceAccount", "oidcFederation", "googleOAuth"]
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

        // Enterprise OIDC federation — destination/identity pins. The
        // issuer + client ID + role ARN + workforce provider are all
        // org-config strings an admin pins fleet-wide; scopes is an
        // array; ephemeral-browser is a Bool; session duration is an
        // Int clamped to STS's 900...43200 window (mirrors the parse
        // clamp). Each empty/invalid value is treated as unmanaged with
        // a fail-open log, matching the other destination pins above.
        if let raw = ManagedConfig.managedString(forKey: "oidcIssuer") {
            if let validated = ManagedConfig.validateOIDCIssuer(raw) {
                c.oidcIssuer = validated
                managedKeys.insert("oidcIssuer")
            } else {
                configLogStderr("[parleq] oidcIssuer: rejected managed value — must be an https:// URL (or http:// loopback for dev); empty or non-HTTPS non-loopback values are not valid OIDC issuers; treating as unmanaged")
            }
        }
        if let raw = ManagedConfig.managedString(forKey: "oidcClientID") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                c.oidcClientID = trimmed
                managedKeys.insert("oidcClientID")
            } else {
                configLogStderr("[parleq] oidcClientID: rejected managed value — empty string is not a valid OIDC client ID; treating as unmanaged")
            }
        }
        if let raw = ManagedConfig.managedStringArray(forKey: "oidcScopes") {
            // managedStringArray already returns nil for an empty array,
            // so a non-nil result here is a non-empty scope list.
            c.oidcScopes = raw
            managedKeys.insert("oidcScopes")
        }
        if let v = ManagedConfig.managedBool(forKey: "oidcEphemeralBrowserSession") {
            c.oidcEphemeralBrowser = v
            managedKeys.insert("oidcEphemeralBrowserSession")
        }
        if let raw = ManagedConfig.managedString(forKey: "oidcRedirectURI") {
            if let validated = ManagedConfig.validateOIDCRedirectURI(raw) {
                c.oidcRedirectURI = validated
                managedKeys.insert("oidcRedirectURI")
            } else {
                configLogStderr("[parleq] oidcRedirectURI: rejected managed value — must be a custom-scheme URL or an http:// loopback redirect; treating as unmanaged")
            }
        }
        if let dict = ManagedConfig.managedStringDict(forKey: "oidcExtraAuthParams") {
            // managedStringDict returns nil for an empty/unusable dict, so a
            // non-nil result here is a non-empty [String: String] of extra
            // authorization-request params.
            c.oidcExtraAuthParams = dict
            managedKeys.insert("oidcExtraAuthParams")
        }
        if let raw = ManagedConfig.managedString(forKey: "awsRoleArn") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                c.awsRoleArn = trimmed
                managedKeys.insert("awsRoleArn")
            } else {
                configLogStderr("[parleq] awsRoleArn: rejected managed value — empty string is not a valid IAM role ARN; treating as unmanaged")
            }
        }
        if let v = ManagedConfig.managedInt(forKey: "awsSessionDurationSeconds") {
            c.awsSessionDurationSeconds = min(max(v, 900), 43200)
            managedKeys.insert("awsSessionDurationSeconds")
        }
        if let raw = ManagedConfig.managedString(forKey: "vertexWorkforceProvider") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                c.vertexWorkforceProvider = trimmed
                managedKeys.insert("vertexWorkforceProvider")
            } else {
                configLogStderr("[parleq] vertexWorkforceProvider: rejected managed value — empty string is not a valid workforce provider resource name; treating as unmanaged")
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

        // REFINE TIER — provider/model pins (mirror of the contextProvider/
        // contextModel pins above, pin-only). Lets an admin force the
        // refine tier (voice-refine, quick chips, styled cleanup) onto a
        // specific cloud provider+model. Falls back to the context-tier
        // value, then cleanup, exactly like the runtime resolution chain,
        // so pinning just the provider snaps the model to that provider's
        // curated default.
        let currentRefineProvider = c.refineModel?.provider ?? (c.contextModel?.provider ?? c.llmProvider)
        let currentRefineModel    = c.refineModel?.model    ?? (c.contextModel?.model    ?? c.llmModel)
        var refineProvider = currentRefineProvider
        var refineModelName = currentRefineModel

        if let pinnedProvider = ManagedConfig.managedString(forKey: "refineProvider") {
            // If only the provider is pinned and the stored model belongs
            // to a different provider, snap the model to the pinned
            // provider's default (mirror of the cleanup/context checks).
            if pinnedProvider != refineProvider,
               !ModelCatalog.isCanonical(provider: pinnedProvider, model: refineModelName) {
                refineModelName = ModelCatalog.defaultModel(forProvider: pinnedProvider)
            }
            refineProvider = pinnedProvider
            managedKeys.insert("refineProvider")
        }
        if let pinnedModel = ManagedConfig.managedString(forKey: "refineModel") {
            refineModelName = pinnedModel
            managedKeys.insert("refineModel")
        }

        let refineTierManaged = managedKeys.contains("refineProvider")
            || managedKeys.contains("refineModel")
        if refineTierManaged {
            let cleanupId = ModelIdentifier(provider: c.llmProvider, model: c.llmModel)
            let refineId  = ModelIdentifier(provider: refineProvider, model: refineModelName)
            // nil when the pin resolves back to the cleanup tier (= "same
            // as cleanup"); otherwise the explicit refine identifier.
            c.refineModel = (refineId == cleanupId) ? nil : refineId
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
            let refineModelManaged = managedKeys.contains("refineModel")
            if let rfn = c.refineModel,
               !refineModelManaged,
               !ModelCatalog.isCanonical(provider: rfn.provider, model: rfn.model) {
                let original = rfn.model
                let replacement = ModelCatalog.defaultModel(forProvider: rfn.provider)
                c.refineModel = ModelIdentifier(provider: rfn.provider, model: replacement)
                configLogStderr("[parleq] customModelEntryEnabled=false: rejected non-canonical refine model '\(original)' (provider=\(rfn.provider)); reset to '\(replacement)'")
            }
        }
    }

    // MARK: - Test seams

    /// Parse a Config from a raw JSON dictionary (the same logic used
    /// by `load()`, but without filesystem I/O or MDM overlay).
    /// Production `load()` delegates here; tests call it directly as a seam.
    /// Internal so tests can call it via `@testable import`.
    static func parse(fromDictionary parsed: [String: Any]) -> Config {
        var c = Config.default
        // Reframe v2: whether the config carried an explicit `llm.refinement`
        // type. When absent (a pre-reframe config), we derive the refinement
        // type from the legacy refine tier below (see the migration near the
        // end of parse).
        var refinementKeyPresent = false
        if let hotkey = parsed["hotkey"] as? [String: Any] {
            if let binding = hotkey["binding"] as? String {
                c.hotkeyBinding = binding
            }
            // #84: configurable double-tap gesture actions.
            if let gestures = hotkey["gestures"] as? [String: Any] {
                var m: [String: String] = [:]
                for (key, value) in gestures {
                    if let s = value as? String { m[key] = s }
                }
                c.hotkeyGestures = m
            }
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
            // Advanced LLM-request tuning (#55). Every key is
            // optional-with-default and clamped here at parse time, so
            // out-of-range / malformed values land on a safe value
            // (never an invalid request). An absent "tuning" sub-object
            // leaves c.llmTuning at its default.
            if let tuning = llm["tuning"] as? [String: Any] {
                c.llmTuning = parseLLMTuning(tuning)
            }
            // On-device cleanup tier — llm.local sub-object.
            // All fields optional-with-default; omit-when-default on save.
            if let local = llm["local"] as? [String: Any] {
                if let v = local["residency"] as? String,
                   let r = LocalResidency(rawValue: v) {
                    c.localResidency = r
                }
                if let v = local["idle_unload_minutes"] as? Int, v >= 0 {
                    c.localIdleUnloadMinutes = v
                }
                if let v = local["allow_unsupported_ram"] as? Bool {
                    c.localAllowUnsupportedRAM = v
                }
            }
            // Refinement tier — llm.refine sub-object ({provider, model}).
            // Mirrors the context_model shape but lives under "llm" so the
            // three model tiers (cleanup, refine, context) read coherently.
            // Routes hotkey voice-refine, quick chips, and styled (per-app
            // preset) cleanup to a cloud provider when cleanup is the
            // on-device Concord tier (which can't perform those ops).
            if let refine = llm["refine"] as? [String: Any],
               let provider = refine["provider"] as? String,
               let model = refine["model"] as? String {
                let tp = provider.trimmingCharacters(in: .whitespacesAndNewlines)
                let tm = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tp.isEmpty && !tm.isEmpty {
                    c.refineModel = ModelIdentifier(provider: tp, model: tm)
                }
            }
            // Reframe v2: the global refinement TYPE. When present it is
            // authoritative; when absent we migrate from the legacy refine
            // tier after all fields are parsed (see near the end of parse).
            if let v = llm["refinement"] as? String, let t = TargetMode(rawValue: v) {
                c.refinementType = t
                refinementKeyPresent = true
            }
        }
        if let aws = parsed["aws"] as? [String: Any] {
            if let v = aws["region"] as? String, !v.isEmpty { c.awsRegion = v }
            if let v = aws["profile"] as? String {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                c.awsProfile = t.isEmpty ? nil : t
            }
            if let v = aws["auth_mode"] as? String,
               ["sso", "static", "bedrockApiKey", "oidc"].contains(v) { c.awsAuthMode = v }
            // Enterprise OIDC federation — AWS leg.
            if let v = aws["role_arn"] as? String {
                c.awsRoleArn = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let v = aws["session_duration_seconds"] as? Int {
                c.awsSessionDurationSeconds = min(max(v, 900), 43200)
            }
        }
        if let vertex = parsed["vertex"] as? [String: Any] {
            if let v = vertex["project"] as? String {
                c.vertexProject = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let v = vertex["region"] as? String, !v.isEmpty { c.vertexRegion = v }
            if let v = vertex["auth_mode"] as? String,
               ["adc", "serviceAccount", "oidcFederation", "googleOAuth"].contains(v) { c.vertexAuthMode = v }
            if let v = vertex["anthropic_region"] as? String, !v.isEmpty {
                c.vertexAnthropicRegion = v
            }
            // Enterprise OIDC federation — GCP leg.
            if let v = vertex["workforce_provider"] as? String {
                c.vertexWorkforceProvider = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Enterprise OIDC federation — top-level "oidc" section (the
        // shared corporate sign-in shared by the AWS + GCP federation legs).
        if let oidc = parsed["oidc"] as? [String: Any] {
            // issuer must be an https:// URL (or http:// loopback for the
            // in-repo Keycloak dev rig) — the same HTTPS-or-loopback rule the
            // MDM path applies via ManagedConfig.validateOIDCIssuer. runtime
            // discover() catches a bad value later and fails closed, so this
            // is parity/legibility: reject at load (keep the prior/default
            // value) with a code-only log rather than letting it sit in config.
            if let v = oidc["issuer"] as? String {
                if let validated = ManagedConfig.validateOIDCIssuer(v) {
                    c.oidcIssuer = validated
                } else {
                    configLogStderr("[parleq] oidc.issuer: rejected — must be an https:// URL (or http:// loopback for dev); keeping previous value")
                }
            }
            if let v = oidc["client_id"] as? String {
                c.oidcClientID = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let v = oidc["scopes"] as? [String], !v.isEmpty { c.oidcScopes = v }
            if let v = oidc["ephemeral_browser"] as? Bool { c.oidcEphemeralBrowser = v }
            // redirect_uri must be either a custom-scheme URL (intercepted in
            // process by ASWebAuthenticationSession — scheme derived from this
            // value) OR an http:// LOOPBACK redirect (the Desktop-app loopback
            // flow, answered by a transient 127.0.0.1-only listener; the PORT is
            // ignored, the PATH preserved). https:// (can't be intercepted or
            // served) and http:// on a non-loopback host (an attacker could
            // answer it) are rejected — keep the default with a code-only log.
            if let v = oidc["redirect_uri"] as? String {
                if let validated = ManagedConfig.validateOIDCRedirectURI(v) {
                    c.oidcRedirectURI = validated
                } else {
                    configLogStderr("[parleq] oidc.redirect_uri: rejected — must be a custom-scheme URL or an http:// loopback redirect; keeping default")
                }
            }
            // extra_auth_params: a flat [String: String] of additional
            // authorization-request query params. Non-String values are
            // dropped element-wise; an all-default (empty) map is the default.
            if let v = oidc["extra_auth_params"] as? [String: Any] {
                var params: [String: String] = [:]
                for (k, val) in v { if let s = val as? String { params[k] = s } }
                c.oidcExtraAuthParams = params
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
                    let spokenForms: [String] = {
                        guard let raw = obj["spoken_forms"] as? [String] else { return [] }
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
                        spokenForms: spokenForms,
                        biasing: biasing,
                        source: source
                    )
                }
                return nil
            }
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
            if let v = features["voice_enrollment_consented"] as? Bool {
                c.voiceEnrollmentConsented = v
            }
            if let v = features["voice_enrollment_enabled"] as? Bool {
                c.voiceEnrollmentEnabled = v
            }
            if let v = features["voiceprint_clip_storage_enabled"] as? Bool {
                c.voiceprintClipStorageEnabled = v
            }
            if let v = features["voice_clip_storage_consented"] as? Bool {
                c.voiceClipStorageConsented = v
            }
            if let v = features["voiceprint_harvest_enabled"] as? Bool {
                c.voiceprintHarvestEnabled = v
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
        // Hidden contribution-capture arming — its own top-level block,
        // NOT under "features" (the features block is rewritten by
        // Settings saves, which would drop an unknown key; mergeForSave
        // preserves this block verbatim instead). Armed only when the
        // capture value exactly equals the acknowledgment phrase — a
        // bare `true`, an MDM push, or a copied template do nothing.
        if let contribution = parsed["contribution"] as? [String: Any],
           let capture = contribution["capture"] as? String {
            c.contributionCaptureArmed = (capture == Config.contributionCaptureAck)
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
        // Trim whitespace from both keys (bundle IDs) and values (preset IDs)
        // so hand-authored managed configs with padding still resolve correctly.
        if let raw = parsed["preset_app_defaults"] as? [String: Any] {
            var mapped: [String: String] = [:]
            for (key, value) in raw {
                let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let v = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !k.isEmpty, !v.isEmpty else { continue }
                mapped[k] = v
            }
            c.presetAppDefaults = mapped
        }
        // Per-app cleanup behavior — top-level "app_behaviors". This is the
        // successor to `preset_app_defaults`. When present it takes
        // precedence; legacy entries are synthesized in only for bundles
        // NOT covered by app_behaviors, so nothing is lost across a build
        // that wrote one map but not the other. Keys are trimmed; a
        // missing/invalid `mode` defaults to `.polished`.
        var behaviors: [String: AppBehavior] = [:]
        if let raw = parsed["app_behaviors"] as? [String: Any] {
            for (key, value) in raw {
                let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty, let obj = value as? [String: Any] else { continue }
                let mode = (obj["mode"] as? String).flatMap(TargetMode.init(rawValue:)) ?? .polished
                // A native app_behaviors entry may carry a `preset`. Presets
                // live in `presetAppDefaults` (the single source of truth the
                // Settings UI / LearnedStore mutate) — fold it there rather than
                // duplicating it into appBehaviors, which would let the two maps
                // drift (a delete via the legacy path could be resurrected on
                // save). appBehaviors stores the MODE override only.
                if mode == .polished,
                   let preset = (obj["preset"] as? String)?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !preset.isEmpty {
                    c.presetAppDefaults[k] = preset
                }
                behaviors[k] = AppBehavior(mode: mode, presetID: nil)
            }
        }
        // Preserve a user's explicit Polished+styling intent: if a legacy
        // per-app preset exists for an app whose CURATED default would flip it
        // to a non-Polished mode (e.g. a terminal the user had styled), record
        // a mode-only Polished override so it isn't silently turned literal.
        // The preset itself stays in presetAppDefaults.
        for (bundle, _) in c.presetAppDefaults where behaviors[bundle] == nil {
            if let curated = CuratedAppDefaults.mode(for: bundle), curated != .polished {
                behaviors[bundle] = AppBehavior(mode: .polished, presetID: nil)
            }
        }
        c.appBehaviors = behaviors

        // Reframe v2 migration: derive the refinement TYPE from the legacy
        // refine tier when no explicit `llm.refinement` key was present. Old
        // refine resolution was `refineModel ?? contextModel ?? cleanup`, so
        // the effective refine provider tells us the type:
        //   generative → .polished (keep/adopt that provider as the refinement
        //                Polished provider so `polishedProvider` resolves it),
        //   "concord"  → .instant  (append-only, cleaned on-device),
        //   "none"     → .raw      (append-only, verbatim).
        if !refinementKeyPresent {
            if c.llmProvider == "none" {
                // "none" is the GLOBAL no-cloud off switch. Never auto-promote a
                // migrated "none" user to Polished (cloud) refinement from a
                // refine/context tier that was DEAD under "none" — the old
                // modelForInvocation short-circuited every refine turn to the
                // nil cleanup provider. Keep refinement append-only so an
                // upgrade preserves the user's zero-cloud posture, and do NOT
                // copy the context tier into refineModel. (A user can still
                // explicitly choose Raw cleanup + Polished refinement in the new
                // Settings UI — that writes llm.refinement and skips this path.)
                c.refinementType = .raw
                // Drop the dead refine tier so NO Polished provider is
                // resolvable for a migrated "none" user (polishedProvider → nil,
                // no refine client built) — belt-and-suspenders on zero-cloud.
                c.refineModel = nil
            } else {
                let effective = c.refineModel?.provider
                    ?? c.contextModel?.provider
                    ?? c.llmProvider
                if !Config.isGenerativeProvider(effective) {
                    c.refinementType = .instant
                } else {
                    c.refinementType = .polished
                    // When the Polished refinement provider comes from the
                    // context tier (cleanup isn't generative and no explicit
                    // refine tier), copy it into `refineModel` so
                    // `polishedProvider` resolves it.
                    if c.refineModel == nil,
                       !Config.isGenerativeProvider(c.llmProvider),
                       let ctx = c.contextModel,
                       Config.isGenerativeProvider(ctx.provider) {
                        c.refineModel = ctx
                    }
                }
            }
        }
        return c
    }

    /// Parse the `llm.tuning` sub-object into an `LLMTuning`, applying
    /// every clamp from LLMTuning's field docs. Missing keys keep the
    /// LLMTuning default; out-of-range scalars clamp; the TTFT arrays
    /// drop invalid entries, cap at 4, and fall back to the default when
    /// nothing valid survives. Internal so tests can drive it directly.
    static func parseLLMTuning(_ obj: [String: Any]) -> LLMTuning {
        var t = LLMTuning()
        // thinking_budget: null/absent → nil (built-in split). A present
        // numeric value clamps to 0...32768 and is sent verbatim.
        if let n = obj["thinking_budget"] as? NSNumber {
            t.thinkingBudget = min(32768, max(0, n.intValue))
        }
        if let n = obj["max_output_tokens"] as? NSNumber {
            t.maxOutputTokens = min(65536, max(64, n.intValue))
        }
        if let n = obj["temperature"] as? NSNumber {
            t.temperature = min(2.0, max(0.0, n.doubleValue))
        }
        if let raw = obj["ttft_deadline_seconds"] as? [Any] {
            let cleaned = Self.clampTTFTList(raw)
            if !cleaned.isEmpty { t.ttftDeadlineSeconds = cleaned }
        }
        if let raw = obj["ttft_deadline_thinking_seconds"] as? [Any] {
            let cleaned = Self.clampTTFTList(raw)
            if !cleaned.isEmpty { t.ttftDeadlineThinkingSeconds = cleaned }
        }
        if let n = obj["request_timeout_seconds"] as? NSNumber {
            t.requestTimeoutSeconds = min(300.0, max(5.0, n.doubleValue))
        }
        return t
    }

    /// Clamp a raw TTFT-deadline array: keep numeric entries clamped to
    /// 1...120, drop non-numeric / out-of-clampable entries, cap at 4.
    /// (A value below 1 or above 120 clamps rather than drops — only
    /// non-numbers are dropped.)
    private static func clampTTFTList(_ raw: [Any]) -> [Double] {
        raw.compactMap { item -> Double? in
            guard let n = item as? NSNumber else { return nil }
            return min(120.0, max(1.0, n.doubleValue))
        }
        .prefix(4)
        .map { $0 }
    }

    /// Build the `llm` JSON section, appending the `tuning` sub-object
    /// only when at least one tuning field differs from its default
    /// (omit-when-default house style). The base mode/provider/model
    /// fields are always present. The `local` sub-object is likewise
    /// omitted when every field is default.
    static func serializeLLMSection(_ config: Config) -> [String: Any] {
        var llm: [String: Any] = [
            "mode": config.llmMode,
            "provider": config.llmProvider,
            "model": config.llmModel,
        ]
        if !config.llmTuning.isDefault {
            llm["tuning"] = Self.serializeLLMTuning(config.llmTuning)
        }
        if let localDict = Self.serializeLocalSection(config) {
            llm["local"] = localDict
        }
        // Refinement Polished provider — emit as `llm.refine` when set (kept
        // for downgrade: an older build reads it as its refine tier).
        if let model = config.refineModel {
            llm["refine"] = ["provider": model.provider, "model": model.model]
        }
        // Reframe v2: the global refinement TYPE (raw/instant/polished).
        llm["refinement"] = config.refinementType.rawValue
        return llm
    }

    /// Build the `llm.local` sub-object (omit-when-default). Returns nil
    /// when every on-device field is at its default value so the caller can
    /// skip adding a "local" key, keeping the JSON clean. Used by both
    /// `serializeLLMSection` and the MDM/save preservation path so a future
    /// local field only needs to be added here.
    private static func serializeLocalSection(_ config: Config) -> [String: Any]? {
        var localDict: [String: Any] = [:]
        if config.localResidency != .auto {
            localDict["residency"] = config.localResidency.rawValue
        }
        if let minutes = config.localIdleUnloadMinutes {
            localDict["idle_unload_minutes"] = minutes
        }
        if config.localAllowUnsupportedRAM {
            localDict["allow_unsupported_ram"] = true
        }
        return localDict.isEmpty ? nil : localDict
    }

    /// Serialize an LLMTuning to a JSON dictionary, emitting ONLY the
    /// keys that differ from the default (omit-when-default). Used by the
    /// `llm.tuning` section; tests drive it directly.
    static func serializeLLMTuning(_ tuning: LLMTuning) -> [String: Any] {
        let d = LLMTuning()
        var obj: [String: Any] = [:]
        // thinking_budget: nil is the default — emit only a non-nil
        // override (round-trips back to nil when absent).
        if let budget = tuning.thinkingBudget, budget != d.thinkingBudget {
            obj["thinking_budget"] = budget
        }
        if tuning.maxOutputTokens != d.maxOutputTokens {
            obj["max_output_tokens"] = tuning.maxOutputTokens
        }
        if tuning.temperature != d.temperature {
            obj["temperature"] = tuning.temperature
        }
        if tuning.ttftDeadlineSeconds != d.ttftDeadlineSeconds {
            obj["ttft_deadline_seconds"] = tuning.ttftDeadlineSeconds
        }
        if tuning.ttftDeadlineThinkingSeconds != d.ttftDeadlineThinkingSeconds {
            obj["ttft_deadline_thinking_seconds"] = tuning.ttftDeadlineThinkingSeconds
        }
        if tuning.requestTimeoutSeconds != d.requestTimeoutSeconds {
            obj["request_timeout_seconds"] = tuning.requestTimeoutSeconds
        }
        return obj
    }

    /// Serialize a Config to a JSON dictionary (the same structure that
    /// `save()` writes, minus filesystem I/O and MDM preservation).
    /// Production `save()` delegates here; tests call it directly as a seam.
    /// Internal so tests can call it via `@testable import`.
    static func serializeToDictionary(_ config: Config) -> [String: Any] {
        var featuresDict: [String: Any] = [
            "reference_windows_enabled": config.referenceWindowsEnabled,
            "clipboard_reference_enabled": config.clipboardReferenceEnabled,
            "image_reference_enabled": config.imageReferenceEnabled,
            "file_reference_enabled": config.fileReferenceEnabled,
            "custom_dictionary_enabled": config.customDictionaryEnabled,
            "custom_model_entry_enabled": config.customModelEntryEnabled,
            "learn_from_corrections_enabled": config.learnFromCorrectionsEnabled,
            "voice_enrollment_consented": config.voiceEnrollmentConsented,
            "voice_enrollment_enabled": config.voiceEnrollmentEnabled,
            "voiceprint_clip_storage_enabled": config.voiceprintClipStorageEnabled,
            "voice_clip_storage_consented": config.voiceClipStorageConsented,
            "voiceprint_harvest_enabled": config.voiceprintHarvestEnabled,
            "transform_presets_enabled": config.transformPresetsEnabled,
        ]
        if let v = config.transcriptHistoryMaxEntries { featuresDict["transcript_history_max_entries"] = v }
        if let v = config.transcriptHistoryRetentionHours { featuresDict["transcript_history_retention_hours"] = v }
        if let v = config.learnedCorrectionsMaxEntries { featuresDict["learned_corrections_max_entries"] = v }
        if let v = config.learnedCorrectionsRetentionHours { featuresDict["learned_corrections_retention_hours"] = v }

        // Enterprise OIDC federation — assemble the aws/vertex sub-dicts
        // with the OIDC fields appended only when non-default (omit-when-
        // default house style). The base region/profile/auth-mode fields
        // are always present, matching the prior literal shape.
        var awsDict: [String: Any] = [
            "region": config.awsRegion,
            "profile": config.awsProfile ?? "",
            "auth_mode": config.awsAuthMode,
        ]
        if !config.awsRoleArn.isEmpty { awsDict["role_arn"] = config.awsRoleArn }
        if config.awsSessionDurationSeconds != Config.default.awsSessionDurationSeconds {
            awsDict["session_duration_seconds"] = config.awsSessionDurationSeconds
        }
        var vertexDict: [String: Any] = [
            "project": config.vertexProject,
            "region": config.vertexRegion,
            "auth_mode": config.vertexAuthMode,
            "anthropic_region": config.vertexAnthropicRegion,
        ]
        if !config.vertexWorkforceProvider.isEmpty {
            vertexDict["workforce_provider"] = config.vertexWorkforceProvider
        }

        var dict: [String: Any] = [
            "hotkey": config.hotkeyGestures.isEmpty
                ? (["binding": config.hotkeyBinding] as [String: Any])
                : (["binding": config.hotkeyBinding,
                    "gestures": config.hotkeyGestures] as [String: Any]),
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
            "llm": Self.serializeLLMSection(config),
            "aws": awsDict,
            "vertex": vertexDict,
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
                    if !entry.spokenForms.isEmpty { obj["spoken_forms"] = entry.spokenForms }
                    if entry.biasing != .asrAndLLM { obj["biasing"] = entry.biasing.rawValue }
                    if entry.source != .user { obj["source"] = entry.source.rawValue }
                    return obj
                },
            ],
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
        // Per-app cleanup behavior — the canonical key.
        if !config.appBehaviors.isEmpty {
            // v1: app_behaviors is MODE-only. The per-app preset lives in
            // presetAppDefaults (the single source of truth); never serialize
            // AppBehavior.presetID here, or a stale / externally-constructed
            // value would be folded back into presetAppDefaults on the next
            // parse, re-opening the drift bug.
            dict["app_behaviors"] = config.appBehaviors.mapValues { behavior in
                ["mode": behavior.mode.rawValue]
            }
        }
        // `preset_app_defaults` is the single source of truth for per-app
        // presets (the Settings UI / LearnedStore mutate it directly), so write
        // it verbatim — NOT derived from appBehaviors, which would resurrect a
        // preset deleted via the legacy path. appBehaviors (above) carries the
        // new MODE dimension; presets stay here. The dual-key layout keeps an
        // older build (or a downgrade) working.
        if !config.presetAppDefaults.isEmpty {
            dict["preset_app_defaults"] = config.presetAppDefaults
        }
        // Enterprise OIDC federation — emit the top-level "oidc" section
        // only when at least one of its fields is non-default. `scopes` is
        // itself omitted when it equals the default list, matching the
        // omit-when-default house style used throughout this serializer.
        let scopesAreDefault = config.oidcScopes == Config.default.oidcScopes
        let redirectURIIsDefault = config.oidcRedirectURI == Config.default.oidcRedirectURI
        let extraAuthParamsAreDefault = config.oidcExtraAuthParams.isEmpty
        let oidcIsDefault = config.oidcIssuer.isEmpty
            && config.oidcClientID.isEmpty
            && scopesAreDefault
            && config.oidcEphemeralBrowser == Config.default.oidcEphemeralBrowser
            && redirectURIIsDefault
            && extraAuthParamsAreDefault
        if !oidcIsDefault {
            var oidcDict: [String: Any] = [:]
            if !config.oidcIssuer.isEmpty { oidcDict["issuer"] = config.oidcIssuer }
            if !config.oidcClientID.isEmpty { oidcDict["client_id"] = config.oidcClientID }
            if !scopesAreDefault { oidcDict["scopes"] = config.oidcScopes }
            if config.oidcEphemeralBrowser != Config.default.oidcEphemeralBrowser {
                oidcDict["ephemeral_browser"] = config.oidcEphemeralBrowser
            }
            if !redirectURIIsDefault { oidcDict["redirect_uri"] = config.oidcRedirectURI }
            if !extraAuthParamsAreDefault { oidcDict["extra_auth_params"] = config.oidcExtraAuthParams }
            dict["oidc"] = oidcDict
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

        // The managed-key preservation/merge is pure (no disk I/O), so it
        // lives in `mergeForSave(_:existing:)` where tests can drive it with a
        // synthetic existing dict — following the reconcileDictionary
        // precedent of extracting the testable core out of the I/O wrapper.
        let dict = mergeForSave(config, existing: existingDict)
        let data = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Pure merge step of `save()`: given the in-memory `config` and the
    /// existing on-disk dict, produce the dict to serialize — applying MDM
    /// managed-key preservation (so removing an MDM profile restores the
    /// user's pre-MDM choice) and the OIDC-federation omit-when-default /
    /// never-materialize rules. No disk I/O; `save()` reads/writes, this
    /// transforms. Exposed for tests.
    static func mergeForSave(_ config: Config, existing existingDict: [String: Any]) -> [String: Any] {
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
        // Model preservation logic — three cases:
        // (a) modelPinned → always preserve on-disk (user can't change
        //     it anyway; writing the effective MDM value would clobber
        //     their pre-MDM fallback).
        // (b) providerPinned + model unmanaged + on-disk model is
        //     FOREIGN to the pinned provider (e.g. an openai model under
        //     a vertex pin) → preserve it. That foreign value is the
        //     user's pre-MDM fallback for some OTHER provider; the
        //     in-memory model is just a runtime auto-snap into the
        //     pinned world. Preserving it means removing the profile
        //     restores their original choice.
        // (c) providerPinned + model unmanaged + on-disk model is
        //     already CANONICAL for the pinned provider → the user is
        //     picking within the pinned world (e.g. flash → flash-lite
        //     under a vertex pin). WRITE the in-memory choice so it
        //     persists across restarts. (allowlist also lands here:
        //     user actively picks within the allowed set.)
        let onDiskModel = existingLLM["model"] as? String
        // Empty-string guard mirrors the context tier: a degenerate ""
        // on-disk model is not a foreign fallback worth preserving —
        // preserving it would write "" (non-nil, so the ?? never fires).
        let onDiskModelForeign = onDiskModel.map {
            !$0.isEmpty && !ModelCatalog.isCanonical(provider: llmProviderToWrite, model: $0)
        } ?? false
        let preserveModelOnDisk = modelPinned
            || (providerPinned && !modelAllowlist && onDiskModelForeign)
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
        // Voice-enrollment consent is never MDM-managed; always written through.
        featuresDict["voice_enrollment_consented"] = config.voiceEnrollmentConsented
        // voiceEnrollmentEnabled — MDM-managed master switch. Same
        // carry-forward pattern as the other feature toggles: write the
        // in-memory value when unmanaged, preserve the on-disk value when
        // MDM is overriding (so removing the profile restores the user's
        // pre-MDM choice).
        if !config.managedKeys.contains("voiceEnrollmentEnabled") {
            featuresDict["voice_enrollment_enabled"] = config.voiceEnrollmentEnabled
        } else if let existing = existingFeatures["voice_enrollment_enabled"] {
            featuresDict["voice_enrollment_enabled"] = existing
        }
        // voiceprintClipStorageEnabled — MDM-managed kill-switch (fail-closed).
        if !config.managedKeys.contains("voiceprintClipStorageEnabled") {
            featuresDict["voiceprint_clip_storage_enabled"] = config.voiceprintClipStorageEnabled
        } else if let existing = existingFeatures["voiceprint_clip_storage_enabled"] {
            featuresDict["voiceprint_clip_storage_enabled"] = existing
        }
        // Clip-storage consent is never MDM-managed (consent can't be
        // admin-granted); always written through, like the enrollment consent.
        featuresDict["voice_clip_storage_consented"] = config.voiceClipStorageConsented
        // voiceprintHarvestEnabled — MDM-managed kill-switch (fail-closed). Don't
        // let the MDM-overlaid value clobber the user's stored preference.
        if !config.managedKeys.contains("voiceprintHarvestEnabled") {
            featuresDict["voiceprint_harvest_enabled"] = config.voiceprintHarvestEnabled
        } else if let existing = existingFeatures["voiceprint_harvest_enabled"] {
            featuresDict["voiceprint_harvest_enabled"] = existing
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

        // Enterprise OIDC federation preservation. Each of the seven
        // org-config fields can be MDM-pinned and is OMIT-WHEN-DEFAULT in
        // the JSON. The preservation rule differs from azureResource et al.
        // above precisely BECAUSE these fields are omit-when-default:
        //
        //  - PINNED + present on disk  → preserve the existing on-disk value
        //    (removing the MDM profile later restores the user's pre-MDM
        //    choice).
        //  - PINNED + ABSENT from disk → write NOTHING. Falling back to the
        //    effective managed value (the old `?? config.X`) would
        //    materialize the org's pinned value into ~/.parleq/config.json,
        //    where it would SURVIVE MDM-profile removal — leaking org config
        //    onto the user's disk. Absent-on-disk must stay absent.
        //  - UNPINNED → the effective in-memory value, still subject to the
        //    omit-when-default check at the emission sites below.
        //
        // So each computed value is an Optional<…> whose `nil` means "omit
        // this key entirely". The MDM key names differ from the JSON field
        // names where the plan dictates (oidcEphemeralBrowserSession ↔
        // ephemeral_browser). `preservedOrEffective` encodes the rule once.
        let existingOIDC = (existingDict["oidc"] as? [String: Any]) ?? [:]
        func preservedOrEffective<T>(_ key: String, _ onDisk: T?, _ effective: T) -> T? {
            // Pinned: keep only an actually-present on-disk value (nil → omit).
            // Unpinned: the effective value (emission site applies omit-when-default).
            config.managedKeys.contains(key) ? onDisk : effective
        }
        let oidcIssuerToWrite = preservedOrEffective(
            "oidcIssuer", existingOIDC["issuer"] as? String, config.oidcIssuer)
        let oidcClientIDToWrite = preservedOrEffective(
            "oidcClientID", existingOIDC["client_id"] as? String, config.oidcClientID)
        let oidcScopesToWrite = preservedOrEffective(
            "oidcScopes", existingOIDC["scopes"] as? [String], config.oidcScopes)
        let oidcEphemeralToWrite = preservedOrEffective(
            "oidcEphemeralBrowserSession", existingOIDC["ephemeral_browser"] as? Bool,
            config.oidcEphemeralBrowser)
        let oidcRedirectURIToWrite = preservedOrEffective(
            "oidcRedirectURI", existingOIDC["redirect_uri"] as? String, config.oidcRedirectURI)
        // extra_auth_params is [String: String] on disk; cast through
        // [String: Any] (JSONSerialization's bridged shape) then narrow,
        // mirroring how oidcScopes casts its [String]. nil on-disk → omit.
        let oidcExtraAuthParamsToWrite: [String: String]? = preservedOrEffective(
            "oidcExtraAuthParams",
            (existingOIDC["extra_auth_params"] as? [String: Any])
                .map { $0.compactMapValues { $0 as? String } },
            config.oidcExtraAuthParams)
        let awsRoleArnToWrite = preservedOrEffective(
            "awsRoleArn", existingAWS["role_arn"] as? String, config.awsRoleArn)
        let awsSessionDurationToWrite = preservedOrEffective(
            "awsSessionDurationSeconds", existingAWS["session_duration_seconds"] as? Int,
            config.awsSessionDurationSeconds)
        let vertexWorkforceProviderToWrite = preservedOrEffective(
            "vertexWorkforceProvider", existingVertex["workforce_provider"] as? String,
            config.vertexWorkforceProvider)

        // Start from the single-source-of-truth base serialization, then
        // apply save()'s extra semantics on top: MDM managed-key
        // preservation and the context_model CTX-pinning logic.
        var dict = Config.serializeToDictionary(config)

        // Patch ASR, LLM, AWS, Vertex, Azure sections with the
        // managed-override values computed above. These overwrite the
        // naive per-field values that serializeToDictionary put in.
        dict["asr"] = [
            "mode": config.asrMode,
            "endpoint": asrEndpointToWrite,
        ]
        var llmToWrite: [String: Any] = [
            "mode": config.llmMode,
            "provider": llmProviderToWrite,
            "model": llmModelToWrite,
        ]
        // Advanced tuning (#55) has no MDM key — it is purely the user's
        // value. Carry it forward (omit-when-default) so it round-trips
        // through save() rather than being dropped by the llm-section
        // rebuild above.
        if !config.llmTuning.isDefault {
            llmToWrite["tuning"] = Self.serializeLLMTuning(config.llmTuning)
        }
        // On-device cleanup tier — llm.local fields have no MDM key.
        // Carry forward (omit-when-default) same as tuning above.
        if let localToWrite = Self.serializeLocalSection(config) {
            llmToWrite["local"] = localToWrite
        }
        // Reframe v2: the global refinement TYPE has no MDM key — it's purely
        // the user's value. Carry it forward or the llm-section rebuild above
        // would drop it (serializeToDictionary emitted it, but dict["llm"] is
        // overwritten by llmToWrite), reverting a user's Instant/Raw choice to
        // the migrated default on the next load.
        llmToWrite["refinement"] = config.refinementType.rawValue
        // Refinement tier — llm.refine (omit-when-unset). Mirrors the
        // context_model preservation below: when the refine tier is
        // PINNED via MDM, preserve the existing on-disk value so removing
        // the profile restores the user's pre-MDM choice; otherwise write
        // the in-memory value. (serializeToDictionary already put a
        // refine key in, but the llm-section rebuild above overwrites it,
        // so it must be re-added here.)
        let rfnProviderPinned = config.managedKeys.contains("refineProvider")
        let rfnModelPinned    = config.managedKeys.contains("refineModel")
        let rfnModelAllowlist = config.managedKeys.contains("refineAllowedModels")
        let existingRefine = (existingLLM["refine"] as? [String: Any]) ?? [:]
        if rfnProviderPinned || rfnModelPinned {
            let existingProvider = (existingRefine["provider"] as? String) ?? ""
            let existingModel    = (existingRefine["model"] as? String) ?? ""
            let provider = rfnProviderPinned && !existingProvider.isEmpty
                ? existingProvider
                : (config.refineModel?.provider ?? "")
            // Model preservation — keep the provider/model pair COHERENT so a partial pin
            // never writes a mismatched pair:
            // (a) model pinned → always preserve the on-disk model.
            // (b) the preserved provider DIFFERS from the effective pinned provider → the
            //     in-memory model belongs to the effective (pinned) provider, NOT the
            //     preserved one, so preserve the on-disk model atomically (restoring the
            //     user's real pre-MDM pair when the profile is removed).
            // (c) preserved provider == effective provider (or allowlist) → the in-memory
            //     model is valid for that provider → write the in-memory choice.
            let rfnEffectiveProvider = config.refineModel?.provider ?? ""
            let rfnProviderDiffers = !provider.isEmpty && provider != rfnEffectiveProvider
            let preserveModel = rfnModelPinned
                || (rfnProviderPinned && !rfnModelAllowlist && rfnProviderDiffers)
            let model = preserveModel && !existingModel.isEmpty
                ? existingModel
                : (config.refineModel?.model ?? "")
            if !provider.isEmpty && !model.isEmpty {
                llmToWrite["refine"] = ["provider": provider, "model": model]
            }
            // else: pin resolved to "same as cleanup" → omit (no key).
        } else if let model = config.refineModel {
            llmToWrite["refine"] = ["provider": model.provider, "model": model.model]
        }
        dict["llm"] = llmToWrite
        var awsToWrite: [String: Any] = [
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
        // Enterprise OIDC federation — AWS leg fields, omit-when-default.
        // A nil *ToWrite means "pinned but absent on disk" → omit entirely
        // (don't materialize the org's managed value onto disk).
        if let roleArn = awsRoleArnToWrite, !roleArn.isEmpty {
            awsToWrite["role_arn"] = roleArn
        }
        if let dur = awsSessionDurationToWrite, dur != Config.default.awsSessionDurationSeconds {
            awsToWrite["session_duration_seconds"] = dur
        }
        dict["aws"] = awsToWrite
        var vertexToWrite: [String: Any] = [
            "project": vertexProjectToWrite,
            "region": vertexRegionToWrite,
            "auth_mode": vertexAuthModeToWrite,
            "anthropic_region": vertexAnthropicRegionToWrite,
        ]
        // Enterprise OIDC federation — GCP leg field, omit-when-default.
        // nil (pinned but absent on disk) → omit, never materialize.
        if let wp = vertexWorkforceProviderToWrite, !wp.isEmpty {
            vertexToWrite["workforce_provider"] = wp
        }
        dict["vertex"] = vertexToWrite
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

        // Enterprise OIDC federation — patch the top-level "oidc" section
        // with the MDM-preserved issuer/client_id/scopes/ephemeral values
        // computed above (serializeToDictionary emitted the effective
        // values; this overwrites them so a pinned field round-trips the
        // user's on-disk value). Each *ToWrite is optional: nil means
        // "pinned but absent on disk" → omit the key (never materialize the
        // managed value). Omit-when-default also applies to non-nil values,
        // so a default config writes no "oidc" key.
        var oidcToWrite: [String: Any] = [:]
        if let issuer = oidcIssuerToWrite, !issuer.isEmpty {
            oidcToWrite["issuer"] = issuer
        }
        if let clientID = oidcClientIDToWrite, !clientID.isEmpty {
            oidcToWrite["client_id"] = clientID
        }
        if let scopes = oidcScopesToWrite, scopes != Config.default.oidcScopes {
            oidcToWrite["scopes"] = scopes
        }
        if let ephemeral = oidcEphemeralToWrite, ephemeral != Config.default.oidcEphemeralBrowser {
            oidcToWrite["ephemeral_browser"] = ephemeral
        }
        if let redirectURI = oidcRedirectURIToWrite, redirectURI != Config.default.oidcRedirectURI {
            oidcToWrite["redirect_uri"] = redirectURI
        }
        if let extraParams = oidcExtraAuthParamsToWrite, !extraParams.isEmpty {
            oidcToWrite["extra_auth_params"] = extraParams
        }
        if oidcToWrite.isEmpty {
            dict.removeValue(forKey: "oidc")
        } else {
            dict["oidc"] = oidcToWrite
        }

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
            // Model preservation — three cases (mirrors the cleanup
            // tier above):
            // (a) ctxModelPinned → always preserve (user can't change).
            // (b) provider pinned + model unmanaged + on-disk model
            //     FOREIGN to the pinned context provider → preserve it
            //     (pre-MDM fallback for another provider; restored when
            //     the profile is removed).
            // (c) provider pinned + model unmanaged + on-disk model
            //     already CANONICAL for the pinned provider → user is
            //     picking within the pinned world: write the in-memory
            //     choice so it persists. (allowlist lands here too.)
            let ctxOnDiskModelForeign = !existingModel.isEmpty
                && !ModelCatalog.isCanonical(provider: provider, model: existingModel)
            let preserveModel = ctxModelPinned
                || (ctxProviderPinned && !ctxModelAllowlist && ctxOnDiskModelForeign)
            let model = preserveModel && !existingModel.isEmpty
                ? existingModel
                : (config.contextModel?.model ?? "")
            if !provider.isEmpty || !model.isEmpty {
                dict["context_model"] = ["provider": provider, "model": model]
            } else {
                dict.removeValue(forKey: "context_model")
            }
        }
        // (No else branch needed: dict comes fresh from
        // serializeToDictionary, which omits context_model when nil —
        // the key can't be present outside the pinned branch above.)

        // Preserve the hidden contribution-capture block verbatim. It is
        // intentionally NOT emitted by serializeToDictionary (so Settings
        // never writes or re-exposes it); copy it through from disk so a
        // Settings save can't silently drop a contributor's armed flag.
        if let contribution = existingDict["contribution"] {
            dict["contribution"] = contribution
        }
        return dict
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
    /// current state. Priority (highest first):
    ///   1. `override`  — the in-overlay ModelPicker's explicit pick.
    ///   2. references  — when references are attached, the Context tier
    ///      (`contextModel`) wins; references are the most capability-
    ///      sensitive turns and trump refine.
    ///   3. refine      — REFINE-shaped turns (`isRefine`: hotkey
    ///      voice-refine, quick chips, styled per-app-preset cleanup) are
    ///      powered by the SAME Polished provider as cleanup (the reframe
    ///      collapsed the separate Refine tier into Polished). They resolve
    ///      to the cleanup identifier; when that provider can't refine
    ///      (on-device Concord, or none) the runtime applies the append-only
    ///      fallback (`AppState.streamCleanupOrRefine`) rather than routing to
    ///      a different tier.
    ///   4. cleanup     — plain first-pass cleanup.
    /// nil tier values fall through to the next rung, so a user who sets
    /// nothing beyond cleanup gets unchanged single-provider behavior.
    public func modelForInvocation(
        hasReferences: Bool,
        isRefine: Bool = false,
        override: ModelIdentifier? = nil
    ) -> ModelIdentifier {
        if let override { return override }
        let cleanupId = ModelIdentifier(provider: llmProvider, model: llmModel)
        // Cleanup disabled ("none") is a GLOBAL off switch. The Context tier
        // is a sub-feature of cleanup, so when the user has opted out of
        // cleanup entirely, reference-aware turns must NOT route to a
        // (possibly still-configured) context tier — otherwise "skip cleanup,
        // paste raw" would silently keep sending the transcript (and reference
        // content) to that provider. Returning the cleanup identifier makes
        // the call path resolve to the nil cleanup provider and paste raw.
        if llmProvider == "none" {
            return cleanupId
        }
        // References win: a reference-aware turn routes to the context tier
        // even if it's also refine-shaped (references are the most
        // capability-sensitive turns). Context stays a separate provider.
        if hasReferences, let context = contextModel { return context }
        // Everything else — a Polished cleanup re-clean or a Polished refine —
        // is powered by the shared Polished provider (`llmProvider` when cleanup
        // is generative, else the refinement provider `refineModel`). This lets
        // a concord-cleanup user's refine / re-clean reach their cloud
        // refinement provider. Falls back to the cleanup id when no Polished
        // provider is configured (Concord/none) — the runtime then applies the
        // append-only fallback. `isRefine` no longer selects a different model;
        // it changes only prompt shape downstream.
        return polishedIdentifier ?? cleanupId
    }

    /// Whether a provider can perform a refine / style-transform turn — an
    /// instruction-following LLM task. The on-device Concord "Lightweight"
    /// tier is a deterministic corrector that can't, and "none" means cleanup
    /// is off, so neither qualifies. Used by the Settings refine card and the
    /// runtime refine guard so a refine never silently resolves to a provider
    /// that would no-op it.
    public static func providerCanRefine(_ provider: String) -> Bool {
        provider != "concord" && provider != "none"
    }
}

// MARK: - Cleanup/Refinement/Context reframe (three orthogonal settings)

extension Config {
    /// True iff `provider` is a generative (cloud/local) provider that can
    /// serve as the Polished tier. Open-world: anything that is not the
    /// on-device Concord tier ("concord") or the cleanup-off sentinel ("none")
    /// — and is non-empty — is a Polished provider. A new cloud provider added
    /// elsewhere needs no change here.
    public static func isGenerativeProvider(_ provider: String) -> Bool {
        !provider.isEmpty && provider != "concord" && provider != "none"
    }

    /// The global default CLEANUP type (per-app overridable via `appBehaviors`):
    /// the cleanup behavior for a target without an explicit or curated
    /// override. Derived from the legacy `llmProvider` (the cleanup config):
    ///   - "none"            → `.raw`     (no cleanup; send nothing to any cloud)
    ///   - "concord" / other → `.instant` (on-device Concord)
    ///   - a generative provider → `.polished` (cloud/local)
    public var cleanupType: TargetMode {
        if llmProvider == "none" { return .raw }
        if !Config.isGenerativeProvider(llmProvider) { return .instant }
        return .polished
    }

    /// The ONE shared Polished provider — the cloud/local service used by
    /// whichever of cleanup/refinement is set to Polished. It is the cleanup
    /// provider (`llmProvider`) when that is generative; otherwise the
    /// refinement provider (`refineModel`) when THAT is generative; else nil.
    /// (E.g. the maintainer's concord-cleanup + vertex-refine → "vertex".)
    public var polishedProvider: String? {
        if Config.isGenerativeProvider(llmProvider) { return llmProvider }
        if let rm = refineModel, Config.isGenerativeProvider(rm.provider) { return rm.provider }
        return nil
    }

    /// The model paired with `polishedProvider` (nil when none is configured).
    public var polishedModel: String? {
        if Config.isGenerativeProvider(llmProvider) { return llmModel }
        if let rm = refineModel, Config.isGenerativeProvider(rm.provider) { return rm.model }
        return nil
    }

    /// Whether a shared Polished provider is configured. When false, a
    /// Polished-resolved cleanup falls back to Instant (defensive) and Polished
    /// refinement falls back to append-only.
    public var hasPolishedProvider: Bool { polishedProvider != nil }

    /// The Polished provider + model as a `ModelIdentifier`, or nil.
    public var polishedIdentifier: ModelIdentifier? {
        guard let p = polishedProvider, let m = polishedModel else { return nil }
        return ModelIdentifier(provider: p, model: m)
    }
}
