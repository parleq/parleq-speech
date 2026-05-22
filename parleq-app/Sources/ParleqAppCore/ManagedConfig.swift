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
                if let val = managedBool(forKey: key) {
                    return "\(key)=\(val ? "true" : "false")"
                }
                if let val = managedString(forKey: key) {
                    // Sanitize URLs (only key that may contain userinfo /
                    // query tokens we don't want in the log). Other String
                    // managed keys (provider/model/auth-mode IDs) are
                    // non-sensitive.
                    if key == "sparkleUpdateFeedURL", let url = validateFeedURL(val) {
                        let safe = "\(url.scheme ?? "https")://\(url.host ?? "?")"
                        return "\(key)=\(safe)"
                    }
                    return "\(key)=\(val)"
                }
                if let val = managedStringArray(forKey: key) {
                    return "\(key)=[\(val.joined(separator: ","))]"
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
    ///   | none / unknown | —              | NO      |
    ///
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
    ///   - The bundled-ASR sentinel string verbatim (in-process FluidAudio).
    ///     We compare to the well-known `Config.bundledASREndpoint` literal
    ///     here rather than importing the type to avoid a layering cycle.
    ///   - An https:// URL with a non-empty host, no embedded userinfo, and
    ///     no query parameters. Plain http:// is REJECTED — the unmanaged
    ///     codepath accepts it for local-dev setups (sherpa-onnx on
    ///     127.0.0.1), but if an admin is pushing the endpoint via MDM the
    ///     intent is corporate routing, which must travel over TLS.
    ///
    /// Returns the trimmed value on success (so callers can store the
    /// validated form), or nil if any check fails.
    public static func validateASREndpoint(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Bundled sentinel — exact match required so a misspelling falls
        // into URL validation rather than silently being treated as bundled.
        if trimmed == "http://127.0.0.1:8767/inference" {
            return trimmed
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host, !host.isEmpty,
              (url.user == nil || url.user?.isEmpty == true),
              (url.password == nil || url.password?.isEmpty == true),
              url.query == nil
        else {
            return nil
        }
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
}
