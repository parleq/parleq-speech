# Intent-recovery Phase 21 — realism-enriched corrector (the data wall, breached)

**Date:** 2026-06-17
**Status:** POC spike result that **revises Phase 20**. Tests whether enriching the training data with *real* ASR-confusion patterns (mined from the user's own clips) + multi-voice acoustics closes the synthetic→real transfer gap. Artifacts local in `bench/spike/` (git-ignored — personal voice data, public terms). Single speaker, small held-out test (12 term / 12 common) — directional but decisive in direction.

## What Phase 20 left open

Phase 20 trained on pure single-voice synthetic data: 95.9% in-distribution but **42%** on real clips, because synthetic TTS confusion (`SNCC→Snyk`) ≠ real ASR confusion (`sneak→Snyk`). The open question: is the model *fundamentally* data-gated, or does *realistic* data fix it — and can real clips bootstrap a large enough realistic set?

## Method — two realism levers + a no-leakage split

Split the 74 real public clips into **real-train (50)** and **real-test (24, held out)**. Then built `data_v2.jsonl` (4,329 train rows) from three sources, using **real-train only**:

1. **Error-injection (1,269 rows) — the scalable lever.** Aligned `ref` vs ASR `hyp` on the real-train clips to **mine a real confusion table** (`snyk→sneak` 5×, `k8s→Kate's/Cate's`, `worktree→work tree`, `e2e→e to e`, …), then **injected those real mishears into a large clean text corpus** — manufacturing `(raw, ref)` pairs whose error distribution matches real audio, at arbitrary scale, no new recording.
2. **Multi-voice (3,010 rows).** TTS'd clean sentences across **7 macOS voices** → FluidAudio → real acoustic-confusion pairs with vocal diversity.
3. **Real-train mix (50 rows).** The real-train clips' own `(hyp→ref)`.

Eval on the **24 held-out real clips**, all systems scored identically.

## Results

**Main (24 held-out real clips):**

| system | recovery (12 c*) | over-fire (12 o*) | WER |
|---|---|---|---|
| raw ASR | 33% | 0 | 7.0% |
| tuned rule stack | 50% | 0 | 6.2% |
| **learned model (full)** | **75%** | 17% (2/12) | 6.6% |
| cloud LLM | 75% | 0 | 3.3% |

**Ablation — which lever drives transfer:**

| training data | recovery | over-fire | WER |
|---|---|---|---|
| **inject-only** (1,269) | 58% | **0** | **5.0%** |
| multivoice-only (3,010) | 58% | 25% (3) | 11.6% |
| full (4,329) | **75%** | 17% (2) | 6.6% |

## The finding

**Realism breaches the Phase-20 wall: real-clip recovery goes 42% → 75%, matching the LLM's recovery on this set, on-device.** And the user's hypothesis is confirmed — **a modest amount of real audio can bootstrap a large, realistic training set** via confusion-injection.

1. **Error-injection is the clean MVP.** Inject-only alone reaches **58% recovery at 0 over-fire and the best WER (5.0%)** — the scalable "mine real confusion → inject into unlimited text" recipe works *and* is precise. This is the engine: it needs only enough real clips to estimate the confusion patterns, not a huge labeled corpus.
2. **Multi-voice adds recovery but noise.** Alone it matches inject on recovery (58%) but degrades WER (11.6%, worse than raw) and over-fires 25% — acoustic diversity helps the model *see* varied errors but also teaches it to edit more loosely.
3. **Combined is best on recovery (75%)** — the two levers stack — **but at 17% over-fire**, the model's one real weakness. The rules and LLM hold 0 over-fire; the model trades 2 false insertions (`reddish→redis`, a wrong-term `Cates→CRAN` hallucination) for +25 recovery points over the rules.
4. **The honest comparison on this subset:** raw 33 → rules 50 → **model 75 = LLM 75** on recovery; the LLM still wins on WER (3.3%) and over-fire (0). So the on-device model now *matches the LLM's term recovery* but isn't yet as clean.

## What this changes (revises Phase 20's verdict)

Phase 20 said "feasible but data-gated; don't build on synthetic." Phase 21 sharpens it: **the model is more feasible than that implied — the data gate is lower than expected.** You don't need a huge labeled dataset; you need *enough real clips to estimate the user's confusion patterns*, then injection scales it. That means:

- **The correction-journal flywheel can bootstrap a *personalized* corrector even when sparsely populated** — a few dozen real corrections per user is enough to mine their confusion patterns and synthesize a large realistic training set for *them*. That's a genuinely on-device, personalized, privacy-preserving capability the cloud can't replicate.
- **The remaining work is precision, not recovery.** The model reaches LLM-level recovery; closing the over-fire gap (negative-example training, a copy-bias, or — cleanest — a **rule-stack precision post-filter**) is the path to a shippable corrector.

**The hybrid is the answer (again):** deterministic rules for class-1 + 0-over-fire precision gating, a learned corrector (trained on injection-enriched real data) for class-3 recovery. Rules give precision; the model gives recall; together they could reach toward LLM quality on-device.

## Honest bounds (important — don't over-read)

- **Single speaker; tiny test (12 c* / 12 o*).** 75% = 9/12; 50% = 6/12. Directional, not precise. The LLM scored 89% on the full 74 but 75% on this harder 24-subset, so absolute numbers are subset-specific.
- **Same-speaker confusion recurrence.** The confusion table was mined from the *same speaker's* train clips and tested on that speaker's held-out clips, where the same mishears (`sneak←Snyk`) recur. This validates the **per-user personalized** recipe; it does **not** show cross-speaker or cross-confusion generalization. A different user's mishears differ — which is exactly why the *personalized* (correction-journal) framing is the right one, not a one-size model.
- **Injection isn't 100% pure-mined** — a few sparse terms used hand-seeded fallback patterns; and some injected sentences are slightly unnatural ("sync for the bus"). Both add noise that a cleaner pipeline would remove.
- Over-fire (17%) is real and unsolved here; the model is not yet shippable as-is.

## Reproduce / artifacts

Local only (git-ignored `bench/spike/`): `data_v2.jsonl`, `confusion.json`, `real_test.jsonl`, `train_v2.py`, and `model_v2_{full,inject,multivoice}/`. Re-run with more real per-user clips (from the correction journal) to test how the curve climbs with real-data volume — and add a precision filter to attack the over-fire.
