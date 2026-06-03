import XCTest
@testable import ParleqAppCore

final class LearningAnalyzerGateTests: XCTestCase {

    func test_should_not_run_below_threshold() {
        XCTAssertFalse(LearningAnalyzer.shouldRun(unanalyzedCount: 3, threshold: 5,
                                                  lastRunAt: nil, now: Date(), minIntervalSeconds: 600))
    }

    func test_should_run_at_threshold_when_never_run() {
        XCTAssertTrue(LearningAnalyzer.shouldRun(unanalyzedCount: 5, threshold: 5,
                                                 lastRunAt: nil, now: Date(), minIntervalSeconds: 600))
    }

    func test_rate_cap_blocks_a_too_soon_run() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(LearningAnalyzer.shouldRun(unanalyzedCount: 10, threshold: 5,
                                                  lastRunAt: now.addingTimeInterval(-60), now: now, minIntervalSeconds: 600),
                       "Ran 60s ago, 600s cap -> blocked")
    }

    func test_rate_cap_allows_after_interval() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(LearningAnalyzer.shouldRun(unanalyzedCount: 10, threshold: 5,
                                                 lastRunAt: now.addingTimeInterval(-3600), now: now, minIntervalSeconds: 600))
    }

    func test_idle_flush_runs_with_any_backlog_after_interval() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Idle flush passes threshold:1 to catch a small backlog.
        XCTAssertTrue(LearningAnalyzer.shouldRun(unanalyzedCount: 1, threshold: 1,
                                                 lastRunAt: now.addingTimeInterval(-3600), now: now, minIntervalSeconds: 600))
        XCTAssertFalse(LearningAnalyzer.shouldRun(unanalyzedCount: 0, threshold: 1,
                                                  lastRunAt: nil, now: now, minIntervalSeconds: 600),
                       "Nothing to analyze -> don't run")
    }
}
