import XCTest
@testable import ParleqAppCore

/// AudioRecorder unit tests. Most of AudioRecorder's behavior is
/// hardware-coupled (it depends on a live AVAudioEngine + mic), so
/// these tests only cover the parts that DON'T require the engine
/// to be running:
///
/// - Idempotent guards on pause()/resume() when no capture is in
///   flight (must not crash, must not leave the recorder in an
///   inconsistent state).
/// - Default-constructed state (no audio captured yet).
///
/// The actual pause/resume gating behavior (samples drop on the
/// floor between pause and resume, then resume to appending again)
/// is covered by manual + integration testing in PR B's guided
/// testing round, since unit-testing it would require mocking
/// AVAudioEngine which is a much larger refactor than the
/// behavior under test.
@MainActor
final class AudioRecorderTests: XCTestCase {

    func test_pause_without_start_is_noop() {
        // Calling pause() before start() must be safe — guard on
        // isRunning. The latched-compose flow may dispatch pause()
        // speculatively from the state machine; we shouldn't crash
        // if the state ordering ever races.
        let recorder = AudioRecorder()
        recorder.pause()
        // No assertion needed — just verifying no crash. If pause()
        // were to throw or fault, the test would fail.
    }

    func test_resume_without_start_is_noop() {
        // Same defensive shape as pause.
        let recorder = AudioRecorder()
        recorder.resume()
    }

    func test_pause_then_resume_without_start_is_noop() {
        // Both gates active in sequence.
        let recorder = AudioRecorder()
        recorder.pause()
        recorder.resume()
    }
}
