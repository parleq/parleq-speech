# Intent-recovery Phase 12 — the trust metric (proofreading effort vs safety)

**Date:** 2026-06-16
**Status:** Experimental result + the program's product thesis (#2), measured for the first time. Bench tooling only (`bench/trust_metric.py`); no app code. Single speaker, modest N — directional.

## The question

WER tells you *how wrong* a transcript is; it does **not** tell you the thing a dictation user actually cares about: **how much of this must I re-read before I trust it?** The intent-recovery program's most original *product* idea (#2) is to make uncertainty a first-class output — flag the words the engine is unsure of, so the user proofreads only those. Because acoustic confidence is calibrated (Ph5, AUC ~0.80 real), this should work. This phase measures it.

Two quantities, swept over a confidence threshold T (flag words with conf < T):
- **Effort** = fraction of words flagged (what you must double-check).
- **Caught** = fraction of *actual errors* that are flagged (safety).
- **Slips** = errors not flagged (pasted unknowingly — the bad outcome).

Pooled over **102 real-audio clips / 1002 words / 64 errors** (6.4% word error rate).

## Results

**Trust curve:**

| flag conf < T | effort (re-read) | errors caught | slips |
|---|---|---|---|
| 0.80 | 11% | 50% | 32 |
| 0.95 | 24% | 69% | 20 |
| 0.99 | 37% | 86% | 9 |
| 0.995 | 47% | 98% | 1 |
| 0.999 | 66% | 100% | 0 |

**Effort to hit a safety target:** catch 50% of errors → re-read **9%**; 80% → 31%; 90% → 42%; **100% → 50%**.

**Calibration lift over random flagging:**

| re-read budget | errors caught | lift vs random |
|---|---|---|
| 5% | 38% | **7.5×** |
| 10% | 50% | 5.0× |
| 15% | 58% | 3.9× |
| 20% | 62% | 3.1× |

## The finding

**1. The uncertainty surface works, and the value is concentrated at the cheap end.** Re-reading just the **5%** lowest-confidence words catches **38%** of all errors — **7.5× better than re-reading 5% at random**; 10% catches half. So a glance-able "check these few words" surface is genuinely high-value, and it's a far more actionable product number than "6.4% WER."

**2. But there's a long tail: catching *every* error costs ~50% re-read.** The last errors are **confident** errors — confidence can't flag them, so the curve flattens. Inspecting the conf ≥ 0.97 errors (the tail) shows *what* they are:

- `tree`, `work` (from "worktree"), `E`, `to` (from "E2E") — **class-1 compound splits**: the model heard it right, split it, and is confident.
- `sink` (from `Snyk`→"sync"/"sink") — **class-3 confident near-homophone**.
- a few alignment/formatting artifacts (`a`, `Dinner`, casing) — WER-style scoring noise, not real errors.

**3. The closure (why this is the capstone).** The errors the trust surface *cannot* cheaply flag are **exactly the errors the recovery handlers target.** Every error is either:
- **low-confidence** (garble, class-2 mishear) → the **trust surface flags it** for the user, cheaply; or
- **high-confidence** (class-1 compound split, class-3 near-homophone) → confidence is blind, but a **handler fixes it automatically** (Ph7 deterministic join; Ph9 contextual-fit), because those classes are defined precisely by being confident-yet-wrong.

So the surface and the recovery handlers are **complementary and jointly cover the error space**: confidence handles the unsure errors; the handlers handle the confident ones. The trust curve's long tail *is* the recovery handlers' job — that's why the program needs both.

## Product implication

- **Ship the low-confidence flag surface.** Marking the cheapest ~5–15% of words turns "re-read everything" into "glance at these," catching 38–58% of errors at 3.9–7.5× over chance. This is the differentiated product surface the program set out to find.
- **Pair it with the class-1/class-3 recovery handlers**, which mop up the confident errors the surface can't flag. Reported together, the user story is: *the obvious mistakes are flagged for you; the sneaky confident ones are auto-corrected.*
- **Report trust numbers, not WER**, in any eval: "re-read X% → catch Y%." It's the metric that maps to user effort.

## Honest bounds

- Single speaker; 64 errors total — directional. This is an **adversarial** corpus (dense near-homophones), so its *confident*-error fraction (the long tail) is inflated vs ordinary dictation; on normal speech the trust surface would look **even better** (fewer confident errors, more low-confidence garble it flags cheaply).
- The metric inherits WER's alignment/normalization noise — a few "errors" are casing/contraction artifacts, not real mistakes. A normalized (ITN/casing-folded) variant would tighten the numbers.
- Confidence calibration is the single-speaker Ph5 result; per-speaker recalibration may be needed.

## Reproduce

```bash
# pool tokens+results across the human/contextfit/stress sets, then:
bench/.venv/bin/python bench/trust_metric.py --tokens /tmp/trust-tokens.jsonl --results /tmp/trust.json
```
