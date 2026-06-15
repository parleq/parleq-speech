import XCTest
@testable import ParleqAppCore

/// B2 (lost-dictation safety net): during capture, watch the raw mic peak so a
/// DEAD input (the engine is running but delivering ~zero samples) escalates to
/// a "⚠ not hearing your mic" warning after it stays flat-zero for ~1.5 s. A
/// live-but-quiet room (noise floor well above the dead threshold) must NOT
/// trip the warning — that distinction is the whole point, mirroring A3's
/// dead-input vs. genuine-silence split.
final class MicSignalMonitorTests: XCTestCase {

    func testDeadInputWarnsAfterSustainedFlatZero() {
        var monitor = MicSignalMonitor()
        // ~1.6 s of all-zero peaks at 0.08 s chunks → over the 1.5 s threshold.
        var warned = false
        for _ in 0..<20 { warned = monitor.update(peak: 0.0, dt: 0.08) }
        XCTAssertTrue(warned)
        XCTAssertTrue(monitor.notHearing)
    }

    func testNoWarningBeforeThreshold() {
        var monitor = MicSignalMonitor()
        // ~0.8 s of flat-zero — under 1.5 s, so no warning yet (a brief pause
        // before speaking must not flash the warning).
        var warned = false
        for _ in 0..<10 { warned = monitor.update(peak: 0.0, dt: 0.08) }
        XCTAssertFalse(warned)
        XCTAssertFalse(monitor.notHearing)
    }

    func testLiveQuietRoomNeverWarns() {
        var monitor = MicSignalMonitor()
        // A hot mic in a silent room: noise floor ~0.002 peak, above the dead
        // threshold. Even sustained, this is genuine silence, NOT a dead mic.
        var warned = false
        for _ in 0..<40 { warned = monitor.update(peak: 0.002, dt: 0.08) }
        XCTAssertFalse(warned)
        XCTAssertFalse(monitor.notHearing)
    }

    func testSignalResetsTheWarning() {
        var monitor = MicSignalMonitor()
        for _ in 0..<20 { _ = monitor.update(peak: 0.0, dt: 0.08) }
        XCTAssertTrue(monitor.notHearing)
        // Speech arrives → the warning clears immediately and the flat-zero
        // accumulator resets, so a later pause has to re-earn the threshold.
        XCTAssertFalse(monitor.update(peak: 0.3, dt: 0.08))
        XCTAssertFalse(monitor.notHearing)
        for _ in 0..<10 { _ = monitor.update(peak: 0.0, dt: 0.08) }
        XCTAssertFalse(monitor.notHearing)  // only 0.8 s since reset
    }

    func testResetClearsState() {
        var monitor = MicSignalMonitor()
        for _ in 0..<20 { _ = monitor.update(peak: 0.0, dt: 0.08) }
        XCTAssertTrue(monitor.notHearing)
        monitor.reset()
        XCTAssertFalse(monitor.notHearing)
    }
}
