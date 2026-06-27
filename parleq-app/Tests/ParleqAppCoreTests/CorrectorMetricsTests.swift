import XCTest
@testable import ParleqAppCore

final class CorrectorMetricsTests: XCTestCase {
    func testTallyCountsRecoveryAndOverfire() {
        let out = [
            CorrectorMetrics.Outcome(intent: "keavi", recovered: true, overFired: false),
            CorrectorMetrics.Outcome(intent: "keavi", recovered: false, overFired: false),
            CorrectorMetrics.Outcome(intent: "fruit", recovered: false, overFired: true),
            CorrectorMetrics.Outcome(intent: "fruit", recovered: false, overFired: false),
        ]
        let t = CorrectorMetrics.tally(out)
        XCTAssertEqual(t["keavi"], .init(recovered: 1, total: 2, overFired: 0))
        XCTAssertEqual(t["fruit"], .init(recovered: 0, total: 2, overFired: 1))
    }
    func testWithinBaselineDetectsRegression() {
        let base = ["keavi": CorrectorMetrics.Tally(recovered: 2, total: 2, overFired: 0),
                    "fruit": .init(recovered: 0, total: 2, overFired: 0)]
        let worse = ["keavi": CorrectorMetrics.Tally(recovered: 1, total: 2, overFired: 0),
                     "fruit": .init(recovered: 0, total: 2, overFired: 1)]
        let r = CorrectorMetrics.withinBaseline(worse, baseline: base, tolerance: 0)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(Set(r.regressions), ["keavi", "fruit"])
        XCTAssertTrue(CorrectorMetrics.withinBaseline(base, baseline: base, tolerance: 0).ok)
    }
}
