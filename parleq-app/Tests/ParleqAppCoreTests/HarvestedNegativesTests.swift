import XCTest
import CryptoKit
@testable import ParleqAppCore

#if Concord
import Concord

/// Task 1 — `HarvestedNegatives` model + `EncryptedHarvestStore`.
/// Mirrors `EncryptedVoiceprintStoreTests`: fixed test key (no Keychain), temp file URL.
final class HarvestedNegativesTests: XCTestCase {

    private let key = SymmetricKey(size: .bits256)   // fixed test key (no Keychain)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("harvest-test-\(UUID().uuidString).enc")
    }
    private func store(_ url: URL) -> EncryptedHarvestStore {
        EncryptedHarvestStore(fileURL: url, keyOverride: key)
    }

    private func sample() -> HarvestedNegatives {
        let ringA = HarvestRing(
            embeddings: [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]],
            enrollmentPrototype: [0.9, 0.8, 0.7],
            modelVersion: "v3")
        let ringB = HarvestRing(
            embeddings: [[0.11, 0.22, 0.33]],
            enrollmentPrototype: nil,
            modelVersion: "v3")
        return HarvestedNegatives(rings: [
            "Claude": ["cloud": ringA, "clawed": ringB],
            "Keavi": ["kiwi": ringB],
        ])
    }

    func test_save_load_roundtrip_preserves_rings() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        let negatives = sample()
        try s.save(negatives)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try s.load(), negatives)
    }

    func test_save_empty_removes_file_and_load_missing_returns_empty() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        try s.save(sample())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try s.save(HarvestedNegatives())   // empty ⇒ deleteAll
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try s.load(), HarvestedNegatives())   // missing file ⇒ empty, no throw
    }

    func test_load_missing_file_returns_empty() throws {
        XCTAssertEqual(try store(tempURL()).load(), HarvestedNegatives())
    }

    func test_deleteAll_removes_file() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        try s.save(sample())
        try s.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_file_mode_is_0600_after_save() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try store(url).save(sample())
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func test_file_is_encrypted_not_plaintext() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try store(url).save(sample())
        let raw = try Data(contentsOf: url)
        XCTAssertNil(raw.range(of: Data("cloud".utf8)), "confusable label must not appear in ciphertext")
        XCTAssertNil(raw.range(of: Data("Claude".utf8)), "termID must not appear in ciphertext")
    }

    func test_corrupt_blob_throws_never_silently_truncates() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x00]).write(to: url)
        XCTAssertThrowsError(try store(url).load())
    }

    func test_isEmpty_reflects_rings() {
        XCTAssertTrue(HarvestedNegatives().isEmpty)
        XCTAssertFalse(sample().isEmpty)
        // A term key present but with an empty label map still counts as non-empty content?
        // Convention: isEmpty is true only when there are no rings at all.
        XCTAssertTrue(HarvestedNegatives(rings: [:]).isEmpty)
    }

    func test_policy_constants() {
        XCTAssertEqual(HarvestPolicy.maxPerLabel, 8)
        XCTAssertEqual(HarvestPolicy.maxEditReplacements, 3)
    }
}
#endif
