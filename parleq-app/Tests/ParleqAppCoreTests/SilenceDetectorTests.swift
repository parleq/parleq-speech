import XCTest
@testable import ParleqAppCore

final class SilenceDetectorTests: XCTestCase {

    // MARK: - Fixture builders
    //
    // Fixtures are synthesized in-process rather than loaded from
    // disk so the test target stays free of resource-bundle wiring.
    // All fixtures are 16kHz mono 16-bit PCM — the exact shape
    // AudioRecorder.buildWAVData produces.

    private static let sampleRate = 16000

    private static func makeWAV(samples: [Int16]) -> Data {
        var d = Data()
        let byteCount = samples.count * 2
        // RIFF header
        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46])                     // "RIFF"
        d.append(contentsOf: UInt32(36 + byteCount).littleEndianBytes)      // file size - 8
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45])                     // "WAVE"
        // fmt chunk
        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])                     // "fmt "
        d.append(contentsOf: UInt32(16).littleEndianBytes)                  // subchunk1 size
        d.append(contentsOf: UInt16(1).littleEndianBytes)                   // PCM
        d.append(contentsOf: UInt16(1).littleEndianBytes)                   // mono
        d.append(contentsOf: UInt32(sampleRate).littleEndianBytes)          // sample rate
        d.append(contentsOf: UInt32(sampleRate * 2).littleEndianBytes)      // byte rate
        d.append(contentsOf: UInt16(2).littleEndianBytes)                   // block align
        d.append(contentsOf: UInt16(16).littleEndianBytes)                  // bits per sample
        // data chunk
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61])                     // "data"
        d.append(contentsOf: UInt32(byteCount).littleEndianBytes)           // data size
        for s in samples {
            d.append(contentsOf: s.littleEndianBytes)
        }
        return d
    }

    /// 1.5s of pure silence (zero amplitude). The "user held the
    /// hotkey but never spoke" canonical input.
    private static func silenceWAV() -> Data {
        makeWAV(samples: Array(repeating: 0, count: sampleRate * 3 / 2))
    }

    /// 1.5s of 440Hz sine wave at 0.3 amplitude. A pure tone is
    /// loud enough to be "voiced" by an RMS detector; this is the
    /// canonical "audio that should reach ASR" positive case.
    private static func toneWAV(amplitude: Float = 0.3) -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(sampleRate * 3 / 2)
        for i in 0..<(sampleRate * 3 / 2) {
            let s = Float(amplitude) * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
            samples.append(Int16(s * 32767))
        }
        return makeWAV(samples: samples)
    }

    /// 1.5s of very-low-amplitude noise. Mimics a mic in a quiet
    /// room — picks up something but not speech. Each sample is a
    /// pseudo-random value scaled to ~0.001 amplitude (well below
    /// the 0.005 voicing threshold).
    private static func roomNoiseWAV() -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(sampleRate * 3 / 2)
        // Deterministic seed via linear congruential generator so the
        // test is reproducible without depending on system RNG.
        var seed: UInt64 = 42
        for _ in 0..<(sampleRate * 3 / 2) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let normalized = Float(seed % 2000) / 2000.0 - 0.5  // [-0.5, 0.5]
            let scaled = normalized * 0.002  // ~0.001 RMS (well under threshold)
            samples.append(Int16(scaled * 32767))
        }
        return makeWAV(samples: samples)
    }

    // MARK: - Pure silence

    func test_silence_returns_zero_voiced_duration() {
        let result = SilenceDetector.analyze(wavData: Self.silenceWAV())
        XCTAssertTrue(result.isAnalyzable, "Well-formed WAV should be analyzable")
        XCTAssertEqual(result.voicedDurationSeconds, 0,
                       "1.5s of zero-amplitude audio should produce zero voiced duration")
        XCTAssertEqual(result.peakRMS, 0, "Pure silence has zero peak RMS")
    }

    // MARK: - Audio above voicing threshold

    func test_tone_at_moderate_amplitude_counts_as_voiced() {
        let result = SilenceDetector.analyze(wavData: Self.toneWAV(amplitude: 0.3))
        // 440Hz @ 0.3 amplitude has RMS ≈ 0.3 / sqrt(2) ≈ 0.21 — far
        // above the 0.005 threshold. Every 20ms frame should count
        // as voiced.
        XCTAssertTrue(result.isAnalyzable)
        XCTAssertGreaterThan(result.voicedDurationSeconds, 1.4,
                             "1.5s of clearly-audible tone should be ~entirely voiced")
        XCTAssertGreaterThan(result.peakRMS, 0.1,
                             "Peak RMS should reflect the tone's amplitude")
    }

    func test_real_world_threshold_a_quiet_word_counts_as_voiced() {
        // Even quiet speech crosses the threshold. Simulate with a
        // lower-amplitude tone (0.05 — barely audible) and confirm
        // some frames count as voiced.
        let result = SilenceDetector.analyze(wavData: Self.toneWAV(amplitude: 0.05))
        XCTAssertTrue(result.isAnalyzable)
        XCTAssertGreaterThan(result.voicedDurationSeconds, 0.05,
                             "Even a quiet sound (~0.035 RMS) should produce voiced frames > the 50ms gate AppState uses")
    }

    func test_whisper_level_audio_counts_as_voiced() {
        // A 0.004 amplitude tone has RMS ≈ 0.003 — right in the
        // typical whisper range (0.002-0.005). Verifies the
        // post-tuning threshold (0.002) catches whispers that the
        // pre-tuning threshold (0.005) missed. Without this test,
        // anyone bumping the threshold back up could silently
        // regress whisper detection — the constant changes but
        // tests still pass because the other quiet-word test uses
        // 0.05 amplitude which is well above any reasonable
        // threshold value.
        let result = SilenceDetector.analyze(wavData: Self.toneWAV(amplitude: 0.004))
        XCTAssertTrue(result.isAnalyzable)
        XCTAssertGreaterThan(result.voicedDurationSeconds, 0.5,
                             "Whisper-level audio (~0.003 RMS) should cross the voicing threshold and produce substantial voiced duration")
    }

    // MARK: - Audio below voicing threshold

    func test_room_noise_below_threshold_is_not_voiced() {
        let result = SilenceDetector.analyze(wavData: Self.roomNoiseWAV())
        XCTAssertTrue(result.isAnalyzable)
        // Quiet room noise is the realistic "user held hotkey, didn't
        // speak" case. RMS stays under the threshold; voiced
        // duration should remain at or near zero.
        XCTAssertLessThan(result.voicedDurationSeconds, 0.05,
                          "Quiet room noise should not produce more than a frame's worth of voiced audio")
    }

    // MARK: - Defensive paths (all must return isAnalyzable=false)

    func test_empty_data_signals_unanalyzable_so_caller_does_not_suppress() {
        // Empty input is malformed (no WAV header). The detector
        // must signal isAnalyzable=false so the AppState caller's
        // suppression-gate doesn't fire on the default zero
        // voicedDuration — otherwise real ASR work would be
        // accidentally short-circuited on any unexpected buffer
        // shape.
        let result = SilenceDetector.analyze(wavData: Data())
        XCTAssertFalse(result.isAnalyzable,
                       "Malformed input MUST signal isAnalyzable=false (caller proceeds with ASR)")
    }

    func test_malformed_header_signals_unanalyzable() {
        let result = SilenceDetector.analyze(wavData: Data(repeating: 0xAB, count: 44))
        XCTAssertFalse(result.isAnalyzable)
    }

    func test_non_pcm_audio_format_signals_unanalyzable() {
        // Build a valid-looking header but with audioFormat=2 (which
        // would be ADPCM or similar — not PCM). We don't support it.
        var d = Self.silenceWAV()
        d[20] = 2  // audioFormat low byte
        let result = SilenceDetector.analyze(wavData: d)
        XCTAssertFalse(result.isAnalyzable)
    }

    func test_stereo_audio_signals_unanalyzable() {
        var d = Self.silenceWAV()
        d[22] = 2  // numChannels low byte
        let result = SilenceDetector.analyze(wavData: d)
        XCTAssertFalse(result.isAnalyzable)
    }
}

// MARK: - Little-endian byte helpers

private extension UInt16 {
    var littleEndianBytes: [UInt8] {
        [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF)]
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        [
            UInt8(self & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 24) & 0xFF),
        ]
    }
}

private extension Int16 {
    var littleEndianBytes: [UInt8] {
        let u = UInt16(bitPattern: self)
        return u.littleEndianBytes
    }
}
