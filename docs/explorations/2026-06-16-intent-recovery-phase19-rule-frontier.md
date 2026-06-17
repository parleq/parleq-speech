# Intent-recovery Phase 19 — the rule-stack frontier (the bar a learned model must beat)

**Date:** 2026-06-16
**Status:** Decision experiment. Tunes the local correction rule stack (Ph18) to its **own best operating point** — the no-regret step before training any model. Sweeps the recovery thresholds jointly over 120 configs (features precomputed once) and maps the precision/recall frontier vs the LLM ceiling. Public clips only, single speaker — directional.

## Why

Ph18 showed the local pipeline recovers terms but over-fires, at one hand-picked threshold. Before concluding "a learned model is needed," establish the **best the rules can do** — if a tuned rule point is good enough as the fast local default, no model is warranted; if it plateaus short of the product bar, the gap is the model's target.

## Method

Precompute each clip's per-word recovery features once (confidence, grapheme+phonetic proximity, context-embedding fit — the expensive part). Then sweep cheaply: `near_gate ∈ {0.6,0.7}` × `floor ∈ {0.90…1.0}` × `ctx_thresh ∈ {0.0…0.15}` × `ctx_all ∈ {F,T}` = 120 configs. Score term recovery (c* clips), over-fire (o* clips), and WER for each; extract the Pareto front.

## Results (74 public clips; 36 c* / 38 o*)

Baselines — raw: 39% recovery / 0 over-fire / 6.3% WER; **LLM: 89% / 0 / 2.1%**.

Rule-stack Pareto frontier (best WER per point):

| recovery | over-fire | WER | config (near / floor / ctx / ctx_all) |
|---|---|---|---|
| 75% | 8 | 6.4% | 0.6 / 0.90 / 0.10 / **off** |
| **72%** | **2** | **5.1%** | 0.6 / 0.90 / 0.10 / **on** |
| **69%** | **1** | **4.8%** | 0.7 / 0.90 / 0.10 / **on** |

Best rule point at each over-fire budget:

| over-fire ≤ | best recovery | WER |
|---|---|---|
| **0** | **— (unreachable)** | — |
| 1 | 69% | 4.8% |
| 2 | 72% | 5.1% |

## The finding

**Tuned, the rule stack tops out at ~70% term recovery / ≥1 over-fire / 4.8% WER — and structurally cannot reach the LLM's 89% / 0 / 2.1% corner.**

1. **Tuning is worth doing.** Moving from Ph18's hand-picked point to the swept best: over-fire **9 → 1**, WER **7.2% → 4.8%**, recovery 75% → 69% (a small, deliberate recall give-back for big precision/fluency gains). The clear winner is **context-gate every recovery** (`ctx_all=on`) with a slightly tighter proximity gate (`near=0.7`) and an aggressive confidence floor (`floor=0.90`, since context now guards precision). That's the operating point to ship if the rules ship.
2. **The plateau is real.** **No** configuration achieves 0 over-fire, and recovery caps near 70–75%. The thresholds trade recall against precision along a fixed frontier; they can't expand it. The remaining ~17–20 pts of recall and the last over-fire are **out of reach for any threshold tuning**.
3. **That plateau is the learned model's target — and partly its limit.** A learned combiner of confidence + CTC posterior + proximity + context could push *along and past* this frontier where the misses are *decidable from the available signals*. But part of the gap is the **candidate-generation limit** (Ph11): when ASR mangles a term beyond grapheme *and* phonetic reach, it's never even a recovery candidate — and a *constrained* corrector can't recover what it can't propose. Closing that piece needs open-vocabulary generation, which is what the LLM does. So a learned corrector should be expected to **narrow, not fully close**, the gap.

## The decision this gives the maintainer

- **If ~70% local term recovery (no LLM, instant) is good enough as the fast default** — escalating the unrecovered remainder to the LLM only when the user invokes it or when configured — then **ship the tuned rules; no model needed.** You get raw-beating WER (4.8% vs 6.3%) and 2/3 of terms recovered with zero per-dictation LLM cost.
- **If the product bar is ≥~85% local recovery at ~0 over-fire**, the rules can't get there and a **learned posterior-conditioned corrector is justified** — with a now-concrete target (close a ~20pt recall gap at ≤1 over-fire) and a known ceiling (the candidate-gen limit caps it below the LLM).

Either way, Ph19 converts "should we build a model?" into a product-bar question with measured numbers, not a guess.

## Honest bounds

- Single speaker, 74 short clips, adversarial (dense term collisions → over-fire pressure is high; ordinary dictation would over-fire less, flattering the rules). Re-measure on ordinary dictation before setting the bar.
- The frontier is over *these* knobs; richer hand features (e.g. per-term confidence calibration, phonetic distance learned) could shift it some without a full model.
- Recovery/over-fire are public-term substring checks; WER normalized.

## Reproduce

```bash
bench/.venv/bin/python bench/correct_frontier.py --tokens /tmp/pub-tokens.jsonl \
  --results /tmp/pub.json --llm /tmp/pub-llm.jsonl --blurbs bench/blurbs-overfire.json
```
