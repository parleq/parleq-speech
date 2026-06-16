# Intent-recovery Phase 11 — phonetic-aware triggering

**Date:** 2026-06-16
**Status:** Experimental result. Tests whether adding **phonetic** proximity to the dictionary-match **trigger** (the gate every recovery handler depends on) catches near-homophones the grapheme trigger misses, without over-firing. Bench tooling only (`bench/phonetic_trigger.py`); no app code. Single speaker, modest N — directional.

## The question

Every handler (Ph6 confidence×dict, Ph9 contextual-fit, Ph10 combine) first needs the **trigger** to flag a word as "near a user term." That trigger uses **grapheme** proximity (difflib on spelling). It structurally misses near-homophones whose spellings *diverge*: difflib rates `Snyk`↔"sync" at ~0.50 (under the 0.60 gate), even though they sound identical — `metaphone(Snyk) = metaphone(sync) = "SNK"`. This is the candidate-generation gap first flagged in Phase 3 (`Snyk` 0/9). Does a phonetic gate close it cheaply?

## Method

Two measurements on the real recordings + the dictionary:

1. **Trigger recall** on 63 near-term clips (`c*`/`o*`, each built to contain a near-homophone of its term): does the gate fire on the intended term, under grapheme-only / phonetic-only / **grapheme-OR-phonetic**?
2. **Spurious-fire** on 382 words of ordinary dictation (the general corpus, which contains *no* dict terms): how many words wrongly fire the gate — the precision cost.

Phonetic proximity = difflib ratio of the Metaphone codes (1.0 = identical codes), via `jellyfish`. Swept the phonetic gate to find the operating point.

## Results

Trigger recall (63 near-term clips) and spurious-fire (382 ordinary words), at the chosen **phonetic gate ≥ 0.90** (near-exact code match):

| gate | trigger recall | spurious fires (/1000 words) |
|---|---|---|
| grapheme only (status quo) | 79% (50/63) | 26.2 |
| phonetic only | 48% (30/63) | **0.0** |
| **grapheme OR phonetic** | **83% (52/63)** | **26.2** |

The two clips grapheme missed but phonetic caught are exactly the divergent-spelling near-homophone: **`sync`→Snyk** (grapheme 0.50, phonetic 1.00), twice.

Phonetic-gate sweep:

| phonetic gate | combined recall | added spurious vs grapheme |
|---|---|---|
| 0.84 | 84% (53/63) | +7.8/1000 (and a junk catch: 'ground'~CRAN @0.86) |
| **0.90–1.00** | **83% (52/63)** | **+0.0** |

## The finding

**An exact (or near-exact) phonetic-match OR-clause is a strictly-dominant trigger upgrade: it recovers the divergent-spelling near-homophones grapheme misses (`Snyk`↔"sync") at *zero* added spurious-fire cost.**

Three points:
1. **Phonetic is a complement, not a replacement.** On its own it has *lower* recall (48% vs 79%) — when ASR spells the term correctly, grapheme nails it and metaphone can diverge. The value is the **OR**: each gate catches what the other misses.
2. **The operating point is "near-exact code match" (≥0.90).** There it adds the real wins (`sync`→Snyk) with **0 extra spurious fires** — phonetic-only false fires fall to zero, so the union stays at grapheme's rate. Loosening below 0.90 buys a junk catch ('ground'~CRAN) and +8/1000 spurious for no real recall gain.
3. **It closes the Phase-3 candidate-gen gap** (`Snyk`) cheaply and locally — pure text + dictionary, no acoustics, no model.

It is **not** a full fix: combined recall is 83%, so ~17% of near-term clips are still missed by both gates (the term got mangled beyond either spelling or sound proximity — a residual candidate-gen limit). But "free recall, zero precision cost" makes the phonetic OR-clause an unambiguous improvement.

## Implication for the trunk

Upgrade the trigger from grapheme-only to **grapheme-OR-near-exact-phonetic** (metaphone equality / ratio ≥ 0.90). It's local, deterministic, dictionary-scoped, and strictly dominant — the cheapest win surfaced in the program. It widens coverage for *every* downstream handler (Ph6/9/10) at no precision cost. (Productionizing means swapping/augmenting the proximity function the handlers share; maintainer-gated.)

## Honest bounds

- Single speaker; 63 resolvable near-term clips; only two divergent-spelling cases in the set (`sync`→Snyk) — the win is real but the corpus has few instances of it (most collisions, e.g. ran/CRAN, are *also* grapheme-near, so grapheme already catches them).
- Metaphone is English-centric and crude; double-metaphone or a learned phonetic distance could do better, untested here.
- Spurious-fire measured on 382 words — directional. Proprietary clips anonymized in any per-clip detail.

## Reproduce

```bash
bench/.venv/bin/python bench/phonetic_trigger.py --results /tmp/all.json \
  --dictionary bench/dictionary-work.json --general bench/corpus/general.json --pho-gate 0.90
```
