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

    // MARK: - withinBaseline (updated signature)

    func testWithinBaselineDetectsRegression() {
        let base = ["keavi": CorrectorMetrics.Tally(recovered: 2, total: 2, overFired: 0),
                    "fruit": .init(recovered: 0, total: 2, overFired: 0)]
        let worse = ["keavi": CorrectorMetrics.Tally(recovered: 1, total: 2, overFired: 0),
                     "fruit": .init(recovered: 0, total: 2, overFired: 1)]
        let r = CorrectorMetrics.withinBaseline(worse, baseline: base,
                                                recoveryTolerance: 0, overFireTolerance: 0)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(Set(r.regressions), ["keavi", "fruit"])
        XCTAssertTrue(CorrectorMetrics.withinBaseline(base, baseline: base,
                                                      recoveryTolerance: 0,
                                                      overFireTolerance: 0).ok)
    }

    /// An intent present in `baseline` but absent from `got` is a regression,
    /// even when its baseline counts are all zero.
    func testAbsentIntentIsRegression() {
        let base = ["keavi": CorrectorMetrics.Tally(recovered: 2, total: 2, overFired: 0),
                    "fruit": .init(recovered: 0, total: 2, overFired: 0)]
        // "fruit" is missing from `got` entirely.
        let got  = ["keavi": CorrectorMetrics.Tally(recovered: 2, total: 2, overFired: 0)]
        let r = CorrectorMetrics.withinBaseline(got, baseline: base,
                                                recoveryTolerance: 1, overFireTolerance: 0)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.regressions, ["fruit"])
    }

    /// overFireTolerance: 0 — a bucket that gained exactly 1 over-fire is a regression.
    func testOverFireToleranceZeroFlagsOneOverfire() {
        let base = ["control": CorrectorMetrics.Tally(recovered: 0, total: 5, overFired: 0)]
        let got  = ["control": CorrectorMetrics.Tally(recovered: 0, total: 5, overFired: 1)]
        let r = CorrectorMetrics.withinBaseline(got, baseline: base,
                                                recoveryTolerance: 1, overFireTolerance: 0)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.regressions, ["control"])
    }

    /// recoveryTolerance: 1 — a bucket that dropped exactly 1 recovery is NOT a regression.
    func testRecoveryToleranceOneAllowsOneDrop() {
        let base = ["keavi": CorrectorMetrics.Tally(recovered: 10, total: 12, overFired: 0)]
        let got  = ["keavi": CorrectorMetrics.Tally(recovered: 9,  total: 12, overFired: 0)]
        let r = CorrectorMetrics.withinBaseline(got, baseline: base,
                                                recoveryTolerance: 1, overFireTolerance: 0)
        XCTAssertTrue(r.ok, "A single-clip recovery drop within tolerance must not regress")
        XCTAssertTrue(r.regressions.isEmpty)
    }

    /// A bucket whose `total` shrank beyond recoveryTolerance is a regression
    /// (labeled corpus shrank — signal is unreliable).
    func testCorpusShrinkBeyondToleranceIsRegression() {
        let base = ["bird": CorrectorMetrics.Tally(recovered: 0, total: 9, overFired: 0)]
        // total dropped by 2, which exceeds recoveryTolerance: 1.
        let got  = ["bird": CorrectorMetrics.Tally(recovered: 0, total: 7, overFired: 0)]
        let r = CorrectorMetrics.withinBaseline(got, baseline: base,
                                                recoveryTolerance: 1, overFireTolerance: 0)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.regressions, ["bird"])
    }

    /// A bucket whose `total` shrank by exactly recoveryTolerance (1) is NOT a regression.
    func testCorpusShrinkWithinToleranceIsOk() {
        let base = ["bird": CorrectorMetrics.Tally(recovered: 0, total: 9, overFired: 0)]
        let got  = ["bird": CorrectorMetrics.Tally(recovered: 0, total: 8, overFired: 0)]
        let r = CorrectorMetrics.withinBaseline(got, baseline: base,
                                                recoveryTolerance: 1, overFireTolerance: 0)
        XCTAssertTrue(r.ok)
    }
}
