// EnrollmentAudioStore — encrypted-at-rest persistence for enrollment audio clips.
//
// Enrollment audio is BIOMETRIC data. Per the accepted privacy ADR it persists only
// as an AES-GCM-encrypted blob (`~/.parleq/enrollment-audio.enc`, 0600) under the
// shared voiceprint key in the Keychain — `AfterFirstUnlockThisDeviceOnly`, device-only,
// NON-synchronizable (never routed through iCloud Keychain). App-level encryption adds
// same-user process isolation and safety if the file lands in a backup/sync/copy,
// on top of FileVault.
//
// Clips are stored so voiceprints can be re-derived across an encoder change (SI-1).
// Deleting removes the file; the key may be left (decrypts to empty map).
// No audio is ever written anywhere except this file.

#if Concord
import Foundation
import CryptoKit

public enum ClipRole: String, Codable, Sendable {
    case positive, negative
}

public struct StoredEnrollmentClip: Codable, Equatable, Sendable {
    public let wav: Data
    public let carrierText: String
    public let role: ClipRole
    /// The confusable label, for `.negative` clips. nil for `.positive`.
    public let negativeLabel: String?

    public init(wav: Data, carrierText: String, role: ClipRole, negativeLabel: String?) {
        self.wav = wav
        self.carrierText = carrierText
        self.role = role
        self.negativeLabel = negativeLabel
    }
}

public protocol EnrollmentAudioPersistence {
    func load() throws -> [String: [StoredEnrollmentClip]]   // termID -> clips
    func save(_ byTerm: [String: [StoredEnrollmentClip]]) throws
    func remove(termID: String) throws
    func deleteAll() throws
}

public struct EnrollmentAudioStore: EnrollmentAudioPersistence {
    private let fileURL: URL
    /// Test seam: a fixed key that bypasses the Keychain (the `swift test` binary
    /// may lack Keychain access). nil in the app → the Keychain-held device key.
    private let keyOverride: SymmetricKey?

    /// `fileURL` overridable for tests; defaults to `~/.parleq/enrollment-audio.enc`.
    public init(fileURL: URL? = nil, keyOverride: SymmetricKey? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parleq/enrollment-audio.enc")
        self.keyOverride = keyOverride
    }

    public func load() throws -> [String: [StoredEnrollmentClip]] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let blob = try Data(contentsOf: fileURL)
        guard !blob.isEmpty else { return [:] }
        let key = try VoiceprintCryptoKey.key(override: keyOverride)
        let box = try AES.GCM.SealedBox(combined: blob)
        let json = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode([String: [StoredEnrollmentClip]].self, from: json)
    }

    public func save(_ byTerm: [String: [StoredEnrollmentClip]]) throws {
        if byTerm.isEmpty { try deleteAll(); return }
        let key = try VoiceprintCryptoKey.key(override: keyOverride)
        let json = try JSONEncoder().encode(byTerm)
        let sealed = try AES.GCM.seal(json, using: key)
        guard let combined = sealed.combined else { throw VoiceprintPersistenceError.sealFailed }
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write to a 0600 temp first, then atomically replace — so the (encrypted)
        // biometric blob is never briefly group/other-readable.
        let tmp = dir.appendingPathComponent(".enrollment-audio-\(UUID().uuidString).tmp")
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

    public func remove(termID: String) throws {
        var byTerm = try load()
        byTerm.removeValue(forKey: termID)
        try save(byTerm)
    }

    public func deleteAll() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
#endif
