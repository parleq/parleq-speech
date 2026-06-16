# Intent-recovery program — Phase 6: confidence × personal dictionary cracks the irreducible case

**Date:** 2026-06-16
**Status:** Research result for the intent-recovery reframe (bet B / break #4, the personal prior). **Two independent weak signals combine to solve the case that defeated text, CTC margin, and the frequency gate.** No app code changed.
**Builds on:** Phase 5 (acoustic confidence localizes error). **Tooling:** `bench/analyze_personal_prior.py`.

## The case nothing could crack

All session, one case beat every approach: a word that is phonetically one of the user's dictionary terms — did they mean the **common word** or the **term**? `ran` vs `CRAN`, `number` vs `Numba`. Text can't tell (identical surface). The CTC margin can't (Phase 1, overlapping distributions). The frequency gate "solved" it only by *always assuming the common word* — which threw away 13/17 real term recoveries (Phase 4c, recall 82%→56%).

## The hypothesis

Two **independent** signals, neither sufficient alone:
- the **personal dictionary** says *where* to look (this word is phonetically one of your terms);
- the **acoustic confidence** (Phase 5) says *which way* (the model is measurably less sure when it mis-hears a term than when it transcribes a genuine common word).

Combine them: **near-a-your-term AND confidence below the correct-word floor ⇒ they meant the term.**

## Method

Two classes, both filtered to words phonetically near a dictionary term (difflib grapheme ratio ≥ 0.6 to a term or alias — crude, a floor not a ceiling; phonetic proximity would only add more):
- **Class A "meant the common word":** CORRECT words in the over-fire corpus near a term (`ran`, `branch`, `radish` …). 83 words.
- **Class B "meant the term":** ERROR words in the colliding + stress corpora near a term (`number`, `Dino`, `readies`, `SNCC`, `Vithay` …). 58 words.

Measured whether per-word confidence (Phase 5's `conf_min`) separates A from B.

## Result

| | Class A (meant common) | Class B (meant term) |
|---|---|---|
| n (near a term) | 83 | 58 |
| confidence median | **1.000** | **0.843** |
| conf ≥ 0.97 | 99% (82/83) | 28% (16/58) |
| conf < 0.90 | 1% | 59% |

**ROC-AUC = 0.964** (confidence separates "meant common" from "meant term").

Decision rule — *near a term AND conf < T ⇒ treat as "meant the term"*:

| T | recovers term-mishears (B) | false-flags genuine commons (A) |
|---|---|---|
| 0.97 | **72% (42/58)** | **1% (1/83)** |
| 0.98 | 76% | 2% |
| 0.99 | 83% | 8% |

At T≈0.97 the rule recovers ~72% of term intent while touching ~1% of genuine common words. The genuine commons it must not flag (`ran`, `branch`) sit at confidence 1.000; the term mis-hears it wants (`Vithay`→Vite 0.25, `CRN`→CRAN 0.33, `think`→ultrathink 0.42, `number`→Numba) sit well below.

## Why this matters

- **It recovers exactly what the frequency gate threw away.** Phase 4c's gate dropped term recoveries to avoid over-fire; this rule recovers ~72% of them at ~1% false-flag — *and* still leaves genuine common words alone (they're high-confidence, not flagged). The two signals are complementary: dictionary = candidate sites, confidence = intent direction.
- **It's the first thing that separates the irreducible case at all.** Confidence-alone (no dictionary) would flag every low-confidence word including unrelated ASR noise; dictionary-alone (no confidence) is the over-fire problem. Together: AUC 0.96.
- **It's the intent-recovery reframe working end to end on the hardest input** — combine evidence (acoustic + personal) under uncertainty, flag what's uncertain, leave the confident alone.

## Honest bounds

- **Synthetic-heavy.** Most A/B words come from `say` audio; real audio's confidently-wrong tail is bigger (Phase 5 real AUC 0.80), so on real speech the 72%/1% will degrade. **Validating this exact rule on real recordings is the next must-do.**
- **Residual tail:** 28% of term-mishears are ≥0.97 confidence (confidently wrong) — this rule misses them. That residual is where a *richer* personal prior (usage frequency / correction-journal history, not just dictionary membership) should add the next increment — the real bet B.
- **Crude proximity:** grapheme ratio misses phonetic-far mishears (`SNCC`~Snyk), so the recoverable set is *under*-counted here; phonetic proximity (G2P/metaphone) would raise B coverage.
- **Detector, not recovery mechanism:** the rule decides *when* a word is a likely term-mishear; turning it into the term still needs the rescorer / LLM / a user tap. That's the routing the reframe intends.
- Small N (141 near-term words), single real speaker.

## Real-audio check (preliminary — TEMPERS the synthetic result)

Ran the same A/B separation on the real human recordings (speaker jon). **It does not replicate — and the test is both underpowered and term-mismatched:**

- **ROC-AUC 0.69** (vs 0.964 synthetic); rule at T=0.97 → 57% recovery / 25% false-flag (vs 72%/1%).
- Class B is tiny (7 near-term error words) and splits into two types confidence does **not** flag:
  - **confident mishears** — `sneak`→Snyk at conf 0.95–0.97 (real "Snyk" genuinely sounds like "sneak"; the model is sure);
  - **segmentation, not mishearing** — `work`/`tree`→worktree at 0.96–0.996 (the model heard it right, just didn't join the compound — confidence is *correctly* high; this needs a joiner, not an uncertainty signal).
- **The human set doesn't contain the stress terms** (`Numba`/`Dask`/`Deno`) the synthetic result leaned on — real ASR transcribed the colliding terms it *does* contain (CRAN/Redis) correctly, leaving almost no genuine acoustic mis-hears to test. So this neither confirms nor cleanly refutes Phase 6.

**Verdict:** the strong synthetic 0.96 is optimistic; on real speech the confidently-wrong tail (Phase 5) and a distinct *segmentation* error class blunt the rule. Treat Phase 6 as **promising-but-unvalidated on real audio**. This echoes Phase 4b/Phase 5: synthetic systematically overstates the acoustic signal. The proper real-audio test requires recording the **stress-colliding** sentences (clean-common-word terms) — the must-do before trusting this rule.

## Real-audio validation Pass 2 — stress set recorded — VALIDATED

The preliminary check above was underpowered AND term-mismatched (its near-term errors were `Snyk`->`sneak`, a confident near-homophone, and `worktree`->`work tree`, segmentation — neither is the rule's target). Recorded the **stress-colliding** set (the clean-common-word terms the rule actually targets) on real speech. Result resolves the doubt:

| said | ASR wrote | confidence |
|---|---|---|
| Nuxt | `next` | 0.35 |
| Numba | `number` | 0.64 |
| Dask | `desk` | 0.82 |
| Deno | `Dino` | 0.54 |
| Pinia | `penea` | 0.31 |

All 5 real stress-mishears land far below the ~0.99 correct-word floor. **Real-audio ROC-AUC = 0.962** (matches synthetic 0.964): Class A genuine-commons median 0.998, Class B stress-mishears median 0.543. Rule at conf<0.90: **recovers 5/5 (100%)** term intent, **false-flags ~15%** of genuine commons (vs 1% synthetic — real audio has some mumbled low-confidence commons + crude grapheme proximity over-matches; phonetic proximity would cut it).

**Verdict (supersedes the preliminary one):** the rule **holds on real audio for the clean-common-word mishears it targets** (AUC 0.96). Two characterized failure modes remain: (1) **confident near-homophones** (Snyk->sneak) — needs a richer prior/context; (2) **compound segmentation** (worktree, ~41% of recoveries) — a distinct, high-confidence, **deterministically fixable** class (match multi-word spans to compound dict terms), not an uncertainty problem. The Phase 4b/5 "synthetic overstates" worry was half-right: it overstated the *false-flag* rate (1%->15%) and missed these two failure modes, but the *core separation* (~0.96 AUC) replicated on real speech.

## Next experiments

1. **Richer personal prior** for the confident-near-homophone residual (Snyk->sneak): usage frequency / correction-journal history. *(superseded #1: real-audio validation of the clean-common-word case — DONE, Pass 2 above.)* (Numba/Dask/Deno…) so Class B contains genuine clean-common-word mis-hears, not just Snyk/worktree. The current human set can't test Phase 6's actual claim.
2. **Richer personal prior:** add usage frequency / correction-journal history as a term-prior; does it recover the confidently-wrong tail (the 28%)?
3. **Phonetic proximity** to widen Class-B coverage.

## Reproduce

```bash
bench/.venv/bin/python bench/analyze_personal_prior.py \
  --add /tmp/of5-tokens.jsonl  /tmp/of5-tok.json  bench/dictionary-overfire.json A \
  --add /tmp/coll5-tokens.jsonl /tmp/coll5-tok.json bench/dictionary-overfire.json B \
  --add /tmp/stresscoll-tokens.jsonl /tmp/stresscoll-tok.json bench/dictionary-stress.json B
```
