// VoiceprintReencoder — canonical-context re-encode primitive for the
// voice-enrollment acoustic gate.
//
// PROVEN BUG (validated on real audio; see the `VoiceprintReencodeValidationTests`
// spike): the voiceprint gate pools a candidate word's acoustic embedding from
// WHOLE-UTTERANCE Parakeet encoder frames. Those frames are context-contaminated —
// global self-attention and whole-clip CMVN mel normalization mean the SAME word
// (e.g. "Keavi") embeds differently depending on what else is in the clip (e.g. a
// trailing "kiwi"). A real dictation like "...ship Keavi along with a kiwi" could
// flip every "Keavi" occurrence to REJECT even though each was correctly dictated.
//
// FIX: re-encode JUST the gated word's own audio inside a FIXED, deterministic,
// utterance-INDEPENDENT canonical context (silence-like padding to a constant
// buffer length), then pool the embedding from THAT standalone encoder pass
// instead of the whole-utterance pooled span. A word re-encoded this way embeds
// nearly identically regardless of what else was in the original clip — restoring
// the acoustic gate's designed (context-free) behavior.
//
// FROZEN CONSTANTS (validated; do not casually retune — the numbers behind these
// live in the `VoiceprintReencodeValidationTests` spike + tuning sweep):
//   - pad amplitude:    1e-4   (a fixed, deterministic low-amplitude noise floor —
//                                NOT digital zeros, which hit the log-mel floor and
//                                distort whole-clip CMVN)
//   - canonical buffer: 28,000 samples @ 16 kHz = 1.75s total (word audio + padding)
//   - word margin:      0.08s on each side of the word's ASR-reported span, before
//                       padding
//
// Used by BOTH the serving-time acoustic gate (`VoiceprintDemo.buildGate`,
// store-relevant spans only — re-encoding every span would cost a full extra
// encoder pass per span, which is prohibitively slow to do for every word) and
// enrollment (`VoiceprintCoordinator.localizedSpan`), so enrolled voiceprints and
// served candidates live in the SAME embedding space.
//
// Plain (not `#if Concord`-gated): this type only references FluidAudio's
// `ASRResult` / `EncoderFeatureSequence`, not any Concord type, so it compiles in
// both the public (trait-off) and Concord (trait-on) builds.

import FluidAudio
import Foundation

public enum VoiceprintReencoder {
    /// Deterministic low-amplitude pad amplitude — part of the canonical-context
    /// fingerprint definition, not a tunable knob. See file header.
    public static let padAmplitude: Float = 1e-4
    /// Total canonical buffer length in samples @ 16 kHz (1.75s).
    public static let canonicalBufferSamples = 28_000
    /// Margin (seconds) added on each side of the word's own span before slicing.
    public static let wordMarginSeconds = 0.08

    private static let sampleRate = 16_000.0

    /// A fixed, deterministic, low-amplitude noise sequence (NOT digital zeros —
    /// see file header). Identical every call (same seed) — it's part of the
    /// canonical-context fingerprint definition, not a random nuisance. A simple
    /// LCG keeps this dependency-free.
    private static func fixedNoisePad(count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = Float(state >> 40) / Float(1 << 24) // in [0, 1)
            out[i] = padAmplitude * (r * 2 - 1)
        }
        return out
    }

    /// Re-encode JUST a word's own audio inside the fixed canonical context, and
    /// pool its embedding — independent of everything else in the original
    /// utterance. Slices `[startSec - wordMarginSeconds, endSec + wordMarginSeconds]`
    /// (clamped to the utterance bounds), pads with `fixedNoisePad` to
    /// `canonicalBufferSamples` total, re-runs the encoder over that buffer ALONE
    /// via `transcribe`, and pools the resulting encoder features over the word's
    /// known offset inside the canonical buffer.
    ///
    /// Returns `nil` when the slice is empty/out of bounds, `transcribe` returns
    /// no result, or the result carries no encoder features.
    public static func contextFreeEmbedding(
        utteranceSamples: [Float],
        startSec: Double,
        endSec: Double,
        transcribe: @Sendable (_ samples: [Float]) async -> ASRResult?
    ) async -> [Float]? {
        let sliceStartSec = max(0.0, startSec - wordMarginSeconds)
        let sliceEndSec = min(Double(utteranceSamples.count) / sampleRate, endSec + wordMarginSeconds)
        let startIdx = max(0, Int((sliceStartSec * sampleRate).rounded()))
        let endIdx = min(utteranceSamples.count, Int((sliceEndSec * sampleRate).rounded()))
        guard endIdx > startIdx else { return nil }
        // Clamp an over-long word slice to the canonical buffer. A slice longer
        // than `canonicalBufferSamples` leaves `remaining`/pad lengths at 0, so
        // the buffer would be the raw (unpadded, longer-than-canonical) slice —
        // Parakeet's whole-clip CMVN would then normalise over a different
        // context than the padded case, placing the embedding in a slightly
        // different normalisation space. Truncating keeps every embedding in the
        // same fixed-length canonical context. Only words longer than ~1.59s
        // (1.75s buffer − 2×0.08s margin) hit this — extremely rare.
        let clampedEndIdx = min(endIdx, startIdx + canonicalBufferSamples)
        let wordSlice = Array(utteranceSamples[startIdx..<clampedEndIdx])

        let sliceLen = wordSlice.count
        let remaining = max(0, canonicalBufferSamples - sliceLen)
        let padLen = remaining / 2
        let padLenEnd = remaining - padLen

        var buffer = fixedNoisePad(count: padLen)
        buffer.append(contentsOf: wordSlice)
        buffer.append(contentsOf: fixedNoisePad(count: padLenEnd))

        guard let result = await transcribe(buffer), let features = result.encoderFeatures else {
            return nil
        }
        let wordStartSec = Double(padLen) / sampleRate
        let wordEndSec = Double(padLen + sliceLen) / sampleRate
        return features.pooledEmbedding(startSeconds: wordStartSec, endSeconds: wordEndSec)
    }
}
