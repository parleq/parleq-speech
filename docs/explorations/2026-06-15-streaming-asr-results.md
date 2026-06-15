# Streaming ASR vs. batch — benchmark results

**Date:** 2026-06-15
**Branch:** `spike/streaming-asr`
**Design:** [`2026-06-15-streaming-asr-spike-design.md`](2026-06-15-streaming-asr-spike-design.md)
**Tooling:** `bench/` + `asr-bench` (this branch). Machine: Apple M4 Max, 64 GB, macOS 26.5.1.
**Corpus:** 120 clips (40 utterances × 3 macOS `say` voices, US/GB/AU), median clip 3.47 s.

## TL;DR

- **The FluidAudio 0.14.5 → 0.15.3 bump is safe to ship on its own.** Zero batch-API
  drift (compiled with no source changes), zero WER change, latency unchanged. Take
  it independently of any streaming decision.
- **Nemotron-560 streaming matches batch quality** (WER 5.5% vs 4.2%) and gives a
  ~27 ms first-partial — live "ghost text" is genuinely feasible.
- **The streaming latency win is marginal on Apple Silicon for short dictations**
  (post-release ~13 ms vs batch ~80 ms — both imperceptible). It only becomes
  compelling for long utterances (batch latency scales with length; streaming stays
  ~constant) or slower hardware.
- **Streaming has no vocabulary-biasing API.** Adopting it would drop Parleq's custom
  dictionary boosting on the ASR side. This is the real blocker, not latency.
- **EOU-160 is not quality-competitive** (WER 20.9%, drops leading words).

## Headline numbers

| Path | FluidAudio | WER mean | WER med | post-release p50/p95 | 1st partial p50 | RTFx |
|---|---|---|---|---|---|---|
| batch | 0.14.5 | 4.25% | 0.0% | 80 / 94 ms¹ | — | ~42× |
| batch | 0.15.3 | 4.25% | 0.0% | 79 / 90 ms¹ | — | ~43× |
| eou-160 | 0.15.3 | 20.92% | 15.4% | 12 / 18 ms | 54 ms | ~11× |
| nemotron-560 | 0.15.3 | 5.46% | 0.0% | 13 / 16 ms | 27 ms | ~37× |

¹ For batch, the entire transcription happens after the user releases the hotkey, so
its full `latency_ms` *is* the post-release window. For streaming, post-release is the
final-chunk `process()` + `finish()` — the work left after speech ends.

WER is scored with the Whisper English normalizer (ITN) + `jiwer`. Absolute WER is
inflated a little by scoring artifacts (e.g. "nine thirty" → "9 30", "standup" →
"stand-up") that affect all paths equally, so cross-path comparison is sound.

## Phase 1 / 2 — batch baseline and the version bump

The harness reproduces our known-good batch behavior on the pinned 0.14.5 (4.25% mean
WER, 87/120 perfect, ~80 ms). Bumping to 0.15.3:

- **No API drift.** `asr-bench` compiled against 0.15.3 with zero source changes.
  Upgrade cost for the batch path is effectively nil.
- **No regression.** mean WER 4.25% → 4.25% (Δ +0.00 pp, gate ≤ +0.5 pp); median
  latency 80 → 79 ms (Δ −1.2%, gate ≤ +15%). **Gate: PASS.**

## Phase 3 — streaming

Both streaming managers (`StreamingEouAsrManager`, `StreamingNemotronAsrManager`) run
in-process on the ANE via `loadModels(from:)` → `process(audioBuffer:)` → `finish()`,
with a `setPartialCallback` for interim "ghost text".

**Nemotron-560 is the viable streaming path.** WER 5.5% (within ~1.3 pp of batch),
0 failures, first partial at 27 ms, post-release ~13 ms. The 560 ms chunk size is its
lowest-latency tier; larger tiers (1120/2240 ms) trade latency for throughput and are
documented as WER-neutral upstream.

**EOU-160 is not competitive.** WER 20.9%; it systematically drops leading words
("Open the settings…" → "the settings…", "I dictated…" → "dictated…") and garbles
terms. This is the **model's behavior, not a feeding artifact** — feeding each clip as
one whole buffer (the FluidAudio CLI's pattern) gave an identical 20.92% WER. One clip
also crashed the EOU pipeline with a CoreML `zero shape error` (1/120), yielding an
empty transcript.

### On the latency win

Post-release latency is measured as the final chunk's `process()` + `finish()` — the
only work that, in real use, still has to happen after the user stops speaking
(earlier chunks are processed during speech). It is **bounded by one chunk's
processing and independent of utterance length**.

Batch, by contrast, transcribes the whole utterance after release, so its latency
**scales with utterance length**. On our ~3.5 s clips batch is already ~80 ms (RTFx
~42×) — imperceptible. Extrapolating by RTFx, a 30 s utterance would be ~700–800 ms
batch vs. still ~13–30 ms streaming. So the streaming latency advantage is real but
only *matters* for long dictations or slower hardware. For Parleq's short-dictation,
press-release-paste flow on Apple Silicon, **batch latency is not a problem streaming
needs to solve.**

The stronger reason to want streaming is **live partials** (ghost text during speech,
~27 ms first token) — a UX feature, not a latency fix.

## Phase 3 — dictionary biasing

**Streaming exposes no vocabulary/biasing API.** The CTC keyword-spotting + rescoring
stack (`CtcKeywordSpotter`, `VocabularyRescorer`) that powers Parleq's custom
dictionary is a **batch-only** facility operating on full-utterance samples + token
timings. The streaming managers take no custom vocabulary. So switching the default
ASR to streaming would **lose dictionary biasing on the ASR side** unless we
re-implement it as a post-hoc rescoring pass over the streamed transcript +
`finishWithTokenTimings()` — possible, but extra work.

For the batch path we measured what biasing buys, and it is **highly sensitive to
dictionary size** on this corpus:

| Dictionary | Parleq clips (plain → +vocab) | general corpus (plain → +vocab) |
|---|---|---|
| 1 term ("Parleq" + real aliases) | 10.33% → **3.54%** (0→9/12 perfect) | 3.10% → 14.27% |
| 10 terms, no aliases | 5.97% → 26.92%¹ | 3.10% → 28.25% |
| 10 terms, broad aliases | 5.97% → 23.22%¹ | 3.10% → 32.40% |

¹ biasing-corpus aggregate (all 10 terms' clips).

The single-term case shows biasing **working as designed** — it reliably fixes the
target term ("Parlac"/"Parlek"/"Parlaq" → "Parleq"). But it also fires on audio that
doesn't contain the term (general corpus 3.1% → 14.3%), and the false-positive damage
grows sharply with dictionary size.

> **Caveat — these biasing numbers are on synthetic `say` audio.** The CTC spotter is
> acoustic; synthetic voices plausibly produce more spurious near-matches than real
> speech, so the false-positive rates here are likely an upper bound and should be
> re-measured on real human recordings before drawing conclusions about the shipping
> feature. The latency and base-WER results are far less sensitive to TTS-vs-real.

## Recommendation (go / no-go)

1. **Adopt the 0.15.3 bump** — independently, in its own small PR. It is free and safe.
2. **Do not switch the default ASR to streaming for latency reasons.** Batch is already
   imperceptibly fast on Apple Silicon for short dictation, and streaming would cost us
   dictionary biasing.
3. **Revisit streaming specifically to ship live partials (ghost text)** via
   Nemotron-560, *if* we first solve biasing as a post-stream rescoring pass and
   validate biasing false-positive rates on real speech. Treat it as a UX feature with
   a known cost, not a latency optimization.
4. **Drop EOU-160 from consideration** at this chunk size (accuracy + a pipeline crash).

## Reproduce

```bash
cd parleq-app && swift build --product asr-bench && cd ..
./parleq-app/.build/debug/asr-bench --paths batch,eou,nemotron \
    --manifest bench/fixtures/manifest.json --wav-dir bench/fixtures \
    --out bench/results/run.json
# biasing arm:
./parleq-app/.build/debug/asr-bench --paths batch --dictionary bench/dictionary-minimal.json \
    --manifest bench/fixtures/manifest.json --wav-dir bench/fixtures --out bench/results/bias.json
bench/.venv/bin/python bench/score_wer.py bench/results/run.json
```

Raw results: `bench/results/*.json`. Per-phase commits on `spike/streaming-asr`.
