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
// The lock-icon badge UI (Phase 6) will read the same set.

import CoreFoundation
import Foundation

public enum ManagedConfig {
    /// The bundle identifier used for managed-preferences lookups.
    /// Matches the app's CFBundleIdentifier in Info.plist.
    public static let bundleID = "com.parleq.app"

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
}
