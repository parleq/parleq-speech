// SilenceDetector — RMS-based voice-activity check on a captured WAV
// buffer, used as a pre-ASR guard against Parakeet TDT's silence
// hallucinations.
//
// Parakeet (and most CTC/RNNT models) sometimes return a single short
// word ("yeah", "okay", "thank you") when given audio that's longer
// than ~200ms but contains no real speech (silence, breath, room
// noise). The model has a non-trivial prior on producing SOMETHING
// rather than nothing, especially at the end of a clip. AppState's
// existing 200ms duration guard skips obviously-accidental taps, and
// its empty-transcript guard skips clearly-empty results — but a
// phantom "yeah" passes both gates and gets pasted into the focused
// app as if the user had said it.
//
// This detector runs after the duration guard but before invoking
// ASR. It computes RMS over short windows of the captured PCM samples
// and sums how much voiced audio is present. Below a threshold (50ms
// of voiced content), we treat the entire capture as silent and
// short-circuit the ASR/LLM pipeline.
//
// The detector is intentionally simple — RMS over 20ms frames, no
// spectral analysis, no ML. It's a noise-gate, not a speech
// classifier. Spectral / ML VADs (WebRTC VAD, Silero) would catch
// non-speech tones as "not voiced", but we don't need that: any
// audio above the threshold is something the user might have meant
// to dictate (a hum, a sigh, a quick "yes"), and ASR can handle it.
// We only want to reject true silence + room noise.

import Foundation

public enum SilenceDetector {
    /// Result of analyzing a WAV buffer. All fields are derived from
    /// the same single pass over the samples (when `isAnalyzable` is
    /// true). When `isAnalyzable` is false, the buffer was malformed
    /// and the voiced-duration / peak fields are not meaningful —
    /// callers should treat that as "couldn't tell, proceed with ASR"
    /// rather than as silence.
    public struct Result: Equatable {
        /// Total time (seconds) spent in 20ms frames whose RMS
        /// exceeded the voicing threshold. A real word like "yes" is
        /// typically 150-300ms of voiced content; a deliberate
        /// silent-tap gesture is essentially 0ms. Meaningful only
        /// when `isAnalyzable` is true.
        public let voicedDurationSeconds: TimeInterval

        /// Peak RMS observed across all frames. Useful for diagnostics
        /// — distinguishes "mic was hot but the user didn't speak"
        /// (peak ~0.001-0.01, voiced=0) from "mic was muted" (peak 0).
        /// Meaningful only when `isAnalyzable` is true.
        public let peakRMS: Float

        /// False when the buffer didn't look like a 16-bit mono PCM
        /// WAV (header check failed, too short to contain a frame,
        /// etc.). Callers MUST gate any silence-suppression decision
        /// on this flag — without it, the voicedDuration=0 returned
        /// for malformed input would falsely trigger suppression.
        public let isAnalyzable: Bool

        public init(voicedDurationSeconds: TimeInterval, peakRMS: Float, isAnalyzable: Bool) {
            self.voicedDurationSeconds = voicedDurationSeconds
            self.peakRMS = peakRMS
            self.isAnalyzable = isAnalyzable
        }
    }

    /// Voicing threshold for normalized 16-bit PCM amplitude. The
    /// constant is calibrated against captures from MacBook built-in
    /// mics + Razer Seiren USB mic in a few rooms:
    ///
    ///   Quiet room baseline:       ~0.0005-0.001 RMS
    ///   Office with HVAC running:  ~0.001-0.002 RMS
    ///   Whispered speech:          ~0.002-0.005 RMS (very mic-dependent)
    ///   Conversational speech:     ~0.05-0.20 RMS
    ///
    /// 0.002 sits between typical room noise and whispered speech.
    /// The initial 0.005 value was tuned only against conversational
    /// speech and missed whisper-level audio entirely — verified by
    /// real-world testing on 0.13.0 prep: users speaking quietly or
    /// whispering would have all their audio rejected.
    private static let voicingRMSThreshold: Float = 0.002

    /// Window size in milliseconds. 20ms is the standard VAD frame
    /// length (matches WebRTC VAD's smallest mode and most academic
    /// papers). Short enough to localize within a syllable, long
    /// enough that the RMS estimate is stable.
    private static let frameMilliseconds: Int = 20

    /// Analyze a 16-bit mono PCM WAV buffer and return how much of it
    /// contains voiced audio. Returns zero-valued result on malformed
    /// input — callers should treat that as "couldn't tell, proceed
    /// with ASR" by checking against the voicing threshold themselves.
    /// (In practice AppState pairs this with the existing 200ms
    /// duration guard, so a truly malformed buffer wouldn't reach
    /// here anyway.)
    ///
    /// Implementation deliberately does NOT throw on malformed input.
    /// We're a noise-gate; failing safe means returning a result with
    /// `isAnalyzable = false`, which signals to the caller that they
    /// should proceed with ASR rather than suppress. AppState gates
    /// its suppression decision on `isAnalyzable && voicedDuration < threshold`.
    public static func analyze(wavData: Data) -> Result {
        // Bail safely on anything that doesn't look like a 16-bit PCM
        // WAV. AudioRecorder.buildWAVData always produces this format,
        // so the only way we'd see anything else is if some future
        // caller hands us synthetic data. Signal isAnalyzable=false
        // so the caller proceeds with ASR rather than suppressing.
        guard let format = parseWAVHeader(wavData) else {
            return Result(voicedDurationSeconds: 0, peakRMS: 1.0, isAnalyzable: false)
        }

        let frameSamples = (format.sampleRate * frameMilliseconds) / 1000
        guard frameSamples > 0 else {
            return Result(voicedDurationSeconds: 0, peakRMS: 1.0, isAnalyzable: false)
        }

        let sampleBytes = wavData[44...]
        let totalSamples = sampleBytes.count / 2
        let frameCount = totalSamples / frameSamples
        guard frameCount > 0 else {
            // Less than one full frame — too short to analyze.
            // Upstream 200ms duration guard catches this case
            // before we get here, but be defensive: signal
            // unanalyzable so the caller doesn't suppress.
            return Result(voicedDurationSeconds: 0, peakRMS: 0, isAnalyzable: false)
        }

        var voicedFrames = 0
        var peak: Float = 0

        // Iterate frame-by-frame, computing RMS. We read directly out
        // of the Data without copying — withUnsafeBytes scopes a raw
        // pointer into a typed Int16 buffer.
        sampleBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            let frames = UnsafeBufferPointer(start: base, count: totalSamples)

            for frameIndex in 0..<frameCount {
                let frameStart = frameIndex * frameSamples
                var sumOfSquares: Float = 0
                for i in 0..<frameSamples {
                    // Normalize int16 to [-1, 1] before squaring.
                    let sample = Float(frames[frameStart + i]) / 32768.0
                    sumOfSquares += sample * sample
                }
                let rms = (sumOfSquares / Float(frameSamples)).squareRoot()
                if rms > peak { peak = rms }
                if rms > voicingRMSThreshold {
                    voicedFrames += 1
                }
            }
        }

        let voicedDuration = TimeInterval(voicedFrames) * TimeInterval(frameMilliseconds) / 1000.0
        return Result(voicedDurationSeconds: voicedDuration, peakRMS: peak, isAnalyzable: true)
    }

    // MARK: - Internal helpers

    private struct WAVFormat {
        let sampleRate: Int
        let numChannels: Int
        let bitsPerSample: Int
    }

    /// Parse the standard 44-byte PCM WAV header. Returns nil for
    /// anything that doesn't look like 16-bit mono PCM at a known
    /// sample rate. We don't try to handle every WAV variant — the
    /// only producer in the project is AudioRecorder.buildWAVData,
    /// which always emits canonical 16-bit mono PCM.
    private static func parseWAVHeader(_ data: Data) -> WAVFormat? {
        guard data.count >= 44 else { return nil }

        // RIFF / WAVE magic
        guard data[0..<4] == Data([0x52, 0x49, 0x46, 0x46]) else { return nil }  // "RIFF"
        guard data[8..<12] == Data([0x57, 0x41, 0x56, 0x45]) else { return nil }  // "WAVE"
        guard data[12..<16] == Data([0x66, 0x6D, 0x74, 0x20]) else { return nil }  // "fmt "

        // Audio format: 1 = PCM. Anything else is unsupported.
        let audioFormat = Int(data[20]) | (Int(data[21]) << 8)
        guard audioFormat == 1 else { return nil }

        let numChannels = Int(data[22]) | (Int(data[23]) << 8)
        let sampleRate = Int(data[24]) |
                         (Int(data[25]) << 8) |
                         (Int(data[26]) << 16) |
                         (Int(data[27]) << 24)
        let bitsPerSample = Int(data[34]) | (Int(data[35]) << 8)

        // Only 16-bit mono is supported. AudioRecorder always emits
        // this, so any other shape is a malformed input we should
        // reject.
        guard numChannels == 1, bitsPerSample == 16, sampleRate > 0 else { return nil }

        return WAVFormat(
            sampleRate: sampleRate,
            numChannels: numChannels,
            bitsPerSample: bitsPerSample
        )
    }
}
