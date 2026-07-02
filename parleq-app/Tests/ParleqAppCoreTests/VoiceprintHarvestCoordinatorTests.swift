// VoiceprintHarvestCoordinatorTests — Task 3: coordinator harvest/heal/clear + ring lifecycle.
//
// Synthetic embeddings only (orthogonal-ish unit vectors, dim 4) — no flywheel
// content, no real audio, no Keychain (in-memory persistence spies).

import XCTest
@testable import ParleqAppCore

#if Concord
import Concord

@MainActor
final class VoiceprintHarvestCoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    private let current = BundledASREngine.voiceprintEncoderIdentity

    /// dim-4 synthetic embeddings.
    private let vpVec: [Float] = [1, 0, 0, 0]        // the term's voiceprint
    private let e1: [Float] = [0, 1, 0, 0]
    private let e2: [Float] = [0, 0, 1, 0]
    private let e3: [Float] = [0, 0, 0, 1]
    private let proto: [Float] = [0, 0.5, 0.5, 0]    // wizard-enrolled prototype

    private func template(_ id: String = "Claude",
                          negatives: [String: [Float]] = [:]) -> VoiceprintTemplate {
        VoiceprintTemplate(termID: id, voiceprint: vpVec, negatives: negatives,
                           dim: 4, lowQuality: false, modelVersion: current)
    }

    /// Coordinator wired with spies and `templates` pre-loaded via loadPersisted
    /// (which never saves — SI-1 — so save counts start at zero).
    private func makeCoordinator(templates: [VoiceprintTemplate],
                                 harvested: HarvestedNegatives = HarvestedNegatives())
    -> (VoiceprintCoordinator, VoicePersistenceSpy, HarvestPersistenceSpy) {
        let c = VoiceprintCoordinator()
        let vpSpy = VoicePersistenceSpy(templates)
        let hSpy = HarvestPersistenceSpy(harvested)
        c.persistence = vpSpy
        c.harvestPersistence = hSpy
        c.loadPersisted()
        return (c, vpSpy, hSpy)
    }

    private func assertVector(_ got: [Float]?, _ want: [Float],
                              accuracy: Float = 1e-6, _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let got else {
            XCTFail("vector is nil — \(message)", file: file, line: line); return
        }
        XCTAssertEqual(got.count, want.count, message, file: file, line: line)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g, w, accuracy: accuracy, message, file: file, line: line)
        }
    }

    private func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors { for i in 0..<v.count { sum[i] += v[i] } }
        let inv = 1 / Float(vectors.count)
        return sum.map { $0 * inv }
    }

    // MARK: - Happy path

    func test_harvest_attaches_negative_and_goes_contrastive() {
        let (c, vpSpy, hSpy) = makeCoordinator(templates: [template()])
        let before = c.template(for: "Claude")!
        XCTAssertTrue(before.negatives.isEmpty, "precondition: one-class")
        XCTAssertFalse(VoiceprintGate().decide(candidate: e1, against: before).usedContrastive)

        let outcome = c.harvestNegative(termID: "Claude", label: "cloud",
                                        embedding: e1, harvestEnabled: true)
        XCTAssertEqual(outcome, .attached(ringCount: 1))

        let after = c.template(for: "Claude")!
        assertVector(after.negatives["cloud"], e1, "single harvest ⇒ centroid == the embedding")
        XCTAssertTrue(VoiceprintGate().decide(candidate: e1, against: after).usedContrastive)
        // Template identity preserved.
        XCTAssertEqual(after.modelVersion, before.modelVersion)
        XCTAssertEqual(after.voiceprint, before.voiceprint)
        XCTAssertEqual(after.dim, before.dim)
        // Persisted exactly once, via the commit path (loadPersisted never saves).
        XCTAssertEqual(vpSpy.saved.count, 1, "exactly one voiceprint save (via commit)")
        XCTAssertEqual(hSpy.saved.count, 1, "exactly one harvest-ring save")
        XCTAssertEqual(hSpy.saved.last?.rings["Claude"]?["cloud"]?.embeddings.count, 1)
    }

    // MARK: - Accumulation + FIFO

    func test_three_harvests_centroid_of_three() {
        let (c, _, _) = makeCoordinator(templates: [template()])
        for e in [e1, e2, e3] {
            c.harvestNegative(termID: "Claude", label: "cloud", embedding: e, harvestEnabled: true)
        }
        assertVector(c.template(for: "Claude")!.negatives["cloud"], centroid([e1, e2, e3]))
    }

    func test_nine_harvests_ring_keeps_newest_eight() {
        let (c, _, hSpy) = makeCoordinator(templates: [template()])
        var all: [[Float]] = []
        for i in 1...9 {
            let e: [Float] = [0, Float(i), 1, 0]
            all.append(e)
            let outcome = c.harvestNegative(termID: "Claude", label: "cloud",
                                            embedding: e, harvestEnabled: true)
            XCTAssertEqual(outcome, .attached(ringCount: min(i, 8)))
        }
        let ring = hSpy.saved.last?.rings["Claude"]?["cloud"]
        XCTAssertEqual(ring?.embeddings.count, 8, "FIFO cap at 8")
        XCTAssertEqual(ring?.embeddings.first, all[1], "oldest (1st) evicted; 2nd is now oldest")
        XCTAssertEqual(ring?.embeddings.last, all[8], "newest last")
        assertVector(c.template(for: "Claude")!.negatives["cloud"],
                     centroid(Array(all.dropFirst())))
    }

    // MARK: - Enrollment-prototype merge

    func test_first_harvest_snapshots_enrollment_prototype_and_merges() {
        let (c, _, hSpy) = makeCoordinator(templates: [template(negatives: ["cloud": proto])])
        c.harvestNegative(termID: "Claude", label: "cloud", embedding: e1, harvestEnabled: true)
        let ring = hSpy.saved.last?.rings["Claude"]?["cloud"]
        XCTAssertEqual(ring?.enrollmentPrototype, proto, "prototype snapshotted on first harvest")
        assertVector(c.template(for: "Claude")!.negatives["cloud"], centroid([proto, e1]),
                     "centroid = mean(prototype + ring)")
    }

    func test_mixed_case_enrollment_label_found_and_stale_key_stripped() {
        // Enrollment stored the confusable as "Cloud" (capital) — the lookup must be
        // case-insensitive and the stale-cased duplicate stripped on merge
        // (RoboRev-7484/7488): no shadow negative under the old casing.
        let (c, _, hSpy) = makeCoordinator(templates: [template(negatives: ["Cloud": proto])])
        c.harvestNegative(termID: "Claude", label: "cloud", embedding: e1, harvestEnabled: true)
        let after = c.template(for: "Claude")!
        XCTAssertNil(after.negatives["Cloud"], "stale-cased duplicate must be stripped")
        assertVector(after.negatives["cloud"], centroid([proto, e1]))
        XCTAssertEqual(hSpy.saved.last?.rings["Claude"]?["cloud"]?.enrollmentPrototype, proto)
    }

    // MARK: - Heal

    func test_heal_removes_newest_embedding() {
        let (c, _, _) = makeCoordinator(templates: [template()])
        c.harvestNegative(termID: "Claude", label: "cloud", embedding: e1, harvestEnabled: true)
        c.harvestNegative(termID: "Claude", label: "cloud", embedding: e2, harvestEnabled: true)
        let outcome = c.healHarvestedNegative(termID: "Claude", label: "cloud")
        XCTAssertEqual(outcome, .healed(ringCount: 1))
        assertVector(c.template(for: "Claude")!.negatives["cloud"], e1,
                     "heal removes the NEWEST; centroid == first embedding")
    }

    func test_heal_to_empty_with_prototype_restores_prototype() {
        let (c, _, _) = makeCoordinator(templates: [template(negatives: ["cloud": proto])])
        c.harvestNegative(termID: "Claude", label: "cloud", embedding: e1, harvestEnabled: true)
        let outcome = c.healHarvestedNegative(termID: "Claude", label: "cloud")
        XCTAssertEqual(outcome, .healed(ringCount: 0))
        assertVector(c.template(for: "Claude")!.negatives["cloud"], proto,
                     "empty ring + prototype ⇒ label centroid == the enrollment prototype")
    }

    func test_heal_to_empty_without_prototype_detaches_label() {
        let (c, _, hSpy) = makeCoordinator(templates: [template()])
        c.harvestNegative(termID: "Claude", label: "cloud", embedding: e1, harvestEnabled: true)
        let outcome = c.healHarvestedNegative(termID: "Claude", label: "cloud")
        XCTAssertEqual(outcome, .healed(ringCount: 0))
        let after = c.template(for: "Claude")!
        XCTAssertNil(after.negatives["cloud"], "label detached when nothing remains")
        XCTAssertFalse(VoiceprintGate().decide(candidate: e1, against: after).usedContrastive,
                       "decide returns to one-class")
        XCTAssertTrue(hSpy.saved.last?.isEmpty ?? false, "empty ring pruned from the store")
    }

    func test_heal_with_no_ring_is_a_reported_noop() {
        let (c, vpSpy, _) = makeCoordinator(templates: [template()])
        let outcome = c.healHarvestedNegative(termID: "Claude", label: "cloud")
        XCTAssertEqual(outcome, .rejected(.nothingToHeal))
        XCTAssertEqual(vpSpy.saved.count, 0, "no-op heal must not persist")
    }

    // MARK: - Validation gates

    func test_phonetic_mismatch_rejected() {
        let (c, vpSpy, hSpy) = makeCoordinator(templates: [template()])
        let outcome = c.harvestNegative(termID: "Claude", label: "assistant",
                                        embedding: e1, harvestEnabled: true)
        XCTAssertEqual(outcome, .rejected(.phoneticMismatch))
        XCTAssertEqual(vpSpy.saved.count, 0)
        XCTAssertEqual(hSpy.saved.count, 0)
    }

    func test_alias_bypasses_phonetic_gate() {
        // "nimbus" does not sound like "Claude", but the user declared it an alias.
        let (c, _, _) = makeCoordinator(templates: [template()])
        let outcome = c.harvestNegative(termID: "Claude", label: "nimbus", embedding: e1,
                                        aliases: ["Nimbus"], harvestEnabled: true)
        XCTAssertEqual(outcome, .attached(ringCount: 1))
    }

    func test_existing_negative_label_bypasses_phonetic_gate() {
        // An enrollment-declared confusable is already trusted.
        let (c, _, _) = makeCoordinator(templates: [template(negatives: ["nimbus": proto])])
        let outcome = c.harvestNegative(termID: "Claude", label: "nimbus",
                                        embedding: e1, harvestEnabled: true)
        XCTAssertEqual(outcome, .attached(ringCount: 1))
    }

    func test_unusable_embeddings_rejected_with_reported_outcome() {
        let (c, _, _) = makeCoordinator(templates: [template()])
        XCTAssertEqual(c.harvestNegative(termID: "Claude", label: "cloud",
                                         embedding: [Float.nan, 0, 0, 0], harvestEnabled: true),
                       .rejected(.unusableEmbedding), "NaN")
        XCTAssertEqual(c.harvestNegative(termID: "Claude", label: "cloud",
                                         embedding: [1, 0], harvestEnabled: true),
                       .rejected(.unusableEmbedding), "wrong dim")
        XCTAssertEqual(c.harvestNegative(termID: "Claude", label: "cloud",
                                         embedding: [], harvestEnabled: true),
                       .rejected(.unusableEmbedding), "empty")
    }

    func test_multiword_and_nonalphabetic_labels_rejected() {
        let (c, _, _) = makeCoordinator(templates: [template()])
        XCTAssertEqual(c.harvestNegative(termID: "Claude", label: "two words",
                                         embedding: e1, harvestEnabled: true),
                       .rejected(.multiWordLabel))
        XCTAssertEqual(c.harvestNegative(termID: "Claude", label: "cl0ud",
                                         embedding: e1, harvestEnabled: true),
                       .rejected(.multiWordLabel))
    }

    func test_disabled_rejects_without_any_persistence_call() {
        let (c, vpSpy, hSpy) = makeCoordinator(templates: [template()])
        let outcome = c.harvestNegative(termID: "Claude", label: "cloud",
                                        embedding: e1, harvestEnabled: false)
        XCTAssertEqual(outcome, .rejected(.disabled))
        XCTAssertEqual(vpSpy.saved.count, 0)
        XCTAssertEqual(hSpy.saved.count, 0)
        XCTAssertEqual(hSpy.deleteAllCount, 0)
    }

    func test_no_template_rejected() {
        let (c, _, _) = makeCoordinator(templates: [])
        XCTAssertEqual(c.harvestNegative(termID: "Claude", label: "cloud",
                                         embedding: e1, harvestEnabled: true),
                       .rejected(.noTemplate))
    }

    // MARK: - Wipe wiring

    func test_removeVoiceprint_clears_that_terms_rings_and_persists() {
        let (c, _, hSpy) = makeCoordinator(templates: [template("Claude"), template("Keavi")])
        c.harvestNegative(termID: "Claude", label: "cloud", embedding: e1, harvestEnabled: true)
        // "kiwi" is not a DoubleMetaphone match for "Keavi" — it harvests via the
        // user-declared alias bypass (as in real usage, where it is a dictionary alias).
        XCTAssertEqual(c.harvestNegative(termID: "Keavi", label: "kiwi", embedding: e2,
                                         aliases: ["kiwi"], harvestEnabled: true),
                       .attached(ringCount: 1))
        c.removeVoiceprint(termID: "Claude")
        let last = hSpy.saved.last
        XCTAssertNil(last?.rings["Claude"], "removed term's rings gone")
        XCTAssertNotNil(last?.rings["Keavi"], "other term's rings intact")
    }

    func test_removeAll_empties_harvest_store() {
        let (c, _, hSpy) = makeCoordinator(templates: [template()])
        c.harvestNegative(termID: "Claude", label: "cloud", embedding: e1, harvestEnabled: true)
        c.removeAll()
        XCTAssertGreaterThan(hSpy.deleteAllCount, 0, "harvest file removed on delete-all")
    }

    // MARK: - clearAllHarvests (kill-switch clear offer)

    func test_clearAllHarvests_restores_prototype_or_detaches() {
        let (c, _, hSpy) = makeCoordinator(templates: [
            template("Claude", negatives: ["cloud": proto]),   // has enrollment prototype
            template("Keavi"),                                  // harvest-only label
        ])
        c.harvestNegative(termID: "Claude", label: "cloud", embedding: e1, harvestEnabled: true)
        XCTAssertEqual(c.harvestNegative(termID: "Keavi", label: "kiwi", embedding: e2,
                                         aliases: ["kiwi"], harvestEnabled: true),
                       .attached(ringCount: 1))

        c.clearAllHarvests()

        assertVector(c.template(for: "Claude")!.negatives["cloud"], proto,
                     "label restored to the enrollment prototype")
        XCTAssertNil(c.template(for: "Keavi")!.negatives["kiwi"],
                     "harvest-only label detached")
        XCTAssertGreaterThan(hSpy.deleteAllCount, 0, "harvest file removed")
        XCTAssertEqual(c.harvestedRingCounts(termID: "Claude"), [:])
        XCTAssertEqual(c.harvestedRingCounts(termID: "Keavi"), [:])
    }

    // MARK: - Re-enrollment re-attach

    func test_reenrollment_commit_reattaches_rings_and_refreshes_prototype() {
        let (c, _, hSpy) = makeCoordinator(templates: [template()])
        c.harvestNegative(termID: "Claude", label: "cloud", embedding: e1, harvestEnabled: true)

        // Wizard re-run: fresh one-class template (no negatives).
        c.commit(template())
        var after = c.template(for: "Claude")!
        assertVector(after.negatives["cloud"], e1,
                     "harvested ring re-attached to the fresh template")
        XCTAssertNil(hSpy.saved.last?.rings["Claude"]?["cloud"]?.enrollmentPrototype,
                     "prototype refreshed to nil (new template has no wizard negative)")

        // Wizard re-run WITH a wizard-declared cloud negative.
        c.commit(template(negatives: ["cloud": proto]))
        after = c.template(for: "Claude")!
        assertVector(after.negatives["cloud"], centroid([proto, e1]),
                     "prototype refreshed from the new template and merged with the ring")
        XCTAssertEqual(hSpy.saved.last?.rings["Claude"]?["cloud"]?.enrollmentPrototype, proto)
    }

    // MARK: - Encoder-stamp check at load

    func test_stale_stamp_ring_dropped_at_loadPersisted() {
        let staleRing = HarvestRing(embeddings: [e1], modelVersion: "bogus-encoder-v0")
        let currentRing = HarvestRing(embeddings: [e2], modelVersion: current)
        let harvested = HarvestedNegatives(rings: [
            "Claude": ["clawed": staleRing, "cloud": currentRing],
        ])
        let (c, _, _) = makeCoordinator(templates: [template()], harvested: harvested)
        XCTAssertEqual(c.harvestedRingCounts(termID: "Claude"), ["cloud": 1],
                       "stale-stamp ring dropped; current-stamp ring kept")
    }

    func test_legacy_compatible_stamp_ring_kept_at_loadPersisted() {
        guard let legacy = BundledASREngine.legacyCompatibleStamps.first else {
            XCTFail("no legacy stamp declared"); return
        }
        let ring = HarvestRing(embeddings: [e1], modelVersion: legacy)
        let harvested = HarvestedNegatives(rings: ["Claude": ["cloud": ring]])
        let (c, _, _) = makeCoordinator(templates: [template()], harvested: harvested)
        XCTAssertEqual(c.harvestedRingCounts(termID: "Claude"), ["cloud": 1])
    }
}

// MARK: - Spies

private final class VoicePersistenceSpy: VoiceprintPersistence, @unchecked Sendable {
    private let templates: [VoiceprintTemplate]
    private(set) var saved: [[VoiceprintTemplate]] = []
    init(_ templates: [VoiceprintTemplate]) { self.templates = templates }
    func load() throws -> [VoiceprintTemplate] { templates }
    func save(_ templates: [VoiceprintTemplate]) throws { saved.append(templates) }
    func deleteAll() throws {}
}

private final class HarvestPersistenceSpy: HarvestedNegativePersistence, @unchecked Sendable {
    private let initial: HarvestedNegatives
    private(set) var saved: [HarvestedNegatives] = []
    private(set) var deleteAllCount = 0
    init(_ initial: HarvestedNegatives = HarvestedNegatives()) { self.initial = initial }
    func load() throws -> HarvestedNegatives { initial }
    func save(_ negatives: HarvestedNegatives) throws { saved.append(negatives) }
    func deleteAll() throws { deleteAllCount += 1 }
}
#endif
