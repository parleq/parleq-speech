# Intent-recovery Phase 15 — acronym-aware compound join (closing the Ph14 gap)

**Date:** 2026-06-16
**Status:** Short build + result. Extends the Phase-7 deterministic compound-join handler to the acronym-split case the Phase-14 error budget flagged as the single most common *confident* error (`E2E` written as "E to E", 6/14). Bench only; single speaker.

## The gap

Ph7's joiner derives a term's spoken form by camelCase + letter↔digit split. For `E2E` that yields **"e 2 e"** (literal digit) — but the ASR writes the digit as a *homophone word*: **"E to E"**. So the literal-digit form never matches and E2E stays split. Same for `k8s` ("k eight s").

## The fix

Add `acronym_forms()`: for any digit-bearing term, enumerate char-by-char spoken forms with the **digit's homophones** —
`E2E → {"e two e", "e to e", "e too e"}`, `k8s → {"k eight s", "k ate s"}` — and OR them into the term's spoken forms. Additive: non-digit terms (worktree, ultrathink) are unchanged.

```
DIGIT_WORDS = {"2": ["two","to","too"], "8": ["eight","ate"], "0": ["zero","oh"], ...}
```

## Result (human + contextfit clips)

- **`E2E` is now recovered** by the deterministic join ("E to E" → E2E) — the 6 confident split-errors from the Ph14 budget. Compound-term recall on this set rises **8% → 42%** (the join now fires on E2E in addition to worktree).
- **0 false-joins** — the homophone forms ("e to e", "k eight s") are specific enough not to appear spuriously in ordinary dictation.
- It correctly does **not** recover the `k8s`→"Kate's"/"Cates"/"cate's" clips — those are **class-3 mishears** (the model heard a real word), not splits. They're outside the deterministic joiner's scope by design and belong to the contextual-fit / phonetic handler.

## Why this matters

1. **Closes the biggest confident-error class** from Ph14 deterministically, locally, with zero false-joins and zero acoustics — the same robust, dictionary-scoped profile as the original Ph7 join.
2. **Confirms the class boundary is clean.** The acronym join takes the *splits* (`E to E`); the *mishears* (`Kate's`) fall through to class-3 — exactly the taxonomy the program is built on. A handler that tried to grab both would over-fire; this one doesn't.
3. Combined with Ph11 (phonetic trigger) and Ph14 (budget), the deterministic/local layer now covers class-1 splits **including acronyms**, leaving the context/LLM escalation only the genuine class-3 near-homophones.

## Honest bounds

- Single speaker; the recall number is on a small compound-term subset. The win (E2E recovers, 0 false-joins) is the durable part.
- The digit-homophone table is hand-built; rare digits/locales may need extension. False-join safety should be re-checked on a larger ordinary-dictation corpus before production.
- No unit test added (compound_join.py is a measurement script with none); behavior verified by the run.

## Reproduce

```bash
bench/.venv/bin/python bench/compound_join.py \
  --add /tmp/human.json bench/fixtures/manifest-human.json \
  --add /tmp/contextfit.json bench/fixtures/manifest-contextfit-human.json
```
