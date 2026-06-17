# Featherweight Corrector — A+B De-risking Spike: Results & Go/No-Go

**Date:** 2026-06-18
**Status:** Spike complete. Research result — productionization remains a separate, maintainer-gated effort.
**Implements:** `2026-06-17-featherweight-corrector-spike-design.md` / `-plan.md`. Item 3 of the intent-recovery program (#100).

## TL;DR

A **strong public-data base + dev-jargon injection** reaches **72% term recovery at 3% over-fire / 4.3% WER** on 5-fold CV over the 74 real clips — clearing the success bar (recall ≥ ~65–70%, over-fire ≤ ~5%) and beating the inject-only spike (58%). On-device **serving is feasible with wide margin** (flan-t5-small → CoreML at 187 MB / ~128 ms; a decoder-only alternative on MLX at 91 ms / 276 MB). **All three greenlight legs are met → the recipe clears the gate to productionization.**

Two findings reshape the design:
1. **The precision post-filter is *not needed* with a strong base** — base+inject is intrinsically precise (3% over-fire vs the *weak* model's 17%). The filter as-tuned *cost* recall (72%→56%) and removed 0 real over-fires. Keep `precision_filter.py` as optional tooling; do not put it on the default path.
2. **LibriSpeech→FluidAudio pairs don't help** — they're dominated by casing/convention noise (mr/mrs/grey/honor, function-word swaps), not dictionary-recovery signal. The text base (HyPoradise + Robust-HyPoradise) suffices.

The honest caveat: at current data scale the learned model **ties the free rule stack on recall (72%)**, winning on precision (3% vs 8% over-fire) and WER (4.3% vs 5.1%). Its real upside is (a) a better precision/WER point today and (b) a flywheel-driven improvement trajectory the static rules can't match.

---

## Phase A — recipe validation

### Method
- **Strong base:** flan-t5-small fine-tuned on **145,494** public ASR-correction pairs — HyPoradise v0 (110,991; MIT; TED-LIUM/`td3` subset excluded by license) + Robust-HyPoradise (34,503; Apache; clean `input[0]`/`ground_truth` text extracted from the `.pt` files, tensors dropped). 2 epochs, MPS, dev-loss 0.74.
- **Injection layer (per fold):** confusion mined from the *training-fold* real clips only (no leakage), injected into cased dev-term template sentences + the train-fold real clips, fine-tuned on top of the base.
- **Precision filter:** `bench/precision_filter.py` (committed) — vetoes a model dict-term insertion unless dictionary-grounded (grapheme ≥ 0.7 OR phonetic ≥ 0.90 on the raw word) AND supported (class-2 low-confidence / class-3 context-fit / near-exact phonetic). Self-test passes on the named over-fires.
- **Eval:** 5-fold CV over all 74 real clips (36 c* term-intended / 38 o* common-intended), scored on recovery / over-fire / WER. Base, rule-stack, raw, LLM are fold-independent; base+inject is mined+trained per fold.

### CV ablation matrix (5-fold, 74 clips)

| System | Recovery | Over-fire | WER |
|---|---|---|---|
| raw ASR | 39% (14/36) | 3% (1/38) | 6.3% |
| rule-stack (Ph19) | 72% (26/36) | 8% (3/38) | 5.1% |
| base alone | 25% | 13% | 56.9% ⚠️ |
| **base+inject** | **72% (26/36)** | **3% (1/38)** | **4.3%** |
| base+inject+filter | 56% (20/36) | 3% (1/38) | 5.5% |
| LLM (ceiling) | 89% (32/36) | 3% (1/38) | 2.1% |

Per-fold base+inject+filter recovery: 29–86% (small folds → wide variance; the 72% aggregate for base+inject is the trustworthy figure).

### Findings
- **The strong base lifts recall: 58% (inject-only spike) → 72% (base+inject).** Its error-correction priors transfer once the inject layer aligns the output style.
- **The precision filter is net-negative with the strong base.** It dropped recovery 72%→56% (vetoed 6 correct recoveries) and removed **0** of the 1 over-fire. The strong base+inject already delivers the precision the spike worried about. → *Filter not on the default path; retained as optional tooling.*
- **`base alone` is unusable (25% recall, 56.9% WER):** trained with an *empty* vocabulary slot, it goes out-of-distribution when given the populated 8-term vocab at inference and degenerates (repetition loops, echoing the vocab list). **Recipe fix for productionization:** train the base *with* the populated vocabulary so train/inference input distributions match — likely fixes base-alone and may lift base+inject further.
- **vs the rule stack:** equal recall (72%), but base+inject has lower over-fire (3% vs 8%) and lower WER (4.3% vs 5.1%).

### LibriSpeech→FluidAudio (A.2) — diagnostic, not folded in
Ran the committed `asr-bench` (FluidAudio Parakeet TDT v3, pinned 0.14.5, no vocab) over 15,000 LibriSpeech `train-clean-100` utterances. **Not used as base training data:** LibriSpeech references are UPPERCASE/unpunctuated, so raw `hyp→ref` pairs are 60% pure casing/punctuation noise; the remaining 40% real-content errors are off-domain conventions — `mister→mr`, `missus→mrs`, `gray→grey`, `honour→honor`, `toward(s)`, and function-word swaps (`the/a`, `in/and`). None is dictionary-recovery signal, and folding it in would risk teaching *harmful over-corrections*. Diagnostic value: confirms FluidAudio's read-speech error rate is benign/conventional (reassuring about base ASR quality). HyPoradise's `train_other_500` already carries LibriSpeech-style errors.

### Cross-speaker (A.8)
No second speaker was reachable within the spike → **single-speaker remains the standing bound.** The opt-in flywheel corpus (now collecting on the maintainer's machine) is the path to both more same-speaker in-the-wild data and, once multi-contributor, the first real cross-speaker signal.

---

## Phase B — on-device serving feasibility

| Candidate | Backend | Size | Load | Latency (median) | Peak mem |
|---|---|---|---|---|---|
| flan-t5-small (recipe model) | **CoreML** (ANE/GPU) | **187 MB** | — | **~128 ms** @20 tok* | — |
| flan-t5-small | PyTorch/MPS | 311 MB | ~0.3 s | 214 ms greedy / 296 ms beam-4 | ~1.2 GB |
| Qwen2.5-0.5B (decoder-only) | **MLX** (Metal) | **276 MB** | 0.38 s | **66 ms TTFT / 91 ms total** | **373 MB** |
| flan-t5 via MLX | — | — | — | unsupported (mlx-lm is decoder-only) | — |

\* CoreML estimate is an upper bound (no KV-cache across decoder steps; real would be faster). Targets: ≤ ~139 ms Gemma-tier TTFT, ≪ 4 GB.

**Both servable architectures clear both targets by a wide margin.** The design's central serving unknown — "can a small seq2seq run on-device?" — resolves **yes**: flan-t5-small → CoreML converts cleanly (encoder + decoder-step packages) at 187 MB / ~128 ms.

- **T5 + CoreML** preserves the recipe-validated model exactly (the 72% recall is *this* architecture).
- **Decoder-only + MLX** is faster/smaller (91 ms, 276 MB) and reuses the app's existing mlx-swift Gemma infra — but only *latency* was measured; a decoder-only model's *correction recall* is unvalidated and would need a recall re-check before commitment.

Measurement note: serving was measured in Python (coremltools `predict` runs through Core ML on ANE/GPU; mlx-lm runs the same Metal kernels as mlx-swift), not a Swift micro-harness. Production numbers via the Swift/MLX path (already proven for Gemma at ~139 ms TTFT) are a follow-up.

---

## Success bar — verdict

| Leg | Bar | Result | |
|---|---|---|---|
| Recall | ≥ ~65–70% | **72%** (base+inject) | ✅ |
| Precision | over-fire ≤ ~5% | **3%** (base+inject, *no filter*) | ✅ |
| Serving | feasible on-device | **CoreML 187 MB/~128 ms; MLX 91 ms/276 MB** | ✅ |

**All three legs met → the recipe clears the gate to proceed to productionization (Phases C/D).**

### Recommendation
1. **Proceed**, but scoped by the honest caveat: at today's data scale the learned model's recall *ties* the free rule stack (72%); its edge is precision (3% vs 8% over-fire), WER (4.3% vs 5.1%), and a flywheel-driven improvement trajectory the static rules lack. If the maintainer weights "minimal shipped complexity now" over "improvement trajectory," shipping the **rule stack + trust surface (item 2)** as the local tier remains a fully valid alternative.
2. **Production model architecture:** lead with **flan-t5-small → CoreML** (recipe-validated, 187 MB / ~128 ms). Keep **decoder-only → MLX** as the strong alternative (faster, smaller, reuses infra) *pending a recall re-validation*.
3. **Drop the precision filter from the default path** — the strong base+inject is intrinsically precise. Retain `precision_filter.py` as optional tooling / safety valve.
4. **Recipe fix before productionization:** train the base *with* the populated vocabulary (not empty) to eliminate base-alone degeneracy and possibly lift base+inject.
5. **The per-user LoRA personalization tier (Phase C)** stays gated on the correction-journal flywheel accumulating real per-user data — unchanged.

---

## Honest bounds
- **Single speaker.** k-fold CV mitigates the single 50/24 draw, but all 74 clips are one speaker. Cross-speaker generalization is unproven (the program's biggest open claim); the flywheel is the path to it.
- **Small folds.** 74 clips / 5 folds ≈ 15 clips/fold → wide per-fold spread (29–86%). The aggregate is the trustworthy figure.
- **Recipe model ≠ committed production model.** flan-t5-small validated the *recipe*; the production architecture is chosen from Phase B (T5-CoreML vs decoder-only-MLX), the latter needing recall re-validation.
- **Serving measured in Python** (real Core ML / Metal execution, but not the Swift app path).
- This is research; productionization is separate and maintainer-gated.

## Reproduction (committed tooling + git-ignored spike artifacts under `bench/spike/`)
- `bench/precision_filter.py` (committed) — `--selftest`.
- `bench/spike/fetch_datasets.py` → `build_base.py` → `train_base.py` → `eval_cv.py` (Phase A).
- `bench/spike/transcribe_librispeech.py` (A.2 diagnostic, reuses `asr-bench`).
- `bench/spike/serving/{export_t5_coreml.py,probe_t5.py,probe_mlx.py}` (Phase B).
