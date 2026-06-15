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

## Notes

- WER is scored after Whisper inverse-text-normalization, so number formatting and
  casing differences are largely (not entirely) absorbed. Residual artifacts
  (compound-word hyphenation, "nine thirty" → "9 30") inflate absolute WER a little
  but cancel in version-to-version deltas.
- Latency is wall-clock on the measuring machine (Apple Silicon, ANE). Compare
  within a run, not across machines.
