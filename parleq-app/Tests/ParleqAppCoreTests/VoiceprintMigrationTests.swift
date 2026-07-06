import XCTest
@testable import ParleqAppCore

#if Concord
import Concord
import FluidAudio

/// Records persistence calls; load result injectable. (Mirrors the spy in
/// VoiceprintCoordinatorTests but exposed here for the migration asserts.)
private final class SpyVoiceprintPersistence: VoiceprintPersistence, @unchecked Sendable {
    var loadResult: Result<[VoiceprintTemplate], Error>
    private(set) var saved: [[VoiceprintTemplate]] = []
    private(set) var deletedCount = 0
    init(_ loadResult: Result<[VoiceprintTemplate], Error>) { self.loadResult = loadResult }
    func load() throws -> [VoiceprintTemplate] { try loadResult.get() }
    func save(_ templates: [VoiceprintTemplate]) throws { saved.append(templates) }
    func deleteAll() throws { deletedCount += 1 }
    var saveCallCount: Int { saved.count }
    var lastSaved: [VoiceprintTemplate]? { saved.last }
}

/// Audio persistence stub: a fixed map (or a throwing load) plus call recording.
private final class StubAudioPersistence: EnrollmentAudioPersistence, @unchecked Sendable {
    var loadResult: Result<[String: [StoredEnrollmentClip]], Error>
    private(set) var deletedCount = 0
    init(_ loadResult: Result<[String: [StoredEnrollmentClip]], Error>) { self.loadResult = loadResult }
    func load() throws -> [String: [StoredEnrollmentClip]] { try loadResult.get() }
    func save(_ byTerm: [String: [StoredEnrollmentClip]]) throws {}
    func remove(termID: String) throws {}
    func deleteAll() throws { deletedCount += 1 }
}

private struct StubError: Error {}

@MainActor
final class VoiceprintMigrationTests: XCTestCase {

    // MARK: - Test fixtures

    private static let oldStamp = "ancient-encoder-v0"

    /// A non-empty template with an UNKNOWN stamp — so loadPersisted parks it in
    /// `pendingMigration`.
    private func staleTemplate(_ id: String) -> VoiceprintTemplate {
        VoiceprintTemplate(termID: id, voiceprint: [0.1, 0.2, 0.3, 0.4], dim: 4,
                           lowQuality: false, modelVersion: Self.oldStamp)
    }

    /// A stub `transcribe` returning a fixed FluidAudio result with FOUR word
    /// groups (so carrier slots 0…3 resolve) and a constant pooled embedding
    /// ([1,0,0,0]) for every span — identical embeddings → high self-similarity.
    private func goodTranscribe() -> (Data) async throws -> ASRResult? {
        let timings: [TokenTiming] = [
            TokenTiming(token: " Alpha", tokenId: 1, startTime: 0.00, endTime: 0.50, confidence: 1),
            TokenTiming(token: " is",    tokenId: 2, startTime: 0.60, endTime: 0.80, confidence: 1),
            TokenTiming(token: " a",     tokenId: 3, startTime: 0.90, endTime: 1.00, confidence: 1),
            TokenTiming(token: " kiwi",  tokenId: 4, startTime: 1.10, endTime: 1.60, confidence: 1),
        ]
        let hidden = 4
        let frames = Array(repeating: [Float](arrayLiteral: 1, 0, 0, 0), count: 40)
        let window = EncoderFeatureSequence.Window(frames: frames, globalFrameOffset: 0)
        let features = EncoderFeatureSequence(windows: [window], hiddenSize: hidden, secondsPerFrame: 0.08)
        let result = ASRResult(text: "Alpha is a kiwi", confidence: 1, duration: 1.6, processingTime: 0.1,
                               tokenTimings: timings, encoderFeatures: features)
        return { _ in result }
    }

    /// A stub `transcribe` whose transcription SPLITS an acronym term the way the
    /// real encoder does: the carrier held "E2E" as one word, but the ASR hears
    /// "E to E" (3 groups). Every span pools the same constant embedding so the
    /// enroller's self-similarity gate passes — the ONLY thing that can fail
    /// re-derivation here is mis-localizing the term span, which is exactly the
    /// bug under test. Carrier "E2E works" → fresh groups [E, to, E, works].
    private func acronymTranscribe() -> (Data) async throws -> ASRResult? {
        let timings: [TokenTiming] = [
            TokenTiming(token: " E",     tokenId: 1, startTime: 0.00, endTime: 0.30, confidence: 1),
            TokenTiming(token: " to",    tokenId: 2, startTime: 0.40, endTime: 0.60, confidence: 1),
            TokenTiming(token: " E",     tokenId: 3, startTime: 0.70, endTime: 1.00, confidence: 1),
            TokenTiming(token: " works", tokenId: 4, startTime: 1.10, endTime: 1.60, confidence: 1),
        ]
        let frames = Array(repeating: [Float](arrayLiteral: 1, 0, 0, 0), count: 40)
        let window = EncoderFeatureSequence.Window(frames: frames, globalFrameOffset: 0)
        let features = EncoderFeatureSequence(windows: [window], hiddenSize: 4, secondsPerFrame: 0.08)
        let result = ASRResult(text: "E to E works", confidence: 1, duration: 1.6, processingTime: 0.1,
                               tokenTimings: timings, encoderFeatures: features)
        return { _ in result }
    }

    private func positiveClip(carrier: String, n: UInt8) -> StoredEnrollmentClip {
        StoredEnrollmentClip(wav: Data([n]), carrierText: carrier, role: .positive, negativeLabel: nil)
    }
    private func negativeClip(carrier: String, label: String, n: UInt8) -> StoredEnrollmentClip {
        StoredEnrollmentClip(wav: Data([n]), carrierText: carrier, role: .negative, negativeLabel: label)
    }

    /// Park `ids` (with stale stamps) into pendingMigration via loadPersisted, and
    /// return the spy so callers can assert on save/deleteAll.
    private func makeCoordinator(pending ids: [String],
                                 audio: Result<[String: [StoredEnrollmentClip]], Error>)
        -> (VoiceprintCoordinator, SpyVoiceprintPersistence, StubAudioPersistence) {
        let c = VoiceprintCoordinator()
        let spy = SpyVoiceprintPersistence(.success(ids.map { staleTemplate($0) }))
        c.persistence = spy
        let audioStub = StubAudioPersistence(audio)
        c.audioPersistence = audioStub
        c.loadPersisted()   // parks all `ids` into pendingMigration (SI-1: no save)
        XCTAssertEqual(c.pendingMigration.count, ids.count, "all stale templates parked")
        XCTAssertEqual(spy.saveCallCount, 0, "loadPersisted must not save (SI-1)")
        return (c, spy, audioStub)
    }

    // MARK: - Comprehensive: A migrates, B (no audio) + C (lowQuality) stay inert

    func test_migrate_A_migrates_B_and_C_stay_inert_and_survive_save() async {
        let audio: [String: [StoredEnrollmentClip]] = [
            // A: 3 passing positives + a kiwi negative → re-derives, non-lowQuality.
            "Alpha": [
                positiveClip(carrier: "Alpha is here", n: 1),
                positiveClip(carrier: "Alpha is here", n: 2),
                positiveClip(carrier: "Alpha is here", n: 3),
                negativeClip(carrier: "I ate a kiwi", label: "kiwi", n: 4),
            ],
            // C: single positive → fewer than minClips survive → lowQuality.
            "Cee": [positiveClip(carrier: "Cee is here", n: 5)],
            // B: absent → no audio.
        ]
        let (c, spy, _) = makeCoordinator(pending: ["Alpha", "Bee", "Cee"], audio: .success(audio))

        await c.migrateIfNeeded(transcribe: goodTranscribe())

        // A migrated, restamped, with the negative attached.
        XCTAssertTrue(c.hasVoiceprint("Alpha"), "A re-derived into the active store")
        let migratedA = c.template(for: "Alpha")
        XCTAssertEqual(migratedA?.modelVersion, BundledASREngine.voiceprintEncoderIdentity,
                       "A carries the CURRENT encoder stamp")
        XCTAssertNotEqual(migratedA?.modelVersion, Self.oldStamp)
        XCTAssertFalse(migratedA?.negatives.isEmpty ?? true, "negative prototype attached during migration")

        // B and C NOT migrated.
        XCTAssertFalse(c.hasVoiceprint("Bee"))
        XCTAssertFalse(c.hasVoiceprint("Cee"))
        XCTAssertEqual(c.needsReEnrollCount, 2, "B (no audio) + C (lowQuality) need re-enroll")

        // Persist invariants.
        XCTAssertEqual(spy.saveCallCount, 1, "exactly one save when something migrated")
        XCTAssertEqual(spy.deletedCount, 0, "migration NEVER calls deleteAll")
        let payload = spy.lastSaved ?? []
        let byID = Dictionary(uniqueKeysWithValues: payload.map { ($0.termID, $0) })
        XCTAssertNotNil(byID["Alpha"], "A in saved payload")
        XCTAssertEqual(byID["Alpha"]?.modelVersion, BundledASREngine.voiceprintEncoderIdentity)
        // The CRITICAL non-destructive guard: the inert templates survive the save
        // with their OLD stamp — they are NOT dropped from the blob.
        XCTAssertNotNil(byID["Bee"], "B (no audio) STILL in saved payload — inert, not dropped")
        XCTAssertEqual(byID["Bee"]?.modelVersion, Self.oldStamp, "B keeps its old stamp on disk")
        XCTAssertNotNil(byID["Cee"], "C (lowQuality) STILL in saved payload — inert, not dropped")
        XCTAssertEqual(byID["Cee"]?.modelVersion, Self.oldStamp, "C keeps its old stamp on disk")

        // pendingMigration retains only the inert ones.
        XCTAssertEqual(Set(c.pendingMigration.map { $0.termID }), ["Bee", "Cee"])
    }

    // MARK: - Acronym/digit term re-derives instead of parking (item 2)

    /// An acronym term ("E2E") whose enrollment carriers held it as one word but
    /// which the current encoder re-transcribes as several ("E to E"). Before the
    /// text-anchored span alignment, the stale carrier word index pointed at a
    /// single wrong sub-word → the pooled span mis-located → re-derivation failed
    /// → the term was PARKED. It must now migrate cleanly.
    func test_acronym_term_re_derives_and_is_not_parked() async {
        let audio: [String: [StoredEnrollmentClip]] = [
            "E2E": [
                positiveClip(carrier: "E2E works", n: 1),
                positiveClip(carrier: "E2E works", n: 2),
                positiveClip(carrier: "E2E works", n: 3),
            ],
        ]
        let (c, spy, _) = makeCoordinator(pending: ["E2E"], audio: .success(audio))

        await c.migrateIfNeeded(transcribe: acronymTranscribe())

        XCTAssertTrue(c.hasVoiceprint("E2E"), "acronym term re-derived into the active store")
        XCTAssertEqual(c.template(for: "E2E")?.modelVersion, BundledASREngine.voiceprintEncoderIdentity,
                       "carries the current encoder stamp")
        XCTAssertEqual(c.needsReEnrollCount, 0, "acronym term no longer parked for re-enroll")
        XCTAssertTrue(c.pendingMigration.isEmpty, "nothing left inert")
        XCTAssertEqual(spy.saveCallCount, 1, "one save for the migrated term")
        XCTAssertEqual(spy.deletedCount, 0)
    }

    // MARK: - Audio load throws → bail, no save, no deleteAll, pending retained (R1/SI-1)

    func test_audio_load_throws_does_not_save_or_delete() async {
        let (c, spy, _) = makeCoordinator(pending: ["Alpha"], audio: .failure(StubError()))

        await c.migrateIfNeeded(transcribe: goodTranscribe())

        XCTAssertEqual(spy.saveCallCount, 0, "audio load failure must NOT save (blob preserved)")
        XCTAssertEqual(spy.deletedCount, 0, "and must NEVER deleteAll")
        XCTAssertEqual(c.pendingMigration.map { $0.termID }, ["Alpha"], "pending retained on bail")
        XCTAssertFalse(c.hasVoiceprint("Alpha"))
    }

    // MARK: - Nothing migrated (all no-audio) → no save, blob untouched

    func test_nothing_migrated_does_not_save() async {
        let (c, spy, _) = makeCoordinator(pending: ["Bee"], audio: .success([:]))

        await c.migrateIfNeeded(transcribe: goodTranscribe())

        XCTAssertEqual(spy.saveCallCount, 0, "no migration → no save (blob already correct)")
        XCTAssertEqual(spy.deletedCount, 0)
        XCTAssertEqual(c.needsReEnrollCount, 1, "the one no-audio term needs re-enroll")
        XCTAssertEqual(c.pendingMigration.map { $0.termID }, ["Bee"], "still inert")
    }

    // MARK: - Idempotent: a second pass after A migrated does not lose A

    func test_second_migrate_does_not_lose_A() async {
        let audio: [String: [StoredEnrollmentClip]] = [
            "Alpha": [
                positiveClip(carrier: "Alpha is here", n: 1),
                positiveClip(carrier: "Alpha is here", n: 2),
                positiveClip(carrier: "Alpha is here", n: 3),
            ],
            "Cee": [positiveClip(carrier: "Cee is here", n: 5)],
        ]
        let (c, spy, _) = makeCoordinator(pending: ["Alpha", "Bee", "Cee"], audio: .success(audio))

        await c.migrateIfNeeded(transcribe: goodTranscribe())
        XCTAssertTrue(c.hasVoiceprint("Alpha"))
        XCTAssertEqual(spy.saveCallCount, 1)

        // Second pass: only inert B/C remain pending → nothing migrates → no new save.
        await c.migrateIfNeeded(transcribe: goodTranscribe())
        XCTAssertTrue(c.hasVoiceprint("Alpha"), "A survives a second migration pass")
        XCTAssertEqual(spy.saveCallCount, 1, "no redundant save on the idempotent second pass")
        XCTAssertEqual(spy.deletedCount, 0, "deleteAll never called across migrations")
    }

    // MARK: - 7027/7032: a commit after a partial migration keeps inert templates

    func test_commit_after_partial_migration_does_not_drop_inert() async {
        let audio: [String: [StoredEnrollmentClip]] = [
            "Alpha": [
                positiveClip(carrier: "Alpha is here", n: 1),
                positiveClip(carrier: "Alpha is here", n: 2),
                positiveClip(carrier: "Alpha is here", n: 3),
            ],
            // Bee + Cee have no audio → stay inert in pendingMigration.
        ]
        let (c, spy, _) = makeCoordinator(pending: ["Alpha", "Bee", "Cee"], audio: .success(audio))
        await c.migrateIfNeeded(transcribe: goodTranscribe())
        XCTAssertTrue(c.hasVoiceprint("Alpha"))
        XCTAssertEqual(Set(c.pendingMigration.map { $0.termID }), ["Bee", "Cee"])
        let savesBefore = spy.saveCallCount

        // A later commit of a DIFFERENT freshly-enrolled term must persist the
        // active store ∪ inert pending union — NOT active-only (which would drop
        // Bee/Cee from the on-disk blob).
        let fresh = VoiceprintTemplate(termID: "Dee", voiceprint: [1, 0, 0, 0], dim: 4,
                                       lowQuality: false,
                                       modelVersion: BundledASREngine.voiceprintEncoderIdentity)
        c.commit(fresh)

        XCTAssertEqual(spy.saveCallCount, savesBefore + 1, "commit persists")
        XCTAssertEqual(spy.deletedCount, 0, "commit never deletes")
        let ids = Set((spy.lastSaved ?? []).map { $0.termID })
        XCTAssertTrue(ids.contains("Bee"), "inert Bee NOT dropped by a later commit")
        XCTAssertTrue(ids.contains("Cee"), "inert Cee NOT dropped by a later commit")
        XCTAssertTrue(ids.contains("Alpha"), "migrated Alpha retained")
        XCTAssertTrue(ids.contains("Dee"), "freshly committed term present")
    }

    // MARK: - 7036: re-enrolling a pending term clears its banner slot mid-session

    func test_commit_of_pending_term_decrements_reenroll_count() async {
        let (c, spy, _) = makeCoordinator(pending: ["Alpha", "Bee"], audio: .success([:]))
        await c.migrateIfNeeded(transcribe: goodTranscribe())
        XCTAssertEqual(c.needsReEnrollCount, 2, "both need re-enroll (no stored audio)")
        XCTAssertEqual(Set(c.pendingMigrationTermIDs), ["Alpha", "Bee"])

        // User re-enrolls Alpha → committing it clears its pending slot + count.
        let fresh = VoiceprintTemplate(termID: "Alpha", voiceprint: [1, 0, 0, 0], dim: 4,
                                       lowQuality: false,
                                       modelVersion: BundledASREngine.voiceprintEncoderIdentity)
        c.commit(fresh)

        XCTAssertEqual(c.needsReEnrollCount, 1, "banner count decremented mid-session")
        XCTAssertEqual(c.pendingMigrationTermIDs, ["Bee"], "Alpha removed from pending")
        XCTAssertTrue(c.hasVoiceprint("Alpha"))
        // The re-enrolled term must appear exactly once (store wins, no dup).
        XCTAssertEqual((spy.lastSaved ?? []).filter { $0.termID == "Alpha" }.count, 1,
                       "no duplicate Alpha in the persisted union")
    }

    // MARK: - No pending → immediate no-op (no save, no deleteAll)

    func test_empty_pending_is_noop() async {
        let c = VoiceprintCoordinator()
        let spy = SpyVoiceprintPersistence(.success([]))
        c.persistence = spy
        c.audioPersistence = StubAudioPersistence(.success([:]))
        c.loadPersisted()
        XCTAssertTrue(c.pendingMigration.isEmpty)

        await c.migrateIfNeeded(transcribe: goodTranscribe())
        XCTAssertEqual(spy.saveCallCount, 0)
        XCTAssertEqual(spy.deletedCount, 0)
    }
}

#endif
