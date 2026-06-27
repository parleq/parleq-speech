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
        let key = try VoiceprintCryptoKey.key(override: keyOverride)
        let box = try AES.GCM.SealedBox(combined: blob)
        let json = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode([VoiceprintTemplate].self, from: json)
    }

    public func save(_ templates: [VoiceprintTemplate]) throws {
        if templates.isEmpty { try deleteAll(); return }
        let key = try VoiceprintCryptoKey.key(override: keyOverride)
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
            // 7030: `.usingNewMetadataOnly` so the replaced file keeps the temp's
            // 0600 metadata instead of inheriting the destination's (possibly
            // looser) permissions — the biometric blob must stay owner-only.
            _ = try FileManager.default.replaceItemAt(
                fileURL, withItemAt: tmp, options: [.usingNewMetadataOnly])
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }

    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
#endif
