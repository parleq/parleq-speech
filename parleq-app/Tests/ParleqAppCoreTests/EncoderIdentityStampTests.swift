import XCTest
@testable import ParleqAppCore

#if Concord
import Concord

/// Minimal spy that records every persistence call so tests can assert
/// that `loadPersisted` never writes (SI-1: the blob is never emptied by a load).
private final class SpyVoiceprintPersistence: VoiceprintPersistence, @unchecked Sendable {
    var toLoad: [VoiceprintTemplate] = []
    private(set) var saveCallCount = 0
    private(set) var lastSaved: [VoiceprintTemplate]?
    func load() throws -> [VoiceprintTemplate] { toLoad }
    func save(_ t: [VoiceprintTemplate]) throws { saveCallCount += 1; lastSaved = t }
    func deleteAll() throws { saveCallCount += 1; lastSaved = [] }
}

/// Helpers to build `VoiceprintTemplate` test fixtures.
private func makeTemplate(termID: String, modelVersion: String, voiceprint: [Float] = [0.1, 0.2, 0.3]) -> VoiceprintTemplate {
    VoiceprintTemplate(
        termID: termID,
        voiceprint: voiceprint,
        negatives: [:],
        dim: 3,
        lowQuality: false,
        modelVersion: modelVersion
    )
}

// MARK: -

@MainActor
final class EncoderIdentityStampTests: XCTestCase {

    // MARK: - Constant shape

    /// The encoder identity is a human-stable name tied to the Parakeet model
    /// graph, NOT the FluidAudio package version.
    func test_voiceprintEncoderIdentity_is_not_fluidAudioVersion() {
        XCTAssertNotEqual(
            BundledASREngine.voiceprintEncoderIdentity,
            BundledASREngine.fluidAudioVersion,
            "voiceprintEncoderIdentity must be a separate, stable encoder name"
        )
    }

    /// The legacy stamp produced by 0.29.0 must be declared as compatible so
    /// existing enrolled users are grandfathered after the upgrade.
    func test_legacyCompatibleStamps_contains_0_29_0_stamp() {
        XCTAssertTrue(
            BundledASREngine.legacyCompatibleStamps.contains("0.15.4-encoder.1"),
            "legacyCompatibleStamps must include '0.15.4-encoder.1' (the 0.29.0 stamp)"
        )
    }

    // MARK: - loadPersisted: keep predicate

    /// SI-1 guard: `loadPersisted` must never call `save` or `deleteAll`.
    /// A single write path dropped/emptied the on-disk blob (the R1 footgun).
    func test_loadPersisted_never_writes_blob() {
        let coordinator = VoiceprintCoordinator()
        let spy = SpyVoiceprintPersistence()
        // Provide a mix of kept + unknown-stamp templates to trigger the old
        // re-persist branch that was the footgun.
        spy.toLoad = [
            makeTemplate(termID: "Alpha", modelVersion: BundledASREngine.voiceprintEncoderIdentity),
            makeTemplate(termID: "Beta",  modelVersion: "0.9.9-unknown-model"),
        ]
        coordinator.persistence = spy
        coordinator.loadPersisted()

        // SI-1: the spy must record zero writes.
        XCTAssertEqual(spy.saveCallCount, 0,
            "loadPersisted must NEVER call save/deleteAll — the blob is owned by migration, not loading (SI-1)")
    }

    /// A template stamped with `voiceprintEncoderIdentity` (the new stamp) is
    /// upserted into the store.
    func test_current_identity_template_is_kept() {
        let coordinator = VoiceprintCoordinator()
        let spy = SpyVoiceprintPersistence()
        spy.toLoad = [
            makeTemplate(termID: "CurrentTerm", modelVersion: BundledASREngine.voiceprintEncoderIdentity),
        ]
        coordinator.persistence = spy
        coordinator.loadPersisted()

        XCTAssertTrue(coordinator.hasVoiceprint("CurrentTerm"),
            "template stamped with voiceprintEncoderIdentity must be kept in the store")
    }

    /// A template stamped with the legacy 0.29.0 stamp is grandfathered into the
    /// store (the encoder graph/weights did NOT change between 0.29.0 and this
    /// release, so its embeddings are still compatible).
    func test_legacy_stamp_template_is_kept() {
        let coordinator = VoiceprintCoordinator()
        let spy = SpyVoiceprintPersistence()
        spy.toLoad = [
            makeTemplate(termID: "LegacyTerm", modelVersion: "0.15.4-encoder.1"),
        ]
        coordinator.persistence = spy
        coordinator.loadPersisted()

        XCTAssertTrue(coordinator.hasVoiceprint("LegacyTerm"),
            "template stamped with legacy 0.15.4-encoder.1 stamp must be kept (grandfathered)")
    }

    /// A template with an UNKNOWN encoder stamp (neither current nor a declared
    /// legacy-compatible stamp) must NOT be kept in the store.
    func test_unknown_stamp_template_is_not_kept() {
        let coordinator = VoiceprintCoordinator()
        let spy = SpyVoiceprintPersistence()
        spy.toLoad = [
            makeTemplate(termID: "UnknownTerm", modelVersion: "0.9.9-x"),
        ]
        coordinator.persistence = spy
        coordinator.loadPersisted()

        XCTAssertFalse(coordinator.hasVoiceprint("UnknownTerm"),
            "template with unknown encoder stamp must not be upserted into the store")
    }

    /// A template with an empty voiceprint slice must NEVER be upserted, even if
    /// the stamp is a legacy-compatible one. An empty embedding corrupts the gate.
    func test_empty_voiceprint_legacy_template_is_not_kept() {
        let coordinator = VoiceprintCoordinator()
        let spy = SpyVoiceprintPersistence()
        spy.toLoad = [
            makeTemplate(termID: "EmptyLegacy", modelVersion: "0.15.4-encoder.1", voiceprint: []),
        ]
        coordinator.persistence = spy
        coordinator.loadPersisted()

        XCTAssertFalse(coordinator.hasVoiceprint("EmptyLegacy"),
            "empty-voiceprint template must never be upserted even with a legacy-compatible stamp")
    }

    // MARK: - pendingMigration

    /// An unknown-stamp template with a non-empty voiceprint belongs in
    /// `pendingMigration` so a future migration pass can re-stamp it.
    func test_unknown_stamp_nonempty_goes_to_pendingMigration() {
        let coordinator = VoiceprintCoordinator()
        let spy = SpyVoiceprintPersistence()
        let unknownTmpl = makeTemplate(termID: "UnknownTerm", modelVersion: "0.9.9-x")
        spy.toLoad = [unknownTmpl]
        coordinator.persistence = spy
        coordinator.loadPersisted()

        XCTAssertEqual(coordinator.pendingMigration.count, 1,
            "unknown-stamp non-empty template must land in pendingMigration")
        XCTAssertEqual(coordinator.pendingMigration.first?.termID, "UnknownTerm")
    }

    /// A kept template must NOT appear in `pendingMigration`.
    func test_kept_templates_are_not_in_pendingMigration() {
        let coordinator = VoiceprintCoordinator()
        let spy = SpyVoiceprintPersistence()
        spy.toLoad = [
            makeTemplate(termID: "CurrentTerm",  modelVersion: BundledASREngine.voiceprintEncoderIdentity),
            makeTemplate(termID: "LegacyTerm",   modelVersion: "0.15.4-encoder.1"),
        ]
        coordinator.persistence = spy
        coordinator.loadPersisted()

        XCTAssertEqual(coordinator.pendingMigration.count, 0,
            "no kept templates should appear in pendingMigration")
    }

    /// An empty-voiceprint template must NOT appear in `pendingMigration` — it is
    /// unmigratable (no embeddings to carry forward).
    func test_empty_voiceprint_not_in_pendingMigration() {
        let coordinator = VoiceprintCoordinator()
        let spy = SpyVoiceprintPersistence()
        spy.toLoad = [
            makeTemplate(termID: "EmptyLegacy", modelVersion: "0.15.4-encoder.1", voiceprint: []),
        ]
        coordinator.persistence = spy
        coordinator.loadPersisted()

        XCTAssertEqual(coordinator.pendingMigration.count, 0,
            "empty-voiceprint template is unmigratable; must not be in pendingMigration")
    }

    // MARK: - Combined scenario

    /// The full mixed-bag scenario: current + legacy(non-empty) + unknown + empty-legacy.
    /// Asserts all four outcomes in one shot:
    ///   • current & legacy → store
    ///   • empty-legacy → neither store nor pendingMigration
    ///   • unknown → pendingMigration only
    ///   • saveCallCount == 0  (SI-1)
    func test_mixed_load_distributes_correctly_and_never_writes() {
        let coordinator = VoiceprintCoordinator()
        let spy = SpyVoiceprintPersistence()

        spy.toLoad = [
            makeTemplate(termID: "CurrentTerm",  modelVersion: BundledASREngine.voiceprintEncoderIdentity),
            makeTemplate(termID: "LegacyTerm",   modelVersion: "0.15.4-encoder.1"),
            makeTemplate(termID: "UnknownTerm",  modelVersion: "0.9.9-x"),
            makeTemplate(termID: "EmptyLegacy",  modelVersion: "0.15.4-encoder.1", voiceprint: []),
        ]
        coordinator.persistence = spy
        coordinator.loadPersisted()

        // Store contents
        XCTAssertTrue(coordinator.hasVoiceprint("CurrentTerm"))
        XCTAssertTrue(coordinator.hasVoiceprint("LegacyTerm"))
        XCTAssertFalse(coordinator.hasVoiceprint("UnknownTerm"))
        XCTAssertFalse(coordinator.hasVoiceprint("EmptyLegacy"))

        // pendingMigration
        XCTAssertEqual(coordinator.pendingMigration.count, 1)
        XCTAssertEqual(coordinator.pendingMigration.first?.termID, "UnknownTerm")

        // SI-1: zero writes
        XCTAssertEqual(spy.saveCallCount, 0,
            "loadPersisted must never write (SI-1)")
    }
}

#endif
