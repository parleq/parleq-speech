import XCTest
import CryptoKit
import Foundation
@testable import ParleqAppCore

#if Concord
import Concord

/// C1 regression gate: decrypt a pre-sealed 0.29.0-format voiceprints blob.
///
/// The fixture was sealed by a throwaway raw `AES.GCM.seal + JSONEncoder` path,
/// NOT via `EncryptedVoiceprintStore.save()`. This is load-bearing: a format
/// change introduced by a future refactor of the store would bake the NEW format
/// into the fixture if the generator routed through the store, making the gate
/// test pass vacuously and never catch the regression.
///
/// `keyOverride` pins only the seal/JSON FORMAT (not Keychain identity). The
/// frozen-constants test in VoiceprintCryptoKeyTests is the key-identity guard.
final class VoiceprintBlobBackCompatTests: XCTestCase {

    /// Fixed 32-byte throwaway key. Baked into the sealed fixture — never changes.
    private static let fixedKey = SymmetricKey(data: Data(repeating: 7, count: 32))

    /// Path to the committed fixture blob (relative to this source file).
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/voiceprints-0.29.0.enc")
    }

    // MARK: - C1 gate test

    /// C1: verify that the committed 0.29.0-format blob can be decrypted and
    /// decoded correctly. Any future change to the encryption format or JSON
    /// codec path that would silently brick existing users' voiceprints will
    /// cause this test to fail loudly.
    func test_decrypts_0_29_0_blob() throws {
        let store = EncryptedVoiceprintStore(
            fileURL: Self.fixtureURL,
            keyOverride: Self.fixedKey
        )
        let templates = try store.load()
        XCTAssertEqual(templates.count, 1, "fixture must contain exactly 1 template")
        let tmpl = try XCTUnwrap(templates.first)
        XCTAssertEqual(tmpl.termID, "Keavi")
        XCTAssertEqual(tmpl.modelVersion, "0.15.4-encoder.1")
        XCTAssertFalse(tmpl.voiceprint.isEmpty, "voiceprint must be non-empty")
        XCTAssertEqual(tmpl.voiceprint.count, 5)
        XCTAssertFalse(tmpl.lowQuality)
        XCTAssertEqual(tmpl.dim, 5)
    }

    // MARK: - Fixture generator (disabled by default)

    /// One-shot fixture generator. Guarded by `GENERATE_FIXTURE=1` env var so it
    /// never overwrites the committed fixture on a normal `swift test` run.
    ///
    /// To regenerate (only when the template shape or key deliberately changes):
    ///   GENERATE_FIXTURE=1 swift test --traits Concord \
    ///     --filter VoiceprintBlobBackCompatTests/test_generateFixture_disabled
    /// Commit the resulting `Fixtures/voiceprints-0.29.0.enc`.
    ///
    /// IMPORTANT: uses raw `AES.GCM.seal + JSONEncoder`, NOT `EncryptedVoiceprintStore.save()`,
    /// so the fixture captures the canonical wire format independently of the store implementation.
    func test_generateFixture_disabled() throws {
        guard ProcessInfo.processInfo.environment["GENERATE_FIXTURE"] == "1" else {
            // Silently skip — not a real test, just a guarded generator.
            return
        }
        let template = VoiceprintTemplate(
            termID: "Keavi",
            voiceprint: [0.1, 0.2, 0.3, 0.4, 0.5],
            negatives: [:],
            dim: 5,
            lowQuality: false,
            modelVersion: "0.15.4-encoder.1"
        )
        // Raw seal — deliberately NOT routed through EncryptedVoiceprintStore.save().
        let json = try JSONEncoder().encode([template])
        let sealed = try AES.GCM.seal(json, using: Self.fixedKey)
        guard let combined = sealed.combined else {
            XCTFail("AES.GCM.seal returned nil combined")
            return
        }
        let fixtureDir = Self.fixtureURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        try combined.write(to: Self.fixtureURL)
        print("[VoiceprintBlobBackCompat] Fixture written (\(combined.count) bytes): \(Self.fixtureURL.path)")
    }
}
#endif
