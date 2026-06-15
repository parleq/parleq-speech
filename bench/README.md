# asr-bench — on-device ASR benchmark

Dev tooling for comparing Parleq's on-device ASR paths (FluidAudio Parakeet) on
latency and WER. **Not shipped in the app** — `asr-bench` is a separate SwiftPM
product, and these fixtures are never bundled (see the spec's Mergeability section).

Design + results:
- `docs/explorations/2026-06-15-streaming-asr-spike-design.md`
- `docs/explorations/2026-06-15-streaming-asr-results.md`

## Layout

```
bench/
  corpus/general.json     general dictation utterances (text + ids)
  corpus/biasing.json     dictionary-term utterances
  dictionary.json         boosting terms + aliases (for the --dictionary arm)
  gen_fixtures.py         macOS `say` -> 16 kHz mono 16-bit WAV + manifest
  fixtures/*.wav          committed fixtures (regenerable)
  fixtures/manifest.json  clip -> reference transcript pairing
  score_wer.py            jiwer + Whisper-normalizer scorer
  results/                results.json + summaries per run
```

## Run

```bash
# 1. (optional) regenerate fixtures — needs macOS `say`, creds-free
python3 bench/gen_fixtures.py

# 2. build the bench (FluidAudio only; does not compile the app graph)
cd parleq-app && swift build --product asr-bench && cd ..

# 3. transcribe the corpus
./parleq-app/.build/debug/asr-bench \
    --manifest bench/fixtures/manifest.json \
    --wav-dir bench/fixtures \
    --paths batch \
    --out bench/results/batch.json

# 4. score WER + latency
python3 -m venv bench/.venv
bench/.venv/bin/pip install jiwer whisper-normalizer
bench/.venv/bin/python bench/score_wer.py bench/results/batch.json
```

`--paths` accepts `batch`, `eou`, `nemotron` (comma-separated). `--dictionary
bench/dictionary.json` enables vocab boosting where the path supports it.
`--pacing realtime|max` controls how streaming chunks are fed (realtime = ~1×
audio speed, yields the user-felt post-release latency; max = throughput).

## Over-fire regression gate (FluidAudio bumps)

`corpus/overfire.json` is the inverse of `biasing.json`: ordinary dictation that
contains **no** dictionary term but plenty of words acoustically near the
`dictionary-overfire.json` terms (`ran`~CRAN, `sync`~Snyk, `ready`~Redis, …).
Run it through the biasing arm and any dictionary term that appears is a *false
positive* — an over-fire. This is the gate that catches the FluidAudio-0.14.8
over-firing regression (PR #634); see the pin comment in `parleq-app/Package.swift`.

```bash
python3 bench/gen_fixtures.py --corpora overfire \
    --manifest bench/fixtures/manifest-overfire.json
cd parleq-app && swift build --product asr-bench && cd ..
./parleq-app/.build/debug/asr-bench \
    --manifest bench/fixtures/manifest-overfire.json --wav-dir bench/fixtures \
    --paths batch --dictionary bench/dictionary-overfire.json \
    --out bench/results/overfire-<ver>.json
python3 bench/score_overfire.py bench/results/overfire-<ver>.json \
    bench/dictionary-overfire.json
```

Baseline (committed `results/overfire-0.14.5.json` vs `overfire-0.14.8.json`):
**~12 over-fires on the good 0.14.5, ~52 on the regressed 0.14.8.** A future bump
passes the gate only if it stays near the 0.14.5 baseline. (The 0.14.5 residual is
inherent to ASR-biasing short collision-prone terms, not a regression — mitigate
per-term with `biasing: "llmOnly"`.) `score_overfire.py` ends with a machine-readable
JSON summary line for CI diffing.

## Notes

- WER is scored after Whisper inverse-text-normalization, so number formatting and
  casing differences are largely (not entirely) absorbed. Residual artifacts
  (compound-word hyphenation, "nine thirty" → "9 30") inflate absolute WER a little
  but cancel in version-to-version deltas.
- Latency is wall-clock on the measuring machine (Apple Silicon, ANE). Compare
  within a run, not across machines.
