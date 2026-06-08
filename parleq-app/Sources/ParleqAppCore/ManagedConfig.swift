// ManagedConfig — MDM read overlay for /Library/Managed Preferences.
//
// macOS Managed Configuration works by having the MDM push a
// `.mobileconfig` profile targeting the app's bundle ID. The OS writes
// the policy values to /Library/Managed Preferences/<bundleID>.plist.
// `CFPreferencesAppValueIsForced` distinguishes a managed value (pushed
// by MDM / written to /Library/Managed Preferences) from a value the
// user wrote to ~/Library/Preferences — the only reliable detection
// method on macOS. `CFPreferencesCopyAppValue` reads the effective value
// for the key, preferring /Library/Managed Preferences over the user
// domain when both are present.
//
// Usage from Config.load():
//
//   if let forced = ManagedConfig.managedBool(forKey: "referenceWindowsEnabled") {
//       c.referenceWindowsEnabled = forced
//       managedKeys.insert("referenceWindowsEnabled")
//   }
//
// Config.managedKeys: Set<String> tracks which keys came from MDM so
// Settings rows can call `.disabled(config.managedKeys.contains(key))`.
// The lock-icon badge UI (see ManagedIndicator.swift) reads the same set.

import CoreFoundation
import Foundation

public enum ManagedConfig {
    /// The bundle identifier used for managed-preferences lookups.
    /// Matches the app's CFBundleIdentifier in Info.plist.
    public static let bundleID = "com.parleq.app"

    /// Every managed-eligible key across Phase 1 (7 Bool keys),
    /// Phase 2 (8 string/array keys), Phase 3 (2 operational
    /// policy keys), Phase 4 (3 auth-mode restriction keys), and
    /// Phase 7 (1 auth-mode pin + 8 destination pins, closing the
    /// "use a different endpoint" exfiltration gaps within an
    /// otherwise-allowed provider).
    /// This is the single source of truth consumed by the Compliance
    /// Audit dialog, `allKeys`, and test coverage checks.
    /// autoUpdateEnabled is the Sparkle-side Bool.
    public static let allKeys: [String] = [
        // Phase 1 — Bool feature toggles
        "referenceWindowsEnabled",
        "clipboardReferenceEnabled",
        "imageReferenceEnabled",
        "fileReferenceEnabled",
        "customDictionaryEnabled",
        "customModelEntryEnabled",
        "autoUpdateEnabled",
        "livePricingEnabled",
        // Phase 2 — String / [String] provider & model lockdown
        "cleanupProvider",
        "cleanupAllowedProviders",
        "cleanupModel",
        "cleanupAllowedModels",
        "contextProvider",
        "contextAllowedProviders",
        "contextModel",
        "contextAllowedModels",
        // Phase 3 — operational policy
        "sparkleUpdateFeedURL",
        "loggingMode",
        // Phase 4 — auth-mode restrictions
        "staticApiKeysAllowed",
        "azureAuthMode",
        "bedrockAuthMode",
        // Phase 7 — destination pins. These close the "MDM pins
        // provider+model+auth-mode but the user re-targets the data
        // at a personal cloud account or attacker-controlled ASR
        // server" exfiltration class. Pin-only (no allowlist) —
        // orgs typically have ONE Vertex project, ONE Azure
        // resource, etc.; allowlist semantics can be added later
        // if a deployment asks for them.
        "vertexAuthMode",
        "asrEndpoint",
        "vertexProject",
        "vertexRegion",
        "vertexAnthropicRegion",
        "awsRegion",
        "awsProfile",
        "azureResource",
        "azureDeployment",
        // Phase 8 (0.14.0 PR 6, #221) — transcript-history retention.
        // Both Int, non-negative. 0 disables in-memory dictation
        // history entirely (zero-retention deployments). Either or
        // both can be set; whichever triggers first drops entries.
        // Default unmanaged behavior is "unlimited until quit" per
        // the in-memory invariant — no on-disk retention surface
        // either way.
        "transcriptHistoryMaxEntries",
        "transcriptHistoryRetentionHours",
        // Phase 9 — learn-from-corrections (opt-in feature + journal retention)
        "learnFromCorrectionsEnabled",
        "learnedCorrectionsMaxEntries",
        "learnedCorrectionsRetentionHours",
        // Transform presets — MDM off-switch for fleet-wide policy
        "transformPresetsEnabled",
        // Enterprise OIDC federation — issuer/client/scopes/ephemeral
        // sign-in pins plus the AWS (role ARN, STS session duration) and
        // GCP (workforce provider) federation-leg destination pins. All
        // org-config strings; the identity snapshot + refresh token stay
        // Keychain-only and are never managed-config surfaced.
        "oidcIssuer",
        "oidcClientID",
        "oidcScopes",
        "oidcEphemeralBrowserSession",
        // Generic-OP knobs: custom redirect URI (Google reversed-client-ID
        // scheme etc.) and extra authorization-request params (access_type /
        // prompt). Dictionary-typed; see managedStringDict.
        // `oidcRedirectURI` is also the control for the loopback-listener
        // carve-out: the loopback flow activates only for an http+loopback
        // redirect, so pinning a custom-scheme value here means a loopback
        // redirect can never be configured → the local listener never binds
        // (no dedicated "disable loopback" key is needed). See
        // makeOIDCAuthenticator in CompanyAccountView.swift.
        "oidcRedirectURI",
        "oidcExtraAuthParams",
        "awsRoleArn",
        "awsSessionDurationSeconds",
        "vertexWorkforceProvider",
    ]

    /// Subset of `allKeys` whose effective value is an Int.
    /// Used by the startup-summary helper (and any future
    /// type-aware dispatcher) to resolve via `managedInt`
    /// instead of `managedBool` — `managedBool` accepts a
    /// CFNumber 0/1 fallback for Bool keys, which would silently
    /// coerce an Int 5 → "true" if checked first.
    static let intTypedKeys: Set<String> = [
        "transcriptHistoryMaxEntries",
        "transcriptHistoryRetentionHours",
        "learnedCorrectionsMaxEntries",
        "learnedCorrectionsRetentionHours",
        // Enterprise OIDC federation — STS session duration (seconds).
        "awsSessionDurationSeconds",
    ]

    /// Emit a one-line startup summary of which managed keys were
    /// detected. Call this once after Config.load() completes so the
    /// user or admin can confirm via `tail ~/.parleq/app.log` that a
    /// plist override was picked up without code-spelunking.
    ///
    /// Example output (no managed keys):
    ///   [parleq] managed config: 0 keys managed (no /Library/Managed Preferences/com.parleq.app.plist override)
    ///
    /// Example output (two managed keys):
    ///   [parleq] managed config: 2 keys managed (referenceWindowsEnabled=false, imageReferenceEnabled=false)
    public static func logStartupSummary(managedKeys: Set<String>) {
        if managedKeys.isEmpty {
            let msg = "[parleq] managed config: 0 keys managed (no /Library/Managed Preferences/\(bundleID).plist override)"
            if let data = (msg + "\n").data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        } else {
            // Emit the key=value pairs for each managed key so the log
            // is self-contained — no need to also run `plutil -p ...`.
            let kvPairs = managedKeys.sorted().map { key -> String in
                // Int-typed keys must be resolved via managedInt
                // BEFORE managedBool — managedBool coerces a
                // CFNumber 0/1 into Bool true/false to handle MDM
                // tools that push 0/1 for boolean keys, but that
                // same coercion would silently log a managed
                // transcriptHistoryMaxEntries=5 as "true".
                if Self.intTypedKeys.contains(key),
                   let val = managedInt(forKey: key) {
                    return "\(key)=\(val)"
                }
                if let val = managedBool(forKey: key) {
                    return "\(key)=\(val ? "true" : "false")"
                }
                if let val = managedInt(forKey: key) {
                    return "\(key)=\(val)"
                }
                if let val = managedString(forKey: key) {
                    // Sanitize URLs that may carry userinfo / query / path
                    // tokens we don't want appearing in ~/.parleq/app.log.
                    // Other String managed keys (provider/model/auth-mode
                    // IDs) are non-sensitive and pass through verbatim.
                    //
                    // The Compliance Audit dialog (ManagedConfigAuditView)
                    // already strips paths from these URLs at render time;
                    // this is the symmetric server-side log sanitization
                    // so app.log stays consistent with what the audit
                    // dialog shows. Preserves scheme://host[:port] so
                    // operators can still tell at a glance whether the
                    // managed value pointed at the expected host, but
                    // drops path, query, and fragment.
                    if key == "sparkleUpdateFeedURL", let url = validateFeedURL(val) {
                        return "\(key)=\(sanitizedHostOnly(url))"
                    }
                    if key == "asrEndpoint" {
                        // Bundled sentinel is a non-URL string ("bundled"
                        // or similar) — log it verbatim. Only the
                        // network-URL form needs scrubbing.
                        if val == Config.bundledASREndpoint {
                            return "\(key)=\(val)"
                        }
                        if let validated = validateASREndpoint(val),
                           let url = URL(string: validated) {
                            return "\(key)=\(sanitizedHostOnly(url))"
                        }
                        // Failed validation — don't echo the raw value
                        // (it may contain credentials or tokens that
                        // got through some weaker upstream check); log
                        // the key as present with a placeholder.
                        return "\(key)=<invalid>"
                    }
                    return "\(key)=\(val)"
                }
                if let val = managedStringArray(forKey: key) {
                    return "\(key)=[\(val.joined(separator: ","))]"
                }
                if let val = managedStringDict(forKey: key) {
                    // Log the param NAMES only, not their values — keeps the
                    // log self-documenting without echoing arbitrary
                    // admin-pushed query-param values into app.log.
                    return "\(key)={\(val.keys.sorted().joined(separator: ","))}"
                }
                return key
            }.joined(separator: ", ")
            let msg = "[parleq] managed config: \(managedKeys.count) key\(managedKeys.count == 1 ? "" : "s") managed (\(kvPairs))"
            if let data = (msg + "\n").data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
    }

    /// Returns the MDM-managed Bool for `key`, or nil if the key is not
    /// managed (i.e., not present in /Library/Managed Preferences or is
    /// only user-stored in ~/Library/Preferences).
    ///
    /// Uses `CFPreferencesAppValueIsForced` to distinguish a managed
    /// value from a user-written one — a key that's in the user domain
    /// returns false from IsForced, so this correctly returns nil when
    /// the user set the key themselves (e.g., via a defaults write). Only
    /// values pushed by MDM (or, equivalently, written to
    /// /Library/Managed Preferences by a root-owned process) return
    /// non-nil here.
    public static func managedBool(forKey key: String) -> Bool? {
        let appID = bundleID as CFString
        let cfKey = key as CFString
        // IsForced returns true only when the effective value for this
        // key comes from a managed domain (kCFPreferencesAnyHost +
        // kCFPreferencesAnyUser or the local-machine managed domain).
        guard CFPreferencesAppValueIsForced(cfKey, appID) else {
            return nil
        }
        guard let raw = CFPreferencesCopyAppValue(cfKey, appID) else {
            // Key was forced but has no value — treat as unmanaged to
            // be safe; this shouldn't happen in practice.
            return nil
        }
        // The plist value should be a CFBoolean. Bridge it to Swift Bool.
        if let boolValue = raw as? Bool {
            return boolValue
        }
        // Some MDM payloads write integers (0 / 1) instead of booleans.
        if let intValue = raw as? Int {
            return intValue != 0
        }
        return nil
    }

    /// Returns the MDM-managed non-negative Int for `key`, or nil
    /// if the key is not managed, is not an Int value, or is
    /// negative. Same CFPreferencesAppValueIsForced semantics as
    /// `managedBool`. 0 is a valid sentinel value for "disable
    /// entirely" used by the transcript-retention keys
    /// (transcriptHistoryMaxEntries / transcriptHistoryRetentionHours,
    /// 0.14.0 PR 6 / #221). Negative integers are rejected so a
    /// fat-fingered `-1` MDM push doesn't underflow the retention
    /// sweep arithmetic.
    public static func managedInt(forKey key: String) -> Int? {
        let appID = bundleID as CFString
        let cfKey = key as CFString
        guard CFPreferencesAppValueIsForced(cfKey, appID) else {
            return nil
        }
        guard let raw = CFPreferencesCopyAppValue(cfKey, appID) else {
            return nil
        }
        // Bridge CFNumber → Swift Int. Some MDM tools also push
        // numeric values as String; accept that as a fallback.
        if let intValue = raw as? Int, intValue >= 0 {
            return intValue
        }
        if let str = raw as? String, let parsed = Int(str), parsed >= 0 {
            return parsed
        }
        return nil
    }

    /// Returns the MDM-managed String for `key`, or nil if the key is
    /// not managed or is not a string value. Same CFPreferencesAppValueIsForced
    /// semantics as `managedBool` — only values from /Library/Managed
    /// Preferences return non-nil; user-domain writes return nil.
    public static func managedString(forKey key: String) -> String? {
        let appID = bundleID as CFString
        let cfKey = key as CFString
        guard CFPreferencesAppValueIsForced(cfKey, appID) else {
            return nil
        }
        guard let raw = CFPreferencesCopyAppValue(cfKey, appID) else {
            return nil
        }
        // Bridge CFString → Swift String.
        return raw as? String
    }

    /// Returns true when `staticApiKeysAllowed=false` is managed AND the
    /// given provider/authMode combination uses a static-key auth path that
    /// the master switch blocks at runtime.
    ///
    /// This is the single source of truth for the Phase 5 runtime gate.
    /// Both `main.swift`'s `makeProvider` and the Settings UI consult this
    /// method rather than duplicating the per-provider logic.
    ///
    /// Provider-by-provider matrix:
    ///
    ///   | Provider       | Auth mode      | Blocked |
    ///   |----------------|----------------|---------|
    ///   | gemini         | (api-key only) | always  |
    ///   | openai         | (api-key only) | always  |
    ///   | bedrock-bearer | (api-key only) | always  |
    ///   | vertex         | serviceAccount | YES     |
    ///   | vertex         | adc            | NO      |
    ///   | azure          | apiKey         | YES     |
    ///   | azure          | azureAd        | NO      |
    ///   | bedrock        | static         | YES     |
    ///   | bedrock        | bedrockApiKey  | YES     |
    ///   | bedrock        | sso            | NO      |
    ///   | bedrock        | oidc           | NO      |
    ///   | vertex         | oidcFederation | NO      |
    ///   | vertex         | googleOAuth    | NO      |
    ///   | none / unknown | —              | NO      |
    ///
    /// The enterprise-OIDC federation modes ("oidc" for Bedrock,
    /// "oidcFederation" for Vertex) are federated — temporary credentials
    /// minted from a corporate sign-in, no static key on disk — so they
    /// are never blocked by `staticApiKeysAllowed=false`. The Vertex
    /// "googleOAuth" mode (native Google sign-in via the OIDC engine, the
    /// access token used directly as a Vertex bearer) likewise holds no
    /// static key on disk — only a refresh token in the Keychain, same as
    /// the federation modes — so it is also never blocked. They all fall
    /// through the existing string comparisons (≠ "static"/"bedrockApiKey"
    /// for Bedrock, ≠ "serviceAccount" for Vertex) to a NO result.
    ///
    /// Logging-mode policy values pinned by MDM via the `loggingMode`
    /// key. Recognized values today:
    ///   - `.lengthOnly` (default; Parleq's only current behavior)
    ///   - `.verbose`    (anticipated future; reserved for an opt-in
    ///                    verbose mode that does not yet exist)
    ///
    /// Existence of this accessor is the discoverability trap for a
    /// future PR that adds verbose logging: anyone introducing such a
    /// mode should grep for `ManagedConfig.loggingMode` to find this
    /// gate and route the new code through it. Without going through
    /// this accessor a verbose-mode PR would silently bypass any
    /// MDM-pinned `lengthOnly` policy. The unrecognized-value branch
    /// in `Config.applyManagedOverlay` ensures only the recognized
    /// rawValues reach this code path; any unknown plist value is
    /// logged + rejected upstream.
    public enum LoggingMode: String {
        case lengthOnly
        case verbose
    }

    /// Returns the MDM-pinned `LoggingMode`, or nil when unmanaged.
    /// Nil means "no policy expressed" — the app may use its default
    /// (length-only). When non-nil, code paths sensitive to the
    /// distinction (e.g. a future verbose-logging path) MUST honour
    /// the returned value.
    public static func loggingMode() -> LoggingMode? {
        guard let raw = managedString(forKey: "loggingMode") else {
            return nil
        }
        return LoggingMode(rawValue: raw)
    }

    /// Renders a URL as scheme://host[:port] only — drops path, query,
    /// fragment, and any userinfo. Used by `logStartupSummary` to
    /// scrub managed URLs (`sparkleUpdateFeedURL`, `asrEndpoint`)
    /// before they hit ~/.parleq/app.log. Port is preserved because
    /// non-standard ports are a useful operator signal (e.g. an
    /// internal ASR endpoint on :8443) and aren't sensitive on
    /// their own.
    private static func sanitizedHostOnly(_ url: URL) -> String {
        let scheme = url.scheme ?? "https"
        let host = url.host ?? "?"
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Strict validator for the managed `sparkleUpdateFeedURL` value.
    /// Centralized so `main.swift`, `Config.applyManagedOverlay`, and
    /// `ManagedConfigAuditView` all agree on what "valid" means.
    /// Requirements:
    ///   - scheme is exactly "https" (case-insensitive)
    ///   - non-empty host
    ///   - no embedded userinfo (user:password@host would ship credentials)
    ///   - no query parameters (appcasts are static XML; a query suggests
    ///     a tokenized URL that would leak via logs)
    ///
    /// Returns the parsed URL on success, nil if any check fails.
    public static func validateFeedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host, !host.isEmpty,
              (url.user == nil || url.user?.isEmpty == true),
              (url.password == nil || url.password?.isEmpty == true),
              url.query == nil
        else {
            return nil
        }
        return url
    }

    /// Strict validator for the managed `asrEndpoint` value. Centralized so
    /// `Config.applyManagedOverlay` and the UI gate agree on what "valid" means.
    ///
    /// Allowed forms:
    ///   - `Config.bundledASREndpoint` verbatim (in-process FluidAudio).
    ///   - An https:// URL with a non-empty host, no embedded userinfo, no
    ///     query parameters, and no fragment. Plain http:// is REJECTED —
    ///     the unmanaged codepath accepts it for local-dev setups
    ///     (sherpa-onnx on 127.0.0.1), but if an admin is pushing the
    ///     endpoint via MDM the intent is corporate routing, which must
    ///     travel over TLS. Fragments are rejected for the same reason as
    ///     queries: a tokenized URL ending in `#token=...` would still be
    ///     visible in the disabled TextField and the clipboard snapshot.
    ///
    /// Returns the trimmed value on success (so callers can store the
    /// validated form), or nil if any check fails.
    public static func validateASREndpoint(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Bundled sentinel — exact match required so a misspelling falls
        // into URL validation rather than silently being treated as bundled.
        if trimmed == Config.bundledASREndpoint {
            return trimmed
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host, !host.isEmpty,
              (url.user == nil || url.user?.isEmpty == true),
              (url.password == nil || url.password?.isEmpty == true),
              url.query == nil,
              url.fragment == nil
        else {
            return nil
        }
        return trimmed
    }

    /// Validates a managed OIDC issuer URL. Returns the trimmed value if it
    /// passes, nil otherwise. Mirrors the HTTPS-or-loopback-HTTP rule that
    /// `OIDCSession.discover` enforces (and `OIDCDiscovery.parse` applies to the
    /// discovered endpoints) — so an MDM-pushed `http://…` non-loopback issuer
    /// fails closed AT LOAD rather than only later at discovery time. A
    /// plain-HTTP non-loopback issuer would let a network attacker substitute a
    /// discovery document and redirect every subsequent token exchange.
    public static func validateOIDCIssuer(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // The issuer may carry a trailing slash (discover() strips it); parse
        // the bare value so the scheme/host checks see the real URL shape.
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && isLoopbackHost(url))
        else {
            return nil
        }
        return trimmed
    }

    /// Validates an OIDC redirect_uri. Returns the trimmed value if it passes,
    /// nil otherwise. Two interception mechanisms are supported, so two redirect
    /// shapes are accepted:
    ///   - A NON-http/https custom scheme (`parleq-auth:` or a reversed-client-ID
    ///     `com.googleusercontent.apps.…:` shape) — intercepted in-process by
    ///     ASWebAuthenticationSession.
    ///   - An `http://` LOOPBACK redirect (`http://127.0.0.1[:port]/path`,
    ///     `http://localhost/…`, `http://[::1]/…`) — Google's CURRENT "Desktop
    ///     app" client guidance. ASWebAuthenticationSession can't intercept this,
    ///     so a transient 127.0.0.1-only listener answers the callback. The PORT
    ///     in the configured value is IGNORED at runtime (an ephemeral port is
    ///     always bound); the PATH is preserved. The HOST is normalized to
    ///     `127.0.0.1` at runtime even if configured as `localhost`/`[::1]` (the
    ///     listener binds 127.0.0.1) — fine for Google (accepts any loopback
    ///     host); use `127.0.0.1` for IdPs with byte-exact redirect matching.
    /// `https://` is rejected (can't be intercepted AND can't be served by the
    /// loopback listener) and `http://` on a NON-loopback host is rejected (a
    /// network attacker could answer it). Used by the MDM overlay and the JSON
    /// config-load path so the rule is defined once.
    public static func validateOIDCRedirectURI(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), !scheme.isEmpty
        else {
            return nil
        }
        // https can be neither intercepted nor served — always reject.
        if scheme == "https" { return nil }
        // http is accepted for loopback hosts only (the Desktop-app loopback
        // flow); a non-loopback http redirect is rejected.
        if scheme == "http" { return isLoopbackHost(url) ? trimmed : nil }
        // Any other (custom) scheme → ASWebAuthenticationSession path.
        return trimmed
    }

    /// Returns false when `staticApiKeysAllowed` is not managed or is true.
    public static func isProviderAuthPathBlocked(provider: String, authMode: String?) -> Bool {
        // Only active when staticApiKeysAllowed is managed AND set to false.
        guard managedBool(forKey: "staticApiKeysAllowed") == false else {
            return false
        }
        return isProviderAuthPathBlocked(
            provider: provider,
            authMode: authMode,
            staticApiKeysAllowed: false
        )
    }

    /// Internal/test-visible variant that takes `staticApiKeysAllowed`
    /// as an explicit parameter rather than reading from CFPreferences.
    /// Lets unit tests exercise the real matrix without needing a live
    /// MDM profile. Production code goes through the no-arg public
    /// variant above.
    static func isProviderAuthPathBlocked(
        provider: String,
        authMode: String?,
        staticApiKeysAllowed: Bool
    ) -> Bool {
        // Master switch on → nothing is ever blocked.
        guard !staticApiKeysAllowed else { return false }

        switch provider.lowercased() {
        case "gemini":
            // API-key only — always blocked when master switch is off.
            return true
        case "openai":
            // API-key only — always blocked.
            return true
        case "bedrock-bearer":
            // Bearer-token only — always blocked.
            return true
        case "vertex":
            // serviceAccount path uses a static JSON key (Keychain-stored).
            // adc (Application Default Credentials via gcloud) is federated.
            // Nil-default is "adc" (federated) — matches Config.swift's
            // vertexAuthMode default and means an uninitialized vertex
            // config doesn't accidentally appear blocked.
            return (authMode ?? "adc") == "serviceAccount"
        case "azure":
            // apiKey path uses a static resource API key (Keychain-stored).
            // azureAd (Entra ID via az login) is federated.
            // Nil-default is "apiKey" (blocked) — matches Config.swift's
            // azureAuthMode default. Asymmetric with Vertex above; that's
            // intentional and reflects the two providers' default auth
            // modes, not a policy difference.
            return (authMode ?? "apiKey") == "apiKey"
        case "bedrock":
            // static and bedrockApiKey are static-key paths.
            // sso (AWS CLI session) is federated.
            let mode = (authMode ?? "sso").lowercased()
            return mode == "static" || mode == "bedrockapikey"
        default:
            // "none" and any unknown future provider — never blocked.
            return false
        }
    }

    /// Returns the MDM-managed [String] for `key`, or nil if the key is
    /// not managed or is not an array value. Filters out any non-String
    /// elements in the CFArray to ensure the caller always gets a clean
    /// [String] (malformed profiles occasionally include mixed-type arrays).
    ///
    /// Same CFPreferencesAppValueIsForced semantics as `managedBool`.
    public static func managedStringArray(forKey key: String) -> [String]? {
        let appID = bundleID as CFString
        let cfKey = key as CFString
        guard CFPreferencesAppValueIsForced(cfKey, appID) else {
            return nil
        }
        guard let raw = CFPreferencesCopyAppValue(cfKey, appID) else {
            return nil
        }
        // CFArray bridges to [Any] in Swift. Filter to String elements only.
        guard let array = raw as? [Any] else {
            return nil
        }
        let strings = array.compactMap { $0 as? String }
        // Return nil for an empty or fully non-String array — treat
        // a managed empty array as "no restriction" to avoid accidental lockout.
        return strings.isEmpty ? nil : strings
    }

    /// Returns the MDM-managed [String: String] dictionary for `key`, or nil
    /// if the key is not managed or has no usable string-valued entries.
    /// Non-String values are dropped element-wise (malformed profiles
    /// occasionally include mixed-type dictionaries). An empty result is
    /// returned as nil — a managed empty dict is treated as "unset" so it
    /// can't accidentally override a non-empty default.
    ///
    /// Same CFPreferencesAppValueIsForced semantics as `managedBool`.
    /// Used by the OIDC extra-auth-params pin (oidcExtraAuthParams).
    public static func managedStringDict(forKey key: String) -> [String: String]? {
        let appID = bundleID as CFString
        let cfKey = key as CFString
        guard CFPreferencesAppValueIsForced(cfKey, appID) else {
            return nil
        }
        guard let raw = CFPreferencesCopyAppValue(cfKey, appID) else {
            return nil
        }
        // CFDictionary bridges to [String: Any] (or [AnyHashable: Any]).
        // Narrow to String→String, dropping non-String values.
        guard let dict = raw as? [String: Any] else {
            return nil
        }
        let strings = dict.compactMapValues { $0 as? String }
        return strings.isEmpty ? nil : strings
    }
}
