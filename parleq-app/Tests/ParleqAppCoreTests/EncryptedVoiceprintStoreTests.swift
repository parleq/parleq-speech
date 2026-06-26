import XCTest
import CryptoKit
@testable import ParleqAppCore

#if Concord
import Concord

final class EncryptedVoiceprintStoreTests: XCTestCase {

    private let key = SymmetricKey(size: .bits256)   // fixed test key (no Keychain)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vp-test-\(UUID().uuidString).enc")
    }
    private func store(_ url: URL) -> EncryptedVoiceprintStore {
        EncryptedVoiceprintStore(fileURL: url, keyOverride: key)
    }
    private func template(_ id: String) -> VoiceprintTemplate {
        VoiceprintTemplate(termID: id, voiceprint: [0.1, 0.2, 0.3],
                           negatives: ["kiwi": [0.9, 0.8, 0.7]], dim: 3,
                           lowQuality: false, modelVersion: "v3")
    }

    func test_save_load_roundtrip_preserves_templates() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        let templates = [template("Keavi"), template("Claude")]
        try s.save(templates)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try s.load(), templates)
    }

    func test_file_is_encrypted_not_plaintext() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try store(url).save([template("SecretTerm")])
        let raw = try Data(contentsOf: url)
        XCTAssertNil(raw.range(of: Data("SecretTerm".utf8)),
                     "termID must not appear in the ciphertext")
        XCTAssertNil(raw.range(of: Data("kiwi".utf8)),
                     "negative label must not appear in the ciphertext")
    }

    func test_wrong_key_cannot_decrypt() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try store(url).save([template("Keavi")])
        let other = EncryptedVoiceprintStore(fileURL: url, keyOverride: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try other.load(), "a different key must fail to decrypt")
    }

    func test_load_missing_file_returns_empty() throws {
        XCTAssertEqual(try store(tempURL()).load(), [])
    }

    func test_save_empty_deletes_file() throws {
        let url = tempURL()
        let s = store(url)
        try s.save([template("X")])
        try s.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try s.load(), [])
    }

    func test_deleteAll_removes_file() throws {
        let url = tempURL()
        let s = store(url)
        try s.save([template("X")])
        try s.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
#endif
