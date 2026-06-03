import XCTest
@testable import ParleqAppCore

final class CorrectionJournalTests: XCTestCase {

    func test_retention_count_cap_keeps_newest() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let recs = (0..<5).map { i in
            CorrectionRecord(id: UUID(), timestamp: base.addingTimeInterval(Double(i)),
                             kind: .spellout, instruction: nil, before: nil, after: nil, term: "t\(i)")
        }
        let kept = CorrectionJournal.applyRetention(recs, maxEntries: 3, retentionHours: nil, now: base.addingTimeInterval(10))
        XCTAssertEqual(kept.map { $0.term }, ["t2", "t3", "t4"],
                       "Count cap should drop oldest, keep the 3 newest in chronological order")
    }

    func test_retention_age_cap_drops_old() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recs = [
            CorrectionRecord(id: UUID(), timestamp: now.addingTimeInterval(-7200), kind: .spellout, instruction: nil, before: nil, after: nil, term: "old"),
            CorrectionRecord(id: UUID(), timestamp: now.addingTimeInterval(-600),  kind: .spellout, instruction: nil, before: nil, after: nil, term: "new"),
        ]
        let kept = CorrectionJournal.applyRetention(recs, maxEntries: nil, retentionHours: 1, now: now)
        XCTAssertEqual(kept.map { $0.term }, ["new"], "Records older than 1h should be dropped")
    }

    func test_zero_cap_disables_entirely() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recs = [CorrectionRecord(id: UUID(), timestamp: now, kind: .spellout, instruction: nil, before: nil, after: nil, term: "x")]
        XCTAssertTrue(CorrectionJournal.applyRetention(recs, maxEntries: 0, retentionHours: nil, now: now).isEmpty,
                      "maxEntries == 0 is the disable lever")
        XCTAssertTrue(CorrectionJournal.applyRetention(recs, maxEntries: nil, retentionHours: 0, now: now).isEmpty,
                      "retentionHours == 0 is the disable lever")
    }
}
