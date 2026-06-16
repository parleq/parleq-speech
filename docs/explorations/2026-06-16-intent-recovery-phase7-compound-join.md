# Intent-recovery program — Phase 7: the compound-join handler (the easy class, deterministically)

**Date:** 2026-06-16
**Status:** Research result for error-class 1 of the intent-recovery taxonomy (compound segmentation). **A pure-text, deterministic, acoustics-free handler recovers ~half of compound-term occurrences at zero false-join cost — and it holds on real audio.** No app code changed. Tooling: `bench/compound_join.py`.

## The class

Phase 6's real-audio work surfaced that term recoveries split into kinds. ~41% are **compound splits**: the user says a compound term, the ASR hears it correctly but writes it as separate words — `worktree`→"work tree", `FluidAudio`→"fluid audio", `ultrathink`→"ultra think". The model is *high-confidence* (it heard right); this is a **missing join**, not a mishear. So it needs no acoustic/uncertainty machinery — just match the spoken multi-word form against the transcript and join to the canonical term.

## Method

Spoken forms derived by: **camelCase split** (`FluidAudio`→"fluid audio"), **letter↔digit boundary split** (`Route 53`→"route 53"), and **explicit aliases** for all-lowercase compounds a blind splitter would mangle (`worktree`→"work tree"; a greedy word-split would also wrongly produce `redis`→"red is", so we do NOT blind-split). Production derives these from camelCase + user/learned aliases. Then: scan each raw ASR hyp for a spoken form (consecutive words, case-insensitive) → it would join to the canonical term. Measured recall (compound-term clips) and false-joins (the spoken form appearing where the term wasn't intended), across **all corpora including the real human recordings**.

## Result

Compound terms + spoken forms tested: `worktree`←"work tree", `FluidAudio`←"fluid audio", `ultrathink`←"ultra think", `Route 53`←"route 53", `E2E`←"e 2 e", `k8s`←"k 8 s".

**Recall — 57 compound-term occurrences:**
- already correct (no join needed): 23 (40%)
- **recovered by deterministic join: 25 (44%)**
- unrecoverable (genuine mishear, not a clean split): 9 (16%)
- **→ compound recall 40% → 84%**, purely deterministically.

**False-joins: 0** across every corpus (incl. over-fire, where many genuine consecutive words appear). The spoken forms are distinctive enough never to fire by accident — and the join is inherently **scoped to the user's own dictionary terms** (it only ever fires toward a term the user has), which is the structural safety.

The 16% unrecoverable are genuine mis-hears that are *not* clean splits and correctly fall through to the other handlers: `Kate's`/`Kates`→k8s, `ultra thing`→ultrathink (thing≠think), `root 53`→Route 53 (root≠route). Note `k8s`/`E2E` are abbreviation-style: ASR renders them phonetically (`Kates`), never as "k 8 s", so the join can't help them — they're mishears, not compounds.

## Why this matters

- **It peels the easy class off cleanly.** ~half of compound recoveries (and ~41% of *all* term recoveries per Phase 6's taxonomy) are handled by a few lines of deterministic text-matching — no model, no acoustics, no uncertainty, no over-fire risk. The expensive confidence+personal-prior machinery (Phases 5/6) then only has to handle the genuinely hard mishears.
- **It's robust where Phase 6 is fragile.** Because it uses no acoustic signal, the synthetic-vs-real gap doesn't apply — it recovered the real human `work tree`→worktree cases just as well as synthetic. This is the most "shippable-feeling" piece of the whole program.
- **It's a featherweight building block.** A 100%-local cleanup engine gets this entire class for free, on any hardware.

## Limits / honest notes

- **Needs spoken forms.** camelCase auto-split handles `FluidAudio`-style; all-lowercase compounds (`worktree`, `ultrathink`) need an alias or a learned spoken form. That's a small, reasonable requirement (and a natural thing for the correction-journal loop, #4, to learn).
- **0 false-joins is on our (domain-limited) corpora.** Genuine separate uses of a spoken form (e.g. "work tree" meaning something else) are possible but rare, and the dictionary-scoping makes a false join require the user to *both* have the term *and* utter its spoken form non-term-ly — unlikely. Worth a wider-corpus check before shipping.
- Abbreviation terms (`k8s`, `E2E`) are NOT compounds for this purpose — ASR mis-hears them phonetically; they belong to the mishear handlers.

## Taxonomy status (the intent-recovery recovery problem)

1. **Compound splits (~41%) — SOLVED here:** deterministic join, 40%→84% recall, 0 false-joins, real-audio-robust.
2. **Clean-common-word mishears — SOLVED (Phase 6):** confidence × dictionary, real-audio AUC 0.96.
3. **Confident near-homophones (e.g. Snyk→sneak) — OPEN:** confidence can't flag them; needs the richer personal prior (usage/correction history) — the next experiment (#4 / bet B residual).

## Reproduce

```bash
bench/.venv/bin/python bench/compound_join.py \
  --add /tmp/coll5.json bench/fixtures/manifest-colliding.json \
  --add /tmp/bi5.json   bench/fixtures/manifest-biasing.json \
  --add /tmp/of5.json   bench/fixtures/manifest-overfire.json \
  --add /tmp/stress.json bench/fixtures/manifest-stress.json \
  --add /tmp/human.json bench/fixtures/manifest-human.json \
  --add /tmp/stresshuman.json bench/fixtures/manifest-stress-human.json
```
