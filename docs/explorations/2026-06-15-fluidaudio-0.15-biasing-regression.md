# FluidAudio 0.15.x custom-dictionary over-firing — regression or reconfiguration?

**Date:** 2026-06-15
**Branch:** `bench/biasing-roc-harness`
**Tooling:** `bench/` + `asr-bench` (over-fire + recall arms). Apple Silicon, macOS.
**Corpus:** 54-clip over-fire set + 48-clip biasing set (macOS `say`, US/GB/AU voices).
**Companion:** [`2026-06-15-streaming-asr-results.md`](2026-06-15-streaming-asr-results.md) — the streaming spike that declared the 0.15.3 bump "safe to ship," having measured base WER + streaming but **not** the batch biasing arm. This is that missing arm.

## TL;DR

- **It's a genuine regression for Parleq's use case, not a tunable reconfiguration.** FluidAudio PR #634 ("Fix/word boost improvements", first released in **0.14.8**) reworked the CTC vocabulary-rescoring pipeline. For short, English-colliding dictionary terms (CRAN, Snyk, Redis, …) it over-fires badly — replacing ordinary words with dictionary terms even with LLM cleanup off.
- **No exposed knob recovers the old behavior.** Sweeping `minSimilarity` (0.65–0.92), `marginSeconds` (0.10–0.50), `cbw` (0.5–2.0), and the `TDT_EMISSION_DELAY_FRAMES` env override (0/1/3) on 0.15.3, the over-fire floor never drops below ~54, vs **12** on 0.14.5 — and tightening the gates just craters recall.
- **0.15.3 gives Parleq's batch path zero base-ASR upside:** identical WER (4.2%) and latency (~80 ms p50) to 0.14.5. So upgrading would trade working dictionary biasing for nothing.
- **Decision: pin FluidAudio at 0.14.5** (shipped in 0.25.2). It's the correct long-term state, not a stopgap, until upstream fixes short-term KWS or we take on streaming ASR as a deliberate project.

## Background — what PR #634 changed

`410044d1` is the **only** biasing-path commit between 0.14.5 and 0.14.8, and it landed in 0.14.8 (riding forward into all 0.15.x). It bundles:

1. A **blank-aware DP rewrite** (`CtcDPAlgorithm.swift` +270, `VocabularyRescorer+TokenRescoring.swift` +315) — changes the similarity scores the gate compares against.
2. A **−1-frame TDT emission-delay correction** (shifts the CTC search window ~80 ms).
3. **`defaultMarginSeconds` 0.5 → 0.10** and default `cbw` 3.0 → 4.5.

All of it was validated against earnings22 (company names) + FDA drug-name benchmarks — long, distinctive terms where false positives on common English are structurally rare (their result: 6 FPs / 771 files). That validation set never exercises short, English-rhyming terms, which is exactly Parleq's audience.

## Version bisect

| Parleq | FluidAudio | Dictionary biasing |
|---|---|---|
| 0.24.1 | 0.14.5 | clean |
| 0.24.2 | 0.15.3 | over-fires |
| 0.25.1 | 0.14.8 | over-fires (the "revert" landed in the bug via a `0.14.3..<0.15.0` range resolving to newest) |
| **0.25.2** | **0.14.5** | **clean (exact pin)** |

## Over-fire gate (the measurement)

`bench/corpus/overfire.json` is ordinary dictation containing **no** dictionary term but plenty of words acoustically near the `bench/dictionary-overfire.json` terms (`ran`~CRAN, `sync`~Snyk, `ready`~Redis, `everything`~ultrathink, …). Run through the biasing arm, any dictionary term that appears is a false positive. `bench/score_overfire.py` counts terms the rescorer **inserts** (boosted vs. raw); `bench/score_recall.py` measures true-positive recall on the biasing corpus.

Identical generic dictionary + corpus, only the FluidAudio version changing:

| FluidAudio | over-fires | clips hit (of 54) |
|---|---|---|
| **0.14.5** | **12** | 12 |
| 0.14.8 | 52 | 45 |

(Against the original real work dictionary the split was even starker: **12 vs 90**.)

## Can we tune 0.15.3 back? — the ROC sweep

0.14.5 reference operating point: **12 over-fires, 98.3% biasing recall** (raw ASR alone is only 66.7% — the rescorer correctly adds 19 of 20 mis-heard terms, so it is genuinely valuable). Every 0.15.3 setting swept (cbw = 2.0 unless noted):

| 0.15.3 config | over-fires | recall |
|---|---|---|
| minSim 0.65, margin 0.10 *(default)* | 54 | 95.0% |
| minSim 0.75, margin 0.10 | 66 | 88.3% |
| minSim 0.85, margin 0.10 | 66 | 70.0% |
| minSim 0.92, margin 0.10 | 56 | 75.0% |
| minSim 0.65, margin 0.50 (old margin) | 69 | 93.3% |
| minSim 0.65, margin 0.30 | 66 | 91.7% |
| minSim 0.65, margin 0.10, cbw 1.0 | 65 | 93.3% |
| minSim 0.65, margin 0.10, cbw 0.5 | 75 | 80.0% |
| minSim 0.65, margin 0.50, cbw 0.5 | 55 | 81.7% |
| EDF=0 (disable timestamp shift), margin 0.50 | 80 | 96.7% |
| EDF=0, margin 0.10 | 71 | 93.3% |
| EDF=1, margin 0.50 | 68 | 93.3% |
| EDF=3, margin 0.50 | 73 | 81.7% |

**Nothing approaches 12 over-fires.** The floor is ~54 (4.5× worse than 0.14.5), and pushing the gates harder only destroys recall. The diagnostic tell: on 0.15.3 the **false** matches score **higher** similarity than the **true** ones, so no `minSimilarity` threshold separates them. That is the signature of a scoring regression, not a tuning mismatch.

## Base ASR — no upside to offset the loss

Batch base ASR (no biasing), 120 clips, re-scored with `score_wer.py`:

| FluidAudio | mean WER | perfect | latency p50 / p95 |
|---|---|---|---|
| 0.14.5 | 4.2% | 87/120 | 80 / 94 ms |
| 0.15.3 | 4.2% | 87/120 | 79 / 90 ms |

Identical. PR #634 changed rescoring + timestamps, not the batch TDT token output — so 0.15.x offers Parleq's batch path no accuracy or latency gain.

## Verdict

For Parleq's batch + dictionary-biasing path, **0.15.x is strictly worse**: it regresses biasing (untunable via the public API) and gains nothing on base ASR. There is no "FluidAudio upgrade that makes Parleq better" available today.

- **Hold at 0.14.5** (0.25.2). Guarded by the over-fire gate (`Package.swift` pin comment + `bench/README.md`).
- **File upstream** against PR #634 with this ROC data — the path that could unblock a real future upgrade.
- **Revisit** only when upstream fixes short-term KWS, or when streaming ASR (the one genuine 0.15.x upside, but a separate project with no biasing API) is taken on deliberately.

## Reproduce

```bash
# over-fire (false positives)
python3 bench/gen_fixtures.py --corpora overfire --manifest bench/fixtures/manifest-overfire.json
cd parleq-app && swift build --product asr-bench && cd ..
./parleq-app/.build/debug/asr-bench --manifest bench/fixtures/manifest-overfire.json \
  --wav-dir bench/fixtures --paths batch --dictionary bench/dictionary-overfire.json \
  --min-similarity 0.65 --cbw 2.0 --out /tmp/of.json
python3 bench/score_overfire.py /tmp/of.json bench/dictionary-overfire.json

# recall (true positives) — pair the same tuning knobs
./parleq-app/.build/debug/asr-bench --manifest bench/fixtures/manifest-biasing.json \
  --wav-dir bench/fixtures --paths batch --dictionary bench/dictionary.json \
  --min-similarity 0.65 --cbw 2.0 --out /tmp/bi.json
python3 bench/score_recall.py /tmp/bi.json bench/fixtures/manifest-biasing.json
```

`asr-bench` now accepts `--min-similarity`, `--cbw`, and `--margin` so the ROC can be swept without rebuilding; set `TDT_EMISSION_DELAY_FRAMES` in the env to probe the timestamp-correction lever. To sweep a candidate FluidAudio version, change the pin in `parleq-app/Package.swift`, rebuild `asr-bench`, and re-run both arms.
