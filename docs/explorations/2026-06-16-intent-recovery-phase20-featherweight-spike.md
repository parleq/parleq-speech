# Intent-recovery Phase 20 — featherweight corrector spike (the model is easy; the data is the wall)

**Date:** 2026-06-16
**Status:** POC spike result. Trains a small dictionary-aware ASR error-correction model and tests whether it can clear the rule frontier (Ph19) on the **real** clips. Answers "how hard is the featherweight model, and what does training look like?" with evidence. Throwaway scripts + data + model are local in `bench/spike/` (git-ignored — synthetic data, public terms). Single TTS voice, one model/recipe — directional.

## Setup

- **Data:** 1114 synthetic rows. Generated dev sentences embedding 18 "seen" public terms + 5 held-out terms (+ homophone-collision distractor sentences with no term), spoke them via macOS `say`, ran them through **FluidAudio** to capture *real ASR errors*, paired `(raw → ref)`. ASR mis-rendered the target term **45%** of the time — a rich correction signal.
- **Model:** `flan-t5-small` (~80M), fine-tuned 12 epochs (~57s on MPS). Input = `"correct the transcript using this vocabulary: <terms>. transcript: <raw>"` → target = `ref`. Dictionary-conditioned via the prompt.
- **Eval:** (1) synthetic held-out split (seen vs held-out terms); (2) **the 74 real human clips** scored against the same baselines as Ph16/19.

## Results

**Real clips (the decisive test):**

| system | term recovery | over-fire | WER |
|---|---|---|---|
| raw ASR | 39% | 0 | 6.3% |
| tuned rule stack (Ph19) | ~70% | 1 | 4.8% |
| **learned model** | **42%** | **0** | **6.2%** |
| cloud LLM | 89% | 0 | 2.1% |

**Synthetic test split:**

| condition | recovery | over-fire | WER |
|---|---|---|---|
| model, **seen** terms | **95.9%** | low | **1.1%** |
| raw, seen terms | 50% | — | 6.9% |
| model, **held-out** terms | 45.5% | higher | 7.8% |
| raw, held-out terms | 57.3% | — | 7.5% |

## The finding

**The featherweight model is *capable* and *easy to train* — but it is hard **data-gated**, and synthetic data does not clear the gate.**

1. **The architecture works.** In-distribution the model hits **95.9% recovery / 1.1% WER / 0 over-fire** in under a minute of training. A small model *can* learn dictionary-aware correction. The model is not the hard part.
2. **It does not transfer to real audio.** On the real clips it scores **42%** — barely above raw (39%), far below the rule stack (~70%). It **memorized the synthetic confusion patterns** (how `say`+FluidAudio mangles a term, e.g. `SNCC→Snyk`, `K-8S→k8s`) and never learned the *real* ones (`sneak→Snyk`, `Kate's→k8s`). It even missed `work tree→worktree`, which the deterministic rule nails. Synthetic ASR confusion ≠ real ASR confusion — the program's recurring lesson, in its sharpest form yet.
3. **Held-out dictionary generalization is poor** (45.5% < raw 57.3%): the model over-applies its seen-term patterns to terms it never produced in training, sometimes *reducing* recovery.
4. **Over-fire is clean (0).** The one transferable win — it learned to be conservative, not to hallucinate. (Likely because the no-fire guard sentences *do* transfer: ordinary words are ordinary in any voice.)

## What this means for the strategy (it converges)

The two most valuable local upgrades — a **true usage-prior** (Ph10) and a **learned corrector** (Ph20) — are **gated on the same thing: real `(raw → corrected)` data from production.** Synthetic can't substitute (Ph20 proves it), and the usage-prior needs real per-user ratios (Ph10). So the **critical-path enabler is the data flywheel that already half-exists**: `CorrectionJournal` + `LearningAnalyzer` + `LearnedStore` capture real corrections, and the cleanup LLM can label `(raw → clean)` pairs (distillation). Ship that loop, accumulate real pairs, *then* the featherweight model becomes trainable on data that actually transfers.

A second design correction falls out: **the model should not replace the rules wholesale.** The deterministic compound/acronym join (Ph7/15) is *perfect* on class-1 splits and the spike model was *worse* there. The right architecture is **rules for the deterministic classes + a learned model only for the hard class-3 residual**, trained on real data — not one monolithic corrector.

## So: how hard, and what does training look like? (answered)

- **Training mechanics: easy.** flan-t5-small, ~80M, dictionary-conditioned prompt, minutes to train on MPS, runs locally. The recipe in this doc works as-is.
- **The hard 80%: data realism + dictionary generalization.** A model trained on synthetic confusion is useless on real audio. You need real raw→corrected pairs (the correction-journal/distillation flywheel), and a conditioning design that generalizes to unseen user terms (the held-out result shows that's not free).
- **Verdict:** feasible and architecturally proven, but **do not build it now** — build the **data flywheel** first (which also pays off the usage-prior and the dictionary auto-build), then re-run this exact spike on real pairs. Until then, **ship the tuned rules** (Ph19) as the fast local path.

## Honest bounds

- Single TTS voice, one model (flan-t5-small), one recipe, 1114 synthetic rows. A richer synthetic recipe (multiple voices, audio augmentation, mixing in the real clips) would likely transfer *better* — this spike establishes that *pure single-voice synthetic* fails, not that all synthetic is hopeless.
- The real-clip eval is 74 single-speaker clips; recovery/over-fire are public-term substring checks; WER normalized.
- The held-out-term result depends on the conditioning format; a retrieval-style or copy-biased design might generalize better — untested.

## Reproduce / artifacts

Local only (git-ignored `bench/spike/`): `data.jsonl` (1114 rows), `model/` (flan-t5-small checkpoint), and the data-gen / train / eval scripts. Re-run on real correction-journal pairs once available — that is the experiment that decides whether to productionize.
