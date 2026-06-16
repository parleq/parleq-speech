# Intent-recovery Phase 13 — phonetic trigger wired into the probe (end-to-end check)

**Date:** 2026-06-16
**Status:** Short integration result. Wires the Phase-11 phonetic OR-clause into the contextual-fit probe's trigger (`analyze_contextual_fit.target_word`, additive `--phonetic` flag, default off) and re-runs Phase 9 to see whether the "free" trigger win moves the downstream numbers. Bench only; single speaker, small N.

## What changed

`target_word` now optionally accepts a near-exact Metaphone match (≥0.90) in addition to grapheme proximity (`--phonetic`). Default off, so Ph9/10 behavior and the 7 prior unit tests are unchanged; a new test (`test_phonetic_catches_divergent_spelling`) brings the suite to **8 passing**.

## Result (public clips vs real blurbs)

| metric | grapheme only (Ph9) | + phonetic (Ph13) |
|---|---|---|
| clips scored | 45 (23 term / 22 common) | **46** (23 / **23**) |
| all-clips embed AUC | 0.875 | **0.885** |
| confident-slice embed AUC | 0.873 (n=25) | 0.863 (n=24) |
| argmax top-1 | 65% | 65% |

## Read

- **Phonetic widens coverage as designed:** it pulls in **one over-fire clip** (`sync`→Snyk) that grapheme had dropped entirely. Context then correctly scores it **low** against the Snyk blurb (it's about syncing, not security) → a correctly-classified *common* clip, which is why all-clips AUC ticks **up** (0.875→0.885).
- **It composes cleanly downstream:** the newly-covered divergent-spelling homophone is handled correctly by contextual-fit, not mis-recovered. The trigger win doesn't break separation.
- **The confident-slice change is N-noise**, not signal: phonetic can select a *different* target word when its match outscores grapheme, which shifts that clip's target-confidence and can move it across the 0.97 slice boundary (term n 7→5). At 5–7 term clips this is within noise; don't read the 0.873→0.863 as a regression.

## Conclusion

The Phase-11 phonetic win is a **coverage/trigger** improvement (recovering `Snyk`↔"sync" cases at zero spurious cost), and this end-to-end check confirms it **integrates cleanly** with the contextual-fit handler — modestly improving overall separation by correctly classifying the newly-covered over-fire clips, with no downstream harm. It is *not* itself a separation-AUC lever; its value was already booked in Ph11 (trigger recall 79%→83%), and Ph13's job was to confirm it doesn't break what's downstream. It doesn't.

**Honest bound:** only 1–2 clips are affected at this corpus size, so every number here is within small-N noise; the qualitative "widens coverage, composes cleanly" conclusion is the durable part.
