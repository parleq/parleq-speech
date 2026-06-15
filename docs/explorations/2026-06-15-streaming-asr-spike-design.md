# Streaming ASR vs. batch benchmark (FluidAudio 0.15.3)

**Date:** 2026-06-15
**Branch:** `spike/streaming-asr` (worktree `../parleq-worktrees/streaming-asr-spike`)
**Status:** design approved, pre-implementation

This is a **mergeable** piece of work: it adds a permanent `asr-bench` dev tool, a
committed voice-fixture corpus, and this doc to the repo for future reference. It
does **not** change the shipping ASR path — adopting streaming (or the version bump)
in the app is a separate, later decision this benchmark informs.

## Goal

Answer, with numbers, whether FluidAudio's in-process streaming ASR is worth adopting
in Parleq. Three questions, ranked:

1. **Post-release latency** — how much of the "release hotkey → transcript ready"
   window does streaming collapse vs. today's batch transcribe?
2. **Quality / WER** — does streaming match the batch path's word error rate on a
   representative dictation corpus?
3. **Dictionary-biasing impact** — our custom-dictionary feature relies on FluidAudio
   CTC vocab boosting in the batch path. Do the streaming managers accept a
   vocabulary at all, and if not, how big is the WER regression on dictionary-heavy
   speech?

Non-goals (explicit YAGNI): overlay live-partial UX, streaming the LLM-cleanup
output, real `LocalASR` integration in the app, config/MDM surface. This work does
not touch MLX / `mlx.metallib` (FluidAudio only).

## Background

- Today the app pins **FluidAudio 0.14.5** (`Package.swift` range `0.14.3..<0.15.0`;
  `Package.resolved` is tracked). `LocalASR.swift` uses the **batch** API only:
  `AsrModels.downloadAndLoad(...)` → `AsrManager.transcribe(samples, decoderState:)`.
  Transcription runs *after* the user releases the hotkey.
- Upstream is now on **0.15.3**, which added real **in-process, on-device
  (CoreML/ANE) streaming ASR**: `StreamingAsrManager`, `StreamingEouAsrManager`
  (Parakeet + end-of-utterance detection), and `StreamingNemotronAsrManager`
  (Nemotron, encoder cache across chunks, per-token timings as of 0.15.3).
- The existing `StreamingASRClient.swift` in the app is an HTTP/SSE client for the
  retired sidecar's `/stream-nemo` endpoint — **not** in-process FluidAudio. It is
  not the path under test here.

### Why the harness must be Swift

FluidAudio runs Parakeet in-process on the Apple Neural Engine. Go and Python cannot
call it in-process — only over HTTP, which is exactly the sidecar path we are moving
away from. To benchmark the *real* path honestly, the ASR-runner has to be Swift and
link FluidAudio directly.

## Prior art

The methodology reuses a pattern from an earlier internal ASR-evaluation effort: a
TTS fixture pipeline (16 kHz mono 16-bit WAV + a manifest pairing each WAV →
reference transcript) and a `jiwer` + Whisper-normalizer WER harness emitting
per-clip rows and an aggregate summary.

We **borrow the methodology, not the assets.** That earlier corpus is domain-specific
and not ours to publish, so it is **not** vendored into this public repo. Instead we
author a fresh, Parleq-appropriate corpus and commit it here (see Fixtures), generated
from macOS `say` so it needs no third-party TTS credentials. The WER-scoring approach
(`jiwer` + Whisper normalizer) is reimplemented as a small committed script so the
benchmark is fully self-contained.

## Mergeability & safety

- **`asr-bench` is a separate `executableTarget` + product** in
  `parleq-app/Package.swift`. The app bundle is built from the **`parleq-app`**
  product only, so the bench target ships nothing in the app.
- **Fixtures are committed to the GitHub repo but never packaged into the app.**
  They live under a dedicated `bench/` dir, are **not** declared as `resources:` of
  the `parleq-app` target, and are **not** copied by `parleq-app/scripts/make-app.sh`.
  A verification step confirms a built `.app` contains none of them.
- **No proprietary data in the public repo.** Fixtures are freshly authored
  dictation-shaped utterances (plus a dictionary-biasing set); no internal or
  third-party corpus is committed.
- **The FluidAudio bump is staged.** The bench tool + fixtures + this doc are
  mergeable regardless of results. The **0.14.5 → 0.15.3 bump** in `Package.swift` /
  `Package.resolved` merges only if the Phase 2 regression gate passes.

## Architecture

```
committed fixtures (WAV + manifest)
      │
      ▼
asr-bench  (Swift CLI, links FluidAudio + ParleqAppCore)
   paths: batch | eou | nemotron        biasing: on | off
      │
      ▼
results.json   { id, path, ref, hyp, latency_ms, post_release_ms, first_partial_ms, biasing }
      │
      ▼
score-wer.py   (committed: jiwer + Whisper-normalizer ITN)
      │
      ▼
summary table   path × { mean/median WER, post-release p50/p95, first-partial p50, biasing Δ }
```

### Components

1. **`asr-bench` — Swift executable target** in `parleq-app/Package.swift` (separate
   product, never bundled). Links `FluidAudio` and `ParleqAppCore` (to reuse the
   existing model-load path and the CTC vocab-boosting code for the biasing arm).
   - Flags: `--manifest <path>`, `--wav-dir <dir>`, `--paths batch,eou,nemotron`,
     `--dictionary <terms.json>` (enables vocab boosting where supported),
     `--pacing realtime|max`, `--out results.json`.
   - Per clip × path it records:
     - `hyp` — transcript text.
     - **batch** → `transcribe` wall-clock latency.
     - **streaming** → run under both pacings:
       - `--pacing max` — push all chunks as fast as possible → throughput / RTFx.
       - `--pacing realtime` — push chunks at ~1× audio speed (overlapping
         "during speech" processing), then time `finish()` → transcript. This
         `post_release_ms` is the user-felt number.
     - Nemotron → `first_partial_ms` (first interim hypothesis).
   - Emits rows `{id, path, ref, hyp, latency_ms, post_release_ms, first_partial_ms,
     biasing}`; `ref` is copied straight from the manifest so the scorer needs no app
     knowledge.

2. **Fixtures (fresh, committed under `bench/`)**:
   - **General dictation corpus** — freshly authored dictation-shaped utterances
     (varied length, punctuation, numbers) for the latency/WER comparison (goals
     #1, #2). Generous count is fine; committed WAVs make the bench run with zero
     setup.
   - **Dictionary-biasing set (~15–20 clips)** — utterances seeded from the
     dictionary terms in the cleanup eval suite (e.g. Parleq, Route 53, CNAME, TTL)
     to exercise vocab boosting (goal #3).
   - **Generator** — a committed script using **macOS `say`** by default (creds-free,
     any contributor can regenerate/extend), emitting 16 kHz mono 16-bit WAV + a
     manifest pairing WAV → reference transcript.

3. **`score-wer.py` (committed)** — small `jiwer` + Whisper-normalizer (ITN) scorer
   that consumes the `results.json` rows and emits the summary table. Self-contained,
   with no external repo dependency.

## Phases

The version bump is structured as a regression gate so streaming numbers are only
trusted after the batch baseline is shown intact on the new version.

- **Phase 1 — baseline on current 0.14.5.** Build `asr-bench` with the **batch path
  only** against the currently pinned FluidAudio 0.14.5. Run the committed corpus.
  Capture the **0.14.5 batch baseline** (WER + latency). Validates that the harness
  reproduces our known-good behavior before any version change.

- **Phase 2 — bump to 0.15.3 and prove no regression.** Bump `Package.swift` /
  `Package.resolved` to **0.15.3**, fix whatever batch-API drift is required to get
  `ParleqAppCore` compiling again (record it — this *is* the upgrade-cost finding),
  re-run the **batch path**, and **diff vs. the Phase 1 baseline**.
  **Gate (concrete default, adjustable once Phase 1 numbers are in):** mean WER
  increase ≤ 0.5 absolute percentage points **and** median transcribe latency
  increase ≤ 15%, both vs. the Phase 1 baseline. Either threshold exceeded = stop
  and report before touching streaming. The bump only merges if this gate passes.

- **Phase 3 — streaming + biasing.** Only after the Phase 2 gate passes: add the
  `eou` and `nemotron` streaming paths and the dictionary-biasing fixture set. Run
  the full matrix (paths × pacings × biasing on/off) and produce the comparison.

## Deliverable

A results doc (committed alongside this design) containing:

- A table of **path × { mean/median WER, post-release latency p50/p95, first-partial
  p50, biasing WER delta (on vs off) }**.
- The Phase 2 upgrade-cost note (what API drift the 0.14.5 → 0.15.3 bump required).
- A clear **go / no-go recommendation** on adopting in-process streaming ASR.

## Key discovery the benchmark will settle

The streaming managers' published API does not mention vocabulary biasing. The
biasing arm therefore partly tests *whether streaming can accept a vocabulary at
all*. If it cannot, `on == off` and we have **quantified the dictionary-biasing
regression** — the central tradeoff for adoption.

## Risks / dependencies

- **macOS `say`** is the fixture generator (built-in, creds-free); no third-party
  TTS service or credentials are required.
- **0.15.3 batch-API drift** could require fixes to keep `ParleqAppCore` compiling.
  Captured as a Phase 2 finding; the bump merges only behind the passing gate.
- **Fair latency** depends on pacing: only `--pacing realtime` yields the user-felt
  post-release number; `--pacing max` measures throughput. Both are reported,
  labeled.
- **Bundle-exclusion** is an invariant to verify, not assume: a built `.app` must
  contain none of the `bench/` fixtures.
