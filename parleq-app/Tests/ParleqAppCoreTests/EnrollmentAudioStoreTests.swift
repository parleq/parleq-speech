import XCTest
import CryptoKit
@testable import ParleqAppCore

#if Concord

final class EnrollmentAudioStoreTests: XCTestCase {

    private let key = SymmetricKey(size: .bits256)   // fixed test key (no Keychain)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ea-test-\(UUID().uuidString).enc")
    }

    private func store(_ url: URL) -> EnrollmentAudioStore {
        EnrollmentAudioStore(fileURL: url, keyOverride: key)
    }

    private func positiveClip() -> StoredEnrollmentClip {
        StoredEnrollmentClip(wav: Data([0x52, 0x49, 0x46, 0x46]),
                             carrierText: "say Keavi",
                             role: .positive, negativeLabel: nil)
    }

    private func negativeClip() -> StoredEnrollmentClip {
        StoredEnrollmentClip(wav: Data([0x7F, 0x45, 0x4C, 0x46]),
                             carrierText: "say kiwi",
                             role: .negative, negativeLabel: "kiwi")
    }

    // MARK: - Round-trip

    func test_roundtrip_preserves_clips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        let map: [String: [StoredEnrollmentClip]] = ["Keavi": [positiveClip(), negativeClip()]]
        try s.save(map)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try s.load(), map)
    }

    // MARK: - File permissions

    func test_file_permissions_are_0600() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try store(url).save(["Keavi": [positiveClip()]])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "enrollment-audio.enc must be owner-only (0600)")
    }

    // MARK: - Wrong-key decryption

    func test_wrong_key_cannot_decrypt() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try store(url).save(["Keavi": [positiveClip()]])
        let wrongStore = EnrollmentAudioStore(fileURL: url, keyOverride: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try wrongStore.load(), "a different key must fail to decrypt")
    }

    // MARK: - remove(termID:)

    func test_remove_termID_drops_term_keeps_others() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)
        try s.save(["Keavi": [positiveClip()], "Claude": [negativeClip()]])
        try s.remove(termID: "Keavi")
        let loaded = try s.load()
        XCTAssertNil(loaded["Keavi"], "removed termID must be absent")
        XCTAssertEqual(loaded["Claude"], [negativeClip()], "other termID must be preserved")
    }

    func test_remove_last_term_deletes_file() throws {
        let url = tempURL()
        let s = store(url)
        try s.save(["Keavi": [positiveClip()]])
        try s.remove(termID: "Keavi")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "removing the last term must delete the file")
        XCTAssertEqual(try s.load(), [:])
    }

    // MARK: - deleteAll / save([:]})

    func test_deleteAll_removes_file() throws {
        let url = tempURL()
        let s = store(url)
        try s.save(["Keavi": [positiveClip()]])
        try s.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_save_empty_map_removes_file() throws {
        let url = tempURL()
        let s = store(url)
        try s.save(["Keavi": [positiveClip()]])
        try s.save([:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "save([:]) must delete the file")
        XCTAssertEqual(try s.load(), [:])
    }

    func test_load_missing_file_returns_empty() throws {
        XCTAssertEqual(try store(tempURL()).load(), [:])
    }

    // MARK: - 7087: permission-fix path covered (overwrite scenario)

    /// Pre-create the destination with loose perms (0644), call save again,
    /// assert the result is still 0600.
    func test_7087_save_over_loose_perms_file_restores_0600() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = store(url)

        // First write — creates with 0600.
        try s.save(["Keavi": [positiveClip()]])

        // Loosen the permissions to simulate a file that somehow got 0644.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let looseBefore = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        XCTAssertEqual(looseBefore, 0o644, "test pre-condition: file is 0644 before the second save")

        // Second write — should restore 0600 via usingNewMetadataOnly atomic replace.
        try s.save(["Keavi": [positiveClip()], "Claude": [negativeClip()]])

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600,
                       "save over a loose-perms file must restore 0600 (usingNewMetadataOnly)")
    }

    // MARK: - R9: no-leak

    /// R9 — EnrollmentAudioStore must write ONLY to its fileURL's directory.
    /// No bytes must land in ~/.parleq/flywheel/ or ~/.parleq/usage.jsonl.
    func test_no_leak_store_writes_only_to_its_directory() throws {
        // Isolated temp dir — deliberately NOT under ~/.parleq.
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ea-noleak-\(UUID().uuidString)", isDirectory: true)
        // save() creates the dir via createDirectory(withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let url = storeDir.appendingPathComponent("enrollment-audio.enc")

        // Snapshot ~/.parleq state before the save.
        let parleqDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parleq")
        let flywheelDir = parleqDir.appendingPathComponent("flywheel")
        let usageLedger = parleqDir.appendingPathComponent("usage.jsonl")

        let flywheelBefore: Set<String>
        if FileManager.default.fileExists(atPath: flywheelDir.path),
           let contents = try? FileManager.default.contentsOfDirectory(atPath: flywheelDir.path) {
            flywheelBefore = Set(contents)
        } else {
            flywheelBefore = []
        }
        let usageMtimeBefore = (try? FileManager.default.attributesOfItem(
            atPath: usageLedger.path))?[.modificationDate] as? Date

        // Perform the save.
        let s = store(url)
        try s.save(["Keavi": [positiveClip(), negativeClip()]])

        // 1. storeDir must contain only the expected file — no leftover .tmp,
        //    no side-effect files anywhere else in this directory.
        let dirContents = try FileManager.default.contentsOfDirectory(atPath: storeDir.path)
        XCTAssertEqual(dirContents.sorted(), ["enrollment-audio.enc"],
                       "store must leave only enrollment-audio.enc in its directory — no tmp residue")

        // 2. storeDir must not be under ~/.parleq (test isolation sanity check).
        XCTAssertFalse(storeDir.path.hasPrefix(parleqDir.path),
                       "storeDir must be outside ~/.parleq — test is not isolated correctly")

        // 3. ~/.parleq/flywheel/ must not have gained new files.
        let flywheelAfter: Set<String>
        if FileManager.default.fileExists(atPath: flywheelDir.path),
           let contents = try? FileManager.default.contentsOfDirectory(atPath: flywheelDir.path) {
            flywheelAfter = Set(contents)
        } else {
            flywheelAfter = []
        }
        XCTAssertEqual(flywheelAfter, flywheelBefore,
                       "save must not write any file to ~/.parleq/flywheel/")

        // 4. usage.jsonl must not have been modified.
        let usageMtimeAfter = (try? FileManager.default.attributesOfItem(
            atPath: usageLedger.path))?[.modificationDate] as? Date
        XCTAssertEqual(usageMtimeAfter, usageMtimeBefore,
                       "save must not append to ~/.parleq/usage.jsonl")
    }
}
#endif
