import XCTest
@testable import ParleqAppCore

/// A3 (lost-dictation safety net): classify a finished capture so a DEAD mic
/// (engine ran but delivered ~zero samples — the capture-failure case) is told
/// apart from genuine quiet/short input. B1 surfaces `.deadInput` to the user
/// ("didn't catch any audio") instead of silently hiding the overlay.
final class CaptureHealthTests: XCTestCase {

    func testTooShortIsClassifiedFirst() {
        // Below the minimum duration → accidental tap, regardless of content.
        XCTAssertEqual(
            CaptureHealth.classify(durationSeconds: 0.1, peakRMS: 0.5, voicedSeconds: 0.0, isAnalyzable: true),
            .tooShort)
    }

    func testDeadInputWhenLongButAllZero() {
        // The maintainer's bug: a full-length capture with peak≈0 (all-zero
        // samples) — the mic delivered silence. This is a capture FAILURE.
        XCTAssertEqual(
            CaptureHealth.classify(durationSeconds: 16.8, peakRMS: 0.0, voicedSeconds: 0.0, isAnalyzable: true),
            .deadInput)
    }

    func testQuietSilenceWhenNonzeroFloorButNoVoice() {
        // A live-but-quiet mic in a silent room: nonzero noise floor, no voiced
        // speech. Genuine silence, NOT a capture failure.
        XCTAssertEqual(
            CaptureHealth.classify(durationSeconds: 2.0, peakRMS: 0.004, voicedSeconds: 0.0, isAnalyzable: true),
            .quietSilence)
    }

    func testOkWhenVoicedSpeechPresent() {
        XCTAssertEqual(
            CaptureHealth.classify(durationSeconds: 2.0, peakRMS: 0.3, voicedSeconds: 0.8, isAnalyzable: true),
            .ok)
    }

    func testNotAnalyzableProceedsToASR() {
        // A malformed buffer we can't analyze → don't suppress; let ASR decide.
        XCTAssertEqual(
            CaptureHealth.classify(durationSeconds: 2.0, peakRMS: 0.0, voicedSeconds: 0.0, isAnalyzable: false),
            .ok)
    }
}
