# Intent-recovery Phase 10 — combining the local class-3 signals, and the residual

**Date:** 2026-06-16
**Status:** Experimental result. Combines the two *local* class-3 signals — the usage-prior (Ph8) and contextual-fit (Ph9) — and measures the residual the cloud/Gemma LLM must still handle. Bench tooling only (`bench/combine_residual.py`); no app code. Single speaker, modest N — directional, not definitive.

## The question

Class 3 = the *confident near-homophone* (`Snyk`→"sneak"): acoustics are useless, so the only local evidence is (a) **usage-prior** — does this user say the term more than the colliding common word? (Ph8) — and (b) **contextual-fit** — does the sentence match the term's blurb? (Ph9). The trunk's bet was that *combining* these two cheap local signals shrinks the residual the LLM must resolve. This phase tests that bet.

We had no deployment data for the usage-prior, so per the agreed design it's a **swept parameter** λ (how many log-units this user favors their dict terms over the colliding common word), not a measured value.

## Method

Fuse the signals as **additive log-odds** (the trunk's evidence model: `P(intent|evidence) ∝ ∏ likelihoods` ⇒ log-odds add): `score = λ·usage + β·contextfit`. A symmetric **abstain band** around zero ⇒ *escalate to the LLM*. Baselines for comparison: usage-only, context-only, OR-gate, cascade. The residual at any operating point has two parts: **escalations** (punted to the LLM) and **slips** (decided locally but wrong — these escape the LLM, the bad outcome). Two summaries:

- **Forced balanced accuracy** (band 0, always decide): raw discriminative power, averaging term-recall and common-specificity so imbalance can't flatter a lazy guesser.
- **Min escalation for zero slips**: how much we must punt to make *no* local mistake — the product-relevant number.

Reuses the Ph9 per-clip rows (term, target word, acoustic confidence, contextfit cosine). Run on the 92 real-audio clips, public + (aggregate) proprietary.

## Results

Forced balanced accuracy on the **confident class-3 slice** (25 clips, 7 term / 18 common; real blurbs):

| λ (usage strength) | usage-only | context-only | **additive** | OR-gate | cascade |
|---|---|---|---|---|---|
| −1 | 0.36 | — | 0.59 | 0.55 | 0.56 |
| 0 | 0.50 | **0.63** | **0.69** | 0.57 | 0.55 |
| +1 | 0.54 | — | 0.65 | 0.54 | 0.57 |
| +3 | 0.50 | — | 0.50 | 0.50 | 0.50 |

Min escalation for **zero local slips** (lower = better), confident slice, real blurbs:

| model | escalation for 0 slips |
|---|---|
| **context-only** | **44%** |
| usage-only (best λ) | 88–100% |
| additive (best λ) | 80% |

**Flat usage** (drop the frequency term): usage-only = **0.50 at every λ** — i.e. non-discriminative. Flat-additive still peaks at **0.72** — identical to the frequency-aware additive, showing the "gain" isn't coming from the usage signal.

Weaker **public blurbs**, confident slice: context-only 0.56, additive peak 0.62 — combination barely moves a weak context signal. Pooled **public+proprietary**, all-near-term (57 clips): context-only 0.74, additive peak 0.74 — a tie.

## The finding (sharper than expected)

**The usage-prior, without real personal data, contributes essentially no discriminative power — contextual-fit is the workhorse, and "combining" is mostly just re-tuning context's decision threshold.**

Three things establish this:
1. **Flat usage-only = 0.50 at every λ.** A parametric usage-prior is a constant log-odds offset; a constant can shift the recall/specificity trade-off but cannot *separate* the two classes.
2. **Flat-additive and frequency-aware-additive peak at the same accuracy (0.72 vs 0.69).** The frequency-aware per-clip term adds nothing net. The additive "gain" over context-only (0.63→0.72) is the λ bias **sweeping context's threshold** to a better operating point — not the usage signal injecting independent evidence.
3. **Mechanistic reason** (the important part): a class-3 mishear is *itself a common word* — "sneak", "ran", "Kate's". So any **frequency-based** prior sees a common word on both the term-intended and common-intended sides and is structurally blind. Only a **true personal-usage** ratio (does *this* user say "Snyk" often?) or **sentence context** can break the tie — and only context is measurable without deployment data.

This **refines the trunk**, which framed class 3's local path as "usage-prior + contextual-fit, combined." The honest revision: **contextual-fit carries class 3 locally; the usage-prior is not an independent contributor until real per-user usage data exists** (correction journal in production). The frequency proxy is a dead end for class 3 by construction.

## The residual (the number we came for)

On the genuine class-3 target (confident slice, rich real blurbs), the best **local** operating point — context-led, abstain-and-escalate when context is weak — handles **~56% of cases error-free and escalates ~44% to the LLM**. So local context **roughly halves** the LLM's class-3 load; it does not eliminate it. (Caveat below: this rests on 6–7 term clips and is sensitive to the single worst one — directional.)

Widening to all near-term clips (mixing in class 2) pushes escalation-for-zero-slips up to ~80% — but that's the wrong denominator: classes 1–2 are already handled locally (Ph6/Ph7), so the class-3 confident slice is the right place to read the residual.

## Implications

- **Don't build a frequency-based usage-prior for class 3** expecting it to help — it can't, by construction. If the usage-prior is pursued, it must be **true per-user usage from the correction journal**, and that's a deployment-data prerequisite, not a bench experiment.
- **Contextual-fit + a good operating threshold is the class-3 local handler.** Investing in better context (phonetic-aware triggering, richer user `context` blurbs — Ph9 showed real blurbs beat terse ones) will move the residual more than any usage-prior work absent data.
- **The escalation framing is the right product model:** local handles the confident-enough cases, the LLM gets the ~44% genuinely-ambiguous remainder — exactly "cheap local by default, escalate the hard remainder."

## Honest bounds

- Single speaker; the confident slice is **6–7 term clips**. The zero-slip escalation number especially is sensitive to one clip — treat as directional.
- The usage-prior is a **swept parameter, not measured**; this phase tests "can a *data-free* usage-prior help," and the answer is no. It does **not** test a real per-user prior (which could help — untested).
- `all-MiniLM-L6-v2` proxies the on-device embedder; proprietary terms are anonymized aggregates.
- Research, not a build.

## Reproduce

```bash
bench/.venv/bin/python bench/combine_residual.py --tokens /tmp/pub-tokens.jsonl \
  --results /tmp/pub.json --blurbs bench/dictionary-work.json            # confident slice, real blurbs
bench/.venv/bin/python bench/combine_residual.py --tokens /tmp/pub-tokens.jsonl \
  --results /tmp/pub.json --blurbs bench/dictionary-work.json --no-freq-aware   # flat usage (non-discriminative)
```
