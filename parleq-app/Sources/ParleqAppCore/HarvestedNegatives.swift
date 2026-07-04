// HarvestedNegatives — encrypted-at-rest store for auto-harvested voiceprint negatives.
//
// When the user corrects a dictionary-term over-fire (per-correction undo, or an
// E-edit changing an enrolled term back to a common word), Parleq pools that word's
// audio-span embedding and attaches it as a NEGATIVE prototype to the term's
// voiceprint (`VoiceprintTemplate.withNegative`). Because `withNegative` REPLACES a
// label's centroid rather than accumulating, the raw harvested embeddings are kept
// app-side in a bounded FIFO ring per (termID, confusable label) so the centroid can
// be recomputed on every attach — and healed when the user undoes a gate revert.
//
// Same posture as `voiceprints.enc`: this is BIOMETRIC-DERIVED data (pooled ~1024-float
// embeddings — never audio, never transcript text). It persists ONLY as an AES-256-GCM
// blob (`~/.parleq/harvested-negatives.enc`, 0600) under the SAME device-only,
// non-synchronizable Keychain key as the voiceprint store (`VoiceprintCryptoKey`).
// Deleting removes the file; wiped alongside voiceprints on "Delete all voiceprints"
// and by the harvest kill-switch's clear offer.

#if Concord
import Foundation
import CryptoKit
import Security

/// A bounded FIFO ring of raw harvested negative embeddings for one (termID, label) pair.
/// The label centroid attached to the template is recomputed from `enrollmentPrototype`
/// (if any) plus these embeddings on every mutation — never stored pre-pooled here, so a
/// mistaken harvest can be healed by dropping the newest embedding and recomputing.
public struct HarvestRing: Codable, Sendable, Equatable {
    /// Raw harvested embeddings, FIFO — newest LAST. Capped at `HarvestPolicy.maxPerLabel`.
    public var embeddings: [[Float]]
    /// Snapshot of the label's pre-harvest enrollment centroid (if the wizard had enrolled
    /// this confusable), so a wizard-declared negative is never discarded — it contributes
    /// as one element of the recomputed centroid.
    public var enrollmentPrototype: [Float]?
    /// `BundledASREngine.voiceprintEncoderIdentity` at first harvest. A ring whose stamp is
    /// neither current nor legacy-compatible is dropped at load (embeddings can't cross
    /// feature spaces, and — for privacy — no audio is retained to re-derive from).
    public var modelVersion: String

    public init(embeddings: [[Float]] = [], enrollmentPrototype: [Float]? = nil,
                modelVersion: String) {
        self.embeddings = embeddings
        self.enrollmentPrototype = enrollmentPrototype
        self.modelVersion = modelVersion
    }
}

/// The full harvested-negatives set: `termID → confusable label → ring`.
/// Label keys are normalized to lowercase by the harvest path (see `VoiceprintCoordinator`).
public struct HarvestedNegatives: Codable, Sendable, Equatable {
    public var rings: [String: [String: HarvestRing]]

    public init(rings: [String: [String: HarvestRing]] = [:]) {
        self.rings = rings
    }

    /// True when there is no ring content at all. A term key whose label map is
    /// empty (a "ghost" key left by removals) counts as empty too, so
    /// `save(_:)`'s empty ⇒ deleteAll contract can't be defeated by a vacuous
    /// outer key. Mutation sites should still prune empty inner maps; this
    /// makes the store fail safe if one slips through.
    public var isEmpty: Bool { rings.values.allSatisfy(\.isEmpty) }
}

/// Bounded-ring + diff policy constants (single source of truth for the harvest paths).
public enum HarvestPolicy {
    /// Ring cap per (termID, label). Enrollment builds a prototype from 3–5 carrier clips,
    /// so 8 real over-fire samples comfortably exceeds enrollment-grade statistical support;
    /// storage bounded at 8 × 1024 × 4 B = 32 KB per label; 8 bounds a junk sample's half-life.
    public static let maxPerLabel = 8
    /// Max position-wise word replacements an E-edit may carry and still harvest (a hand-fix,
    /// not a rewrite). See `EditDiff`.
    public static let maxEditReplacements = 3
}

/// Outcome of a `VoiceprintCoordinator.harvestNegative` / `healHarvestedNegative` call.
/// Every rejection is REPORTED (never a silent no-op) so callers/tests can distinguish
/// "attached" from the zero-junk skips.
public enum HarvestOutcome: Equatable, Sendable {
    case attached(ringCount: Int)
    case healed(ringCount: Int)
    case rejected(HarvestRejection)
}

/// Why a harvest/heal was refused. Zero-junk posture: any ambiguity resolves to a
/// rejection, never a best-effort attach.
public enum HarvestRejection: Equatable, Sendable {
    /// The term has no enrolled voiceprint to attach to.
    case noTemplate
    /// The label does not sound like the term (DoubleMetaphone primary mismatch)
    /// and is neither an alias nor an existing negative label.
    case phoneticMismatch
    /// Empty / non-finite / wrong-dimension embedding (would be a silent
    /// `withNegative` no-op masquerading as success).
    case unusableEmbedding
    /// Multi-word or non-alphabetic label (v1 harvests single words only).
    case multiWordLabel
    /// The label normalizes to the term itself (e.g. a case-only edit
    /// "Claude" → "claude") — attaching the term's own audio as a negative
    /// would poison the voiceprint into rejecting true matches.
    case selfLabel
    /// The `voiceprintHarvestEnabled` kill-switch is off.
    case disabled
    /// Heal requested but no harvested ring exists for (termID, label).
    case nothingToHeal
}

/// Persistence seam for the harvested-negatives store (mirrors `VoiceprintPersistence`).
/// An in-memory conformer is used in tests; `EncryptedHarvestStore` is the app backend.
public protocol HarvestedNegativePersistence: Sendable {
    func load() throws -> HarvestedNegatives
    /// Persist `negatives`. An empty set removes the file (deleteAll).
    func save(_ negatives: HarvestedNegatives) throws
    func deleteAll() throws
}

/// AES-256-GCM encrypted-at-rest backend. Structurally mirrors `EncryptedVoiceprintStore`
/// and shares the exact same `VoiceprintCryptoKey` device key (frozen Keychain constants).
public struct EncryptedHarvestStore: HarvestedNegativePersistence {
    private let fileURL: URL
    /// Test seam: a fixed key that bypasses the Keychain (the `swift test` binary may lack
    /// Keychain access). nil in the app → the Keychain-held device key.
    private let keyOverride: SymmetricKey?

    /// `fileURL` overridable for tests; defaults to `~/.parleq/harvested-negatives.enc`.
    public init(fileURL: URL? = nil, keyOverride: SymmetricKey? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parleq/harvested-negatives.enc")
        self.keyOverride = keyOverride
    }

    public func load() throws -> HarvestedNegatives {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return HarvestedNegatives() }
        let blob = try Data(contentsOf: fileURL)
        guard !blob.isEmpty else { return HarvestedNegatives() }
        let key = try VoiceprintCryptoKey.key(override: keyOverride)
        let box = try AES.GCM.SealedBox(combined: blob)
        let json = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(HarvestedNegatives.self, from: json)
    }

    public func save(_ negatives: HarvestedNegatives) throws {
        if negatives.isEmpty { try deleteAll(); return }
        let key = try VoiceprintCryptoKey.key(override: keyOverride)
        let json = try JSONEncoder().encode(negatives)
        let sealed = try AES.GCM.seal(json, using: key)
        guard let combined = sealed.combined else { throw VoiceprintPersistenceError.sealFailed }
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write to a 0600 temp first, then atomically replace — so the (encrypted)
        // biometric-derived blob is never briefly group/other-readable.
        let tmp = dir.appendingPathComponent(".harvested-negatives-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: tmp.path, contents: combined, attributes: [.posixPermissions: 0o600]) else {
            throw VoiceprintPersistenceError.writeFailed
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // `.usingNewMetadataOnly` so the replaced file keeps the temp's 0600 metadata
            // instead of inheriting a possibly-looser destination permission.
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
