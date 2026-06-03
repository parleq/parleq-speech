import XCTest
@testable import ParleqAppCore

/// Tests for `TranscriptHistory.upsert(_:)` — the keyed insert-or-
/// update method added in the copy-to-history feature (slice-1).
///
/// `TranscriptHistory.shared` is a `@MainActor` singleton, so the
/// test class is annotated `@MainActor` and each test calls `clear()`
/// first to guarantee isolation.
@MainActor
final class TranscriptHistoryUpsertTests: XCTestCase {

    // Restore unlimited retention after every test so tests don't
    // pollute each other's limits.
    override func setUp() async throws {
        try await super.setUp()
        var cfg = Config.default
        cfg.transcriptHistoryMaxEntries = nil        // unlimited
        cfg.transcriptHistoryRetentionHours = nil    // unlimited
        TranscriptHistory.shared.applyRetentionLimits(from: cfg)
        TranscriptHistory.shared.clear()
    }

    // MARK: - Insert (id absent)

    func test_upsert_new_id_inserts_at_front() {
        let e1 = makeEntry(text: "first")
        let e2 = makeEntry(text: "second")
        TranscriptHistory.shared.upsert(e1)
        TranscriptHistory.shared.upsert(e2)
        // Both should be present; newest (e2) at front.
        XCTAssertEqual(TranscriptHistory.shared.entries.count, 2)
        XCTAssertEqual(TranscriptHistory.shared.entries[0].id, e2.id)
        XCTAssertEqual(TranscriptHistory.shared.entries[1].id, e1.id)
    }

    func test_upsert_new_id_appends_metrics_record() {
        let e = makeEntry(text: "hello")
        TranscriptHistory.shared.upsert(e)
        XCTAssertEqual(TranscriptHistory.shared.metricsRecords.count, 1)
        XCTAssertEqual(TranscriptHistory.shared.metricsRecords[0].id, e.id)
    }

    // MARK: - Update (id present)

    func test_upsert_existing_id_updates_text_in_place() {
        let id = UUID()
        let original = makeEntry(id: id, text: "original text")
        let updated = makeEntry(id: id, text: "updated text")
        TranscriptHistory.shared.upsert(original)
        TranscriptHistory.shared.upsert(updated)
        // Count must be 1 (no duplicate).
        XCTAssertEqual(TranscriptHistory.shared.entries.count, 1)
        XCTAssertEqual(TranscriptHistory.shared.entries[0].text, "updated text")
    }

    func test_upsert_existing_id_moves_entry_to_front() {
        let idA = UUID()
        let eA1 = makeEntry(id: idA, text: "A first")
        let eB  = makeEntry(text: "B")
        let eA2 = makeEntry(id: idA, text: "A updated")
        TranscriptHistory.shared.upsert(eA1) // [A]
        TranscriptHistory.shared.upsert(eB)  // [B, A]
        TranscriptHistory.shared.upsert(eA2) // [A(updated), B]
        XCTAssertEqual(TranscriptHistory.shared.entries.count, 2)
        XCTAssertEqual(TranscriptHistory.shared.entries[0].id, idA)
        XCTAssertEqual(TranscriptHistory.shared.entries[0].text, "A updated")
        XCTAssertEqual(TranscriptHistory.shared.entries[1].id, eB.id)
    }

    // MARK: - MetricsRecord dedup

    func test_upsert_existing_id_does_not_duplicate_metrics_record() {
        let id = UUID()
        let e1 = makeEntry(id: id, text: "first")
        let e2 = makeEntry(id: id, text: "second")
        TranscriptHistory.shared.upsert(e1)
        TranscriptHistory.shared.upsert(e2)
        // Must be exactly 1 MetricsRecord for this id, not 2.
        let matchingRecords = TranscriptHistory.shared.metricsRecords.filter { $0.id == id }
        XCTAssertEqual(matchingRecords.count, 1)
        // Overall count also stays at 1.
        XCTAssertEqual(TranscriptHistory.shared.metricsRecords.count, 1)
    }

    func test_upsert_multiple_ids_have_separate_metrics_records() {
        let e1 = makeEntry(text: "one")
        let e2 = makeEntry(text: "two")
        TranscriptHistory.shared.upsert(e1)
        TranscriptHistory.shared.upsert(e2)
        XCTAssertEqual(TranscriptHistory.shared.metricsRecords.count, 2)
    }

    // MARK: - Zero-retention disable

    func test_upsert_is_noop_when_max_entries_is_zero() {
        var cfg = Config.default
        cfg.transcriptHistoryMaxEntries = 0
        cfg.transcriptHistoryRetentionHours = nil
        TranscriptHistory.shared.applyRetentionLimits(from: cfg)
        let e = makeEntry(text: "should not appear")
        TranscriptHistory.shared.upsert(e)
        XCTAssertEqual(TranscriptHistory.shared.entries.count, 0)
        XCTAssertEqual(TranscriptHistory.shared.metricsRecords.count, 0)
    }

    func test_upsert_is_noop_when_retention_hours_is_zero() {
        var cfg = Config.default
        cfg.transcriptHistoryMaxEntries = nil
        cfg.transcriptHistoryRetentionHours = 0
        TranscriptHistory.shared.applyRetentionLimits(from: cfg)
        let e = makeEntry(text: "should not appear")
        TranscriptHistory.shared.upsert(e)
        XCTAssertEqual(TranscriptHistory.shared.entries.count, 0)
        XCTAssertEqual(TranscriptHistory.shared.metricsRecords.count, 0)
    }

    // MARK: - Helpers

    private func makeEntry(
        id: UUID = UUID(),
        text: String,
        targetAppName: String? = nil
    ) -> TranscriptEntry {
        TranscriptEntry(
            id: id,
            text: text,
            targetAppName: targetAppName,
            wasCleanupSuccessful: true,
            referenceCount: 0,
            referenceLabels: [],
            audioDurationMs: 0,
            asrLatencyMs: nil,
            llmLatencyMs: nil
        )
    }
}
