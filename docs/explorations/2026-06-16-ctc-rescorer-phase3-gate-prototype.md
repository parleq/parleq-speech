# CTC rescorer — Phase 3: end-to-end frequency-gate prototype (5 voices)

**Date:** 2026-06-16
**Status:** Research finding (issue #100, opportunity #1). Phase 3 — prototype the gate end-to-end with a real frequency lexicon, harden across 5 voices, and pin the precision/recall tradeoff. **No app or FluidAudio code changed** — the gate is prototyped as a post-processor on `asr-bench` output.
**Builds on:** Phase 1 (`...phase1-diagnosis.md`) and Phase 2 (`...phase2-corpus.md`).
**Tooling added:** `bench/apply_gate.py` (reverts gate-suppressed replacements in the boosted hyp, emits a gated results JSON the canonical scorers consume). Frequency source: `wordfreq` (installed in `bench/.venv`, dev-only).

## TL;DR

- **The gate works end-to-end, through the canonical scorers, hardened across 5 voices (US/GB/AU + 2× IN).** Rule: *suppress a dictionary replacement iff the original is a SINGLE token with `wordfreq` zipf ≥ 2.5* (a common word).
- **Result @ zipf 2.5, 5 voices: over-fires 19 → 0; biasing recall 97% → 97% (zero cost); colliding recall 78.8% → 77.5% (one true recovery lost).**
- **That single lost recovery is the irreducible case, now observed:** `CRA → CRAN` on the Indian-accent voice — the user said "CRAN", ASR heard "CRA" (a real-ish token, zipf 2.94), and the gate suppressed the correct fix. This is exactly Phase 1 Finding 4 (common-token collisions are acoustically unsolvable post-hoc) materializing at scale. Net recall cost = **1 of 56 true positives (~1.8%)**, entirely on that irreducible case; the per-term `biasing: "llmOnly"` escape covers it.
- **The threshold is a clean precision/recall knob** (over-fires surviving / true recoveries lost): T2.0 → 0/4, **T2.5 → 0/1**, T3.0 → 5/0. T2.5 is near-optimal.
- **A real frequency lexicon matters and is the right production form** (not bare dictionary membership): garble scores zipf 0.0; common words 2.8–6.0; the threshold sits cleanly in the gap.
- **Snyk recall miss diagnosed (separate problem):** ASR renders "Snyk" → "SNC"/"SNCC"; grapheme similarity (~0.5) is below the 0.65 candidate-generation gate, so it is never a candidate — the acoustic check never runs. This is a *candidate-generation* recall gap where **phonetic** matching would help (the opposite of its role in over-fire). Orthogonal to the replace-decision gate.

## End-to-end numbers (5 voices: Samantha/Daniel/Karen/Rishi/Tara)

| arm | clips | baseline | gated (zipf 2.5) |
|---|---|---|---|
| over-fire (`dictionary-overfire`) | 90 | **19** over-fires | **0** over-fires |
| biasing recall (`dictionary.json`) | 100 pairs | 97% (97/100) | **97% (97/100)** |
| colliding recall (`dictionary-overfire`) | 80 | 78.8% (63/80) | 77.5% (62/80) |

Scored with the canonical `score_overfire.py` / `score_recall.py`. The applier reverts only suppressed replacements in the boosted hyp, so arms with zero suppressions are byte-identical to baseline (biasing: 0 suppressed → unchanged, as shown). The colliding 78.8% baseline gap is almost entirely the **9 Snyk clips** the rescorer can't spot (see below), not the gate.

## The precision/recall knob (threshold sweep)

Single-token zipf threshold T; over-fires that survive (of 19) vs colliding true recoveries lost (of 20 single-token TPs):

| T | over-fires surviving | colliding TPs lost |
|---|---|---|
| 1.5 | 0 | 4 |
| 2.0 | 0 | 4 |
| **2.5** | **0** | **1** |
| 3.0 | 5 | 0 |
| 3.5 | 9 | 0 |
| 4.0 | 14 | 0 |

The over-fire originals cluster at zipf 2.78–4.87 (radish 2.78, cram 3.14, crane 3.92, ran 4.87); garble at 0.0. T=2.5 captures every over-fire original while sparing all but the one genuinely-ambiguous short-token recovery (`CRA` 2.94). Pushing T to 3.0 spares that recovery but lets the radish→Redis over-fires (2.78) back in. The crossover *is* the irreducible region.

## The one lost recovery (be precise about the cost)

`c03-cran-Tara`: reference "Is that library on CRAN yet…"; ASR (Indian-accent voice) emitted `CRA`; the rescorer correctly fixed `CRA → CRAN`; the gate suppressed it because `CRA` is a single token with zipf 2.94 ≥ 2.5. There is no post-hoc signal that separates this from the over-fire `ran → CRAN`: the original tokens are short, real-ish, and acoustically adjacent. Confirmed unsolvable at the rescorer level — the recourse is the cleanup LLM's context or per-term `llmOnly`. Every *other* true recovery (multi-word compounds, garble originals) is untouched by the gate.

## Snyk: a separate candidate-generation recall gap

Across all 9 Snyk colliding clips, ASR transcribes "Snyk" as `SNC`/`SNCC` (acronym interpretation). The grapheme Levenshtein similarity `snyk`↔`snc` ≈ 0.5 is below the `minSimilarity` 0.65 candidate gate, so SNC is never proposed as a candidate and the CTC acoustic check never runs — 0/9 recall, with or without biasing. Levers (all orthogonal to the over-fire gate): phonetic/G2P candidate generation (helps recall here, unlike its over-fire role), a per-term alias (`Snyk` ← `SNC`), or a lower candidate-gen threshold (raises over-fire — undesirable). Recommend treating candidate-generation recall as its own work item.

## Build recommendation (issue #100, Option 4) — consolidated across Phases 1–3

1. **The replace-decision lever is a single-token, frequency-aware suppression** ("a dictionary term may override a *common single word* only with strong evidence — or not at all, deferring to the LLM"), with zipf ≈ 2.5 as the default knob. Validated: **19 → 0 over-fires at ~1.8% recall cost, all on the irreducible collision.** This decisively beats both the 0.14.5 baseline (12–19 over-fires) and the refuted A1 competitor-margin approach (couldn't separate at all).
2. **Pair with `llmOnly` / LLM context** for the irreducible common-token collisions (CRA/CRAN/ran). This is a small, named residue, not a general failure.
3. **Candidate-generation recall (Snyk class) is separate work** — phonetic candidate generation, not a replace-gate change.
4. **Productionizing (the actual build, maintainer-gated):** owning the replace decision per #100 means either vendoring the 0.14.5 rescorer (Option 2) or a thin owned reimplementation of just the gate over FluidAudio's spotter outputs (Option 4). A shippable frequency source is needed (bundle a compact common-word list; `wordfreq`'s data is ~MB-scale — evaluate vs a curated top-N list). The gate is a few lines at the decision site; the cost is owning the surrounding rescorer, as #100 already notes.

## Caveats

- `say`-synthesized speech; abbreviation pronunciations (k8s, E2E) are lower-confidence than word-like terms. 5 voices is better than 3 but still synthetic and modest-N.
- The post-processor prototype reconstructs gated text by reverting suppressed replacements; faithful for term-presence scoring but not a substitute for implementing the gate at the real decision site (Phase 4 / build).
- zipf 2.5 is tuned on this corpus; a production threshold should be re-confirmed on real usage and may want per-language frequency.

## Reproduce

```bash
VOICES=Samantha,Daniel,Karen,Rishi,Tara
for c in overfire biasing colliding; do
  python3 bench/gen_fixtures.py --corpora $c --voices $VOICES --manifest bench/fixtures/manifest-$c.json
done
BIN=parleq-app/.build/debug/asr-bench
$BIN --manifest bench/fixtures/manifest-overfire.json  --wav-dir bench/fixtures --paths batch --dictionary bench/dictionary-overfire.json --out /tmp/of5.json   --dump-replacements /tmp/of5-dump.jsonl
$BIN --manifest bench/fixtures/manifest-biasing.json   --wav-dir bench/fixtures --paths batch --dictionary bench/dictionary.json          --out /tmp/bi5.json   --dump-replacements /tmp/bi5-dump.jsonl
$BIN --manifest bench/fixtures/manifest-colliding.json --wav-dir bench/fixtures --paths batch --dictionary bench/dictionary-overfire.json --out /tmp/coll5.json --dump-replacements /tmp/coll5-dump.jsonl
PY=bench/.venv/bin/python   # has wordfreq
for a in of5 bi5 coll5; do $PY bench/apply_gate.py --results /tmp/$a.json --dump /tmp/$a-dump.jsonl --zipf 2.5 --out /tmp/$a-gated.json; done
$PY bench/score_overfire.py /tmp/of5-gated.json bench/dictionary-overfire.json
$PY bench/score_recall.py   /tmp/bi5-gated.json bench/fixtures/manifest-biasing.json
$PY bench/score_recall.py   /tmp/coll5-gated.json bench/fixtures/manifest-colliding.json
```
