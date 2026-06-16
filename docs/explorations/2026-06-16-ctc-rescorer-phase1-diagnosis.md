# CTC rescorer — Phase 1 diagnosis: the over-fire is a common-word collision, not a margin problem

**Date:** 2026-06-16
**Status:** Research finding (issue #100, opportunity #1). Phase 0–1 of the "better rescorer" investigation — confirm the mechanism before any build. **No production code changed.**
**Tooling added:** `asr-bench --dump-replacements <jsonl>` (per-applied-replacement CTC scores) + `bench/analyze_margins.py`. Both dev-only.
**Companion:** `docs/explorations/2026-06-15-fluidaudio-0.15-biasing-regression.md` (the ROC sweep) and the local-ASR opportunity memo.

## TL;DR

- **The bench reproduces the operating point exactly:** 12 over-fires / 98.3% recall (59/60) / 66.7% raw, FluidAudio 0.14.5, cbw 2.0, minSim 0.65.
- **The flat `+cbw` boost is the firing mechanism, confirmed with numbers.** For every over-fire term the boost is the flat base 2.0 (CRAN=2 tokens, Redis=3 tokens, both ≤ `referenceTokenCount`=3, so `adaptiveCbw == base`). On 7 of 12 over-fires the dictionary term's **raw** CTC score is *worse* than the original word's — only the `+2.0` flips the decision.
- **A1 (competitor-relative margin) ALONE is refuted.** True and false corrections have *overlapping* raw-CTC-margin distributions; the true positives are in fact *more* cbw-carried (67%) than the false (58%). No margin threshold separates them — killing all 12 FPs (δ≈+1.0) also kills *all* 21 TPs.
- **The real discriminator is lexical, not acoustic.** **12/12 false positives replace a common English word** (`ran`, `cram`, `crane`, `radish`); **15/21 true positives replace ASR garble** (`Parlek`, `Verdex`, `Parlach`). A gate of *"a dictionary term may override a real English word only with a large acoustic margin"* kills **11/12 over-fires at 20/21 recall** (δ≈0.5, illustrative).
- **But there is an irreducible limit:** when a dictionary term collides with a common word (CRAN~ran, Redis~radish, Snyk~sync), *"they said ran"* (true negative) and *"they said CRAN, misheard as ran"* (false negative) have **identical surface text and overlapping acoustics** — no post-processor can separate them. That residue belongs to LLM context biasing or per-term `biasing: "llmOnly"`.
- **Net:** the build lead shifts from **A1 (margin)** to **A3/A2 (lexicon/frequency-aware gate + margin floor)**, paired with the existing LLM/`llmOnly` escape for common-word collisions. Phase 2 corpus expansion (true short-term positives, more voices) is now clearly a prerequisite before tuning thresholds.

## What was measured

`asr-bench` was extended with `--dump-replacements`, writing one JSONL row per **applied** replacement: `originalScore` (raw CTC of the original word), `replacementScore` (the **boosted** vocab CTC = rawVocab + adaptiveCbw), `reason`, and the run's `cbw`. Two arms, FluidAudio 0.14.5, defaults (minSim 0.65, cbw 2.0):

- **Over-fire arm** — `manifest-overfire` + `dictionary-overfire` → every applied replacement is a **false positive** (the corpus contains no true term). 12 rows.
- **Recall arm** — `manifest-biasing` + `dictionary.json` → applied replacements are mostly **true positives**. 21 rows.

The raw competitor margin a margin-gate would use is `rawMargin = replacementScore − cbw − originalScore` — **exact** for the over-fire terms (adaptiveCbw == flat cbw, verified from the debug log: `CTC('CRAN'): -13.53 + cbw=adaptive=2.00 (base=2.0, tokens=2) = -11.53`).

## Finding 1 — the flat boost fires the over-fires

| over-fire | original (raw CTC) | CRAN/Redis (raw) | boosted (+2.0) | fired because |
|---|---|---|---|---|
| `ran`→CRAN | −13.42 | −13.53 | −11.53 | only the +2.0 (raw CRAN *loses* to `ran`) |
| `crane`→CRAN | −11.21 | −12.05 | −10.05 | only the +2.0 |
| `cram`→CRAN | −10.97 | −10.90 | −8.90 | raw barely wins (+0.07) then +2.0 |

7/12 are "cbw-carried" (raw vocab < original; only the boost flips them); the other 5 have the raw term winning by a hair (+0.07…+0.55). Either way the decision rides on a flat 2.0 nat boost applied regardless of competitor strength.

## Finding 2 — a raw-CTC margin can't separate true from false

Sweeping a competitor-relative gate (fire iff `rawMargin > δ`):

| δ | false-positives surviving | true-positives surviving |
|---|---|---|
| −2.0 *(current gate)* | 12/12 | 21/21 |
| 0.0 | 5/12 | 21/21 |
| +0.5 | 1/12 | 6/21 |
| +1.0 | 0/12 | 0/21 |

FP-survival and TP-survival fall **together**. The distributions overlap (FP rawMargin −0.84…+0.55; TP −1.00…+1.00, and the TP figures are *optimistic* — multi-token true terms have adaptiveCbw > 2.0, so their true rawMargins are even lower). This is the quantified form of the regression's "false scores ≈ true scores": **the discriminating signal is not in the CTC score comparison.**

## Finding 3 — the discriminator is "is the original a real word?"

| | false positives | true positives |
|---|---|---|
| original is a real English word | **12/12** | 6/21 (all `fluid audio`→FluidAudio, high margin) |
| original is ASR garble / non-word | 0/12 | 15/21 (`Parlek`, `Verdex`, `Parlach`, `root 53`…) |

Combined gate — *fire iff `original is NOT a real word` OR `rawMargin > δ`*:

| δ | FP surviving | TP surviving |
|---|---|---|
| +0.5 | **1/12** | **20/21** |
| +1.0 | 0/12 | 15/21 |

At δ≈0.5 this removes 11 of 12 over-fires while keeping 20 of 21 corrections — a clean separation the pure margin could not produce. The lexicon does the heavy lifting; the margin floor only governs the real-word-phrase joins (`fluid audio`→`FluidAudio`), which clear it comfortably. (Lexicon here = `/usr/share/dict/words`; a frequency table or a small distractor list would be the production form — this is the A3/A2 "anti-context / frequency" lever, not A1.)

## Finding 4 — the irreducible limit (be honest about this)

The gate works because the over-fire corpus's true intent is the *common word*. But for a dictionary term that genuinely collides with a common word, the hard case is symmetric:

- User says **"ran"** → ASR `ran` → correct to leave it. (true negative)
- User says **"CRAN"** → ASR mishears `ran` → should become CRAN. (the recall case)

**Both produce the identical hypothesis text `ran`, and Finding 2 shows their acoustics don't separate either.** No surface- or CTC-level post-processor can tell them apart; only **context** (the cleanup LLM, which can see the surrounding topic) or a **user policy** (`biasing: "llmOnly"` for that term, which already exists) resolves it. So the lexicon gate is really a *prior*: "assume the common word unless evidence is strong," which is the right default (people say "ran" far more than "CRAN") but trades away recall on truly-spoken colliding terms. This validates the memo's hybrid: owned/vendored rescorer for the safe cases + LLM biasing for the colliding ones.

## Revised recommendation for the build (updates issue #100 Option 4)

1. **Lead lever = A3/A2, not A1.** A lexicon/frequency-aware gate: a dictionary term may override a **real, common** word only with a large acoustic margin (and/or a duration sanity check); against non-words it fires freely as today. This is where the separation actually lives.
2. **Keep a margin floor** only for the real-word branch (handles legitimate real-word-phrase joins like `fluid audio`→`FluidAudio`).
3. **Route common-word-colliding terms to LLM/`llmOnly`.** For terms whose surface collides with a frequent English word, the acoustic signal is fundamentally insufficient; lean on the cleanup LLM's context or the per-term escape hatch rather than chasing an unachievable acoustic separation.
4. **A1 (competitor-relative margin) is demoted** from "highest-leverage" to "secondary signal used only inside the real-word branch." The memo's ~55–65% confidence in A1-alone resolves to: **A1 alone won't beat 12/98.3%; the lexical gate can.**

## Caveats / what Phase 2 must close

- **Small N, 3 voices** (12 FP, 21 TP). Exact δ values are illustrative, not tuned.
- **No true short-term positives.** We have zero clips of a user genuinely saying CRAN/Snyk/Redis, so the recall cost of the lexicon gate *on colliding terms* is unmeasured (Finding 4 says it's real). Phase 2 must add these.
- **TP margins are optimistic** (flat-cbw subtraction under-counts adaptiveCbw for multi-token terms) — the real separation is at least as good for the lexicon gate, but the margin-floor δ would shift.
- The lexicon check is a stand-in; production needs a frequency table or curated distractor set, plus handling of proper-noun originals that are dictionary words.

## Reproduce

```bash
cd parleq-app && swift build --product asr-bench && cd ..
BIN=parleq-app/.build/debug/asr-bench
$BIN --manifest bench/fixtures/manifest-overfire.json --wav-dir bench/fixtures --paths batch \
  --dictionary bench/dictionary-overfire.json --cbw 2.0 --min-similarity 0.65 \
  --out /tmp/of.json --dump-replacements /tmp/of-dump.jsonl
$BIN --manifest bench/fixtures/manifest-biasing.json --wav-dir bench/fixtures --paths batch \
  --dictionary bench/dictionary.json --cbw 2.0 --min-similarity 0.65 \
  --out /tmp/bi.json --dump-replacements /tmp/bi-dump.jsonl
python3 bench/analyze_margins.py --false /tmp/of-dump.jsonl --true /tmp/bi-dump.jsonl
```
