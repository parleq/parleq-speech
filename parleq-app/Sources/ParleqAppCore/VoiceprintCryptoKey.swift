// VoiceprintCryptoKey — shared Keychain AES key for encrypted voiceprint blobs.
//
// SI-1 FROZEN INVARIANT: keyService and keyAccount must never change.
// Blobs written since 0.29.0 are sealed under the Keychain item identified by
// these exact strings. Changing either string permanently bricks every existing
// user's encrypted voiceprints — the ciphertext can no longer be decrypted.

#if Concord
import Foundation
import CryptoKit
import Security

public enum VoiceprintCryptoKey {
    // FROZEN — never change these strings (SI-1). 0.29.0 blobs are sealed under this exact item.
    public static let keyService = "com.parleq.app"
    public static let keyAccount = "com.parleq.voiceprint.key"

    // Single-flight lock: prevents two concurrent first-callers from both
    // deleting and minting a new key. NSLock is Sendable so no nonisolated(unsafe).
    private static let keyCreationLock = NSLock()

    /// Returns the device key, creating it once (single-flight) if absent.
    /// `override` bypasses the Keychain and is used only in tests.
    public static func key(override: SymmetricKey?) throws -> SymmetricKey {
        if let override { return override }
        keyCreationLock.lock()
        defer { keyCreationLock.unlock() }
        // Re-check inside the lock: another caller may have created the key
        // while we were waiting. Avoids double-delete + double-mint.
        if let data = readKey() { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try storeKey(data)
        return key
    }

    // MARK: - Private Keychain helpers

    private static var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keyService,
         kSecAttrAccount as String: keyAccount]
    }

    private static func readKey() -> Data? {
        var q = keyQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return data
    }

    private static func storeKey(_ data: Data) throws {
        SecItemDelete(keyQuery as CFDictionary)   // replace any stale entry
        var q = keyQuery
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw VoiceprintPersistenceError.keychain(status) }
    }
}
#endif
