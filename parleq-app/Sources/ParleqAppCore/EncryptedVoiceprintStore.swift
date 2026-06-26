// EncryptedVoiceprintStore — encrypted-at-rest persistence for voiceprints.
//
// Voiceprints are BIOMETRIC data. Per the accepted privacy ADR they persist only
// as an AES-GCM-encrypted blob (`~/.parleq/voiceprints.enc`, 0600) under a random
// 256-bit key held in the Keychain — `AfterFirstUnlockThisDeviceOnly`, i.e.
// device-only and NON-synchronizable (never routed through iCloud Keychain). App-
// level encryption adds same-user process isolation (only Parleq can decrypt) and
// safety if the file lands in a backup/sync/copy, on top of FileVault.
//
// No audio is ever stored — only the derived embeddings (the Codable template).
// Deleting removes the file; the key may be left (an empty file decrypts to none).

#if Concord
import Foundation
import CryptoKit
import Concord
import Security

public enum VoiceprintPersistenceError: Error {
    case keychain(OSStatus)
    case sealFailed
    case writeFailed
}

public struct EncryptedVoiceprintStore: VoiceprintPersistence {
    private let fileURL: URL
    private let keyService = "com.parleq.app"
    private let keyAccount = "com.parleq.voiceprint.key"
    /// Test seam: a fixed key that bypasses the Keychain (the `swift test` binary
    /// may lack Keychain access). nil in the app → the Keychain-held device key.
    private let keyOverride: SymmetricKey?

    /// `fileURL` overridable for tests; defaults to `~/.parleq/voiceprints.enc`.
    public init(fileURL: URL? = nil, keyOverride: SymmetricKey? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parleq/voiceprints.enc")
        self.keyOverride = keyOverride
    }

    public func load() throws -> [VoiceprintTemplate] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let blob = try Data(contentsOf: fileURL)
        guard !blob.isEmpty else { return [] }
        let key = try loadOrCreateKey()
        let box = try AES.GCM.SealedBox(combined: blob)
        let json = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode([VoiceprintTemplate].self, from: json)
    }

    public func save(_ templates: [VoiceprintTemplate]) throws {
        if templates.isEmpty { try deleteAll(); return }
        let key = try loadOrCreateKey()
        let json = try JSONEncoder().encode(templates)
        let sealed = try AES.GCM.seal(json, using: key)
        guard let combined = sealed.combined else { throw VoiceprintPersistenceError.sealFailed }
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write to a 0600 temp first, then atomically replace — so the (encrypted)
        // biometric blob is never briefly group/other-readable.
        let tmp = dir.appendingPathComponent(".voiceprints-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: tmp.path, contents: combined, attributes: [.posixPermissions: 0o600]) else {
            throw VoiceprintPersistenceError.writeFailed
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }

    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Keychain key (device-only, non-synchronizable)

    private var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keyService,
         kSecAttrAccount as String: keyAccount]
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let keyOverride { return keyOverride }
        if let data = readKey() { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try storeKey(data)
        return key
    }

    private func readKey() -> Data? {
        var q = keyQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return data
    }

    private func storeKey(_ data: Data) throws {
        SecItemDelete(keyQuery as CFDictionary)   // replace any stale entry
        var q = keyQuery
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw VoiceprintPersistenceError.keychain(status) }
    }
}
#endif
