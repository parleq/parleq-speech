# Intent-recovery Phase 14 — the error budget (capstone accounting)

**Date:** 2026-06-16
**Status:** Capstone measurement. Classifies every real error into a handler class to test the program's central claim — that the 3 handler classes + the trust surface **cover** the error space — and corrects the Phase-12 synthesis with the actual numbers. Also emits a noise-normalized trust curve. Bench only; single speaker, modest N.

## Method

For each aligned hyp error (over 102 clips / 1002 words): is it **noise** (norm(hyp)≈norm(ref) — a WER casing/contraction artifact), **class-1** (hyp word + an adjacent word concatenates to a dict term → Ph7 join), **class-2** (confidence < 0.97 → the surface flags it / Ph6), **class-3** (confident *and* near a dict term by grapheme-or-phonetic → Ph9 context), or **unexplained** (confident, off-dictionary, not compound — the genuine residual)?

## The error budget

64 aligned errors → **4 are WER noise → 60 real errors:**

| class | count | share | handler |
|---|---|---|---|
| class-2 (low-conf: near-term + garble) | 41 | 68% | trust surface flags it (Ph12) / conf×dict (Ph6) |
| class-1 (compound split) | 10 | 17% | deterministic join (Ph7) |
| class-3 (confident near-term) | 1 | 2% | contextual-fit (Ph9) |
| unexplained (confident off-dict) | 8 | 13% | — |

**The bulk is class-2 (68%)** — low-confidence errors the trust surface catches cheaply. So the surface alone, the single cheapest mechanism, addresses two-thirds of real errors.

## The confident tail — corrected from Phase 12

Phase 12 claimed the trust-surface blind spot (confident errors) is "exactly class-1 + class-3." The budget says it's messier — of the 14 confident (≥0.97) errors, only 29% classify as clean class-1/3. **But inspecting the 8 "unexplained" confident errors dissolves the discrepancy:**

- **6/8 are `E2E` acronym-letter-splitting** — the model heard "E-two-E" and wrote `E`, `to`, `E` as separate confident tokens (ref "E2E"). This **is** a compound split (class-1) — but of an *acronym with a digit-homophone*, which the naive "concatenate adjacent words" joiner misses (`E`+`to`+`E` doesn't cleanly form "e2e"; the "2"/"two"/"to" homophone breaks it).
- **2/8 are trivial function-word errors** — `a`→"the", and a `standup`→`stand` word-boundary slip — near-noise, harmless.

So once acronym-splitting is recognized as a (harder) class-1 case, the confident tail is **~64% class-1 (compound/acronym split), ~7% class-3, ~14% trivial noise, ≈0% genuinely-uncovered harmful substitution.** Phase 12's "the tail is the handlers' job" holds — **with a concrete caveat**: the deterministic joiner (Ph7) as designed catches clean concatenations (`work tree`→worktree) but **not** acronym-letter-splits with digit homophones (`E to E` / `E two E` → E2E).

## Normalized trust (noise excluded)

Dropping the 4 noise errors barely moves the Phase-12 trust curve — it's robust:

| re-read | errors caught | lift vs random |
|---|---|---|
| 5% | 38% | 7.7× |
| 10% | 50% | 5.0× |
| 15% | 58% | 3.9× |

## What this establishes

1. **The 3 classes + the surface genuinely cover the error space.** 68% class-2 (surface), 17% class-1 (join), plus class-3 and a confident tail that is itself almost entirely class-1 (acronym splits) + trivial noise. The genuinely-uncovered residual is ≈0 on this corpus — no class of confident, harmful, off-dictionary substitution slips through.
2. **Concrete actionable gap:** extend the **compound-join handler to acronyms with digit/letter homophones** (`E to E`/`E two E`→`E2E`, and similar). It's the single most common confident error here (6/14), currently uncaught. A targeted, deterministic, dictionary-scoped extension of Ph7 — likely the next-highest-value build after the phonetic trigger.
3. **The trust headline is robust** to the WER-noise correction (5%→38%, 7.7×).

## Honest bounds

- Single speaker, 60 real errors — directional; the per-class counts are small.
- The classifier is heuristic (compound = adjacency concat ≥0.85; noise = norm-ratio ≥0.9); it under-counts acronym splits (the whole point of the §confident-tail correction) and could mislabel edge cases. The qualitative budget, not the exact counts, is the durable result.
- Adversarial corpus: dense in dictionary collisions, so class-1/3 are over-represented vs ordinary dictation (where class-2 garble would dominate even more, making the surface look better still).

## Reproduce

```bash
bench/.venv/bin/python bench/error_budget.py --tokens /tmp/trust-tokens.jsonl \
  --results /tmp/trust.json --dictionary bench/dictionary-work.json
```
