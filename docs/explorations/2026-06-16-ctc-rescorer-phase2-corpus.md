# CTC rescorer — Phase 2: a colliding true-positive corpus validates the single-word lexicon gate

**Date:** 2026-06-16
**Status:** Research finding (issue #100, opportunity #1). Phase 2 — close the Phase 1 gap (no true short-term positives) and measure the lexicon gate's recall cost. **No production code changed.**
**Builds on:** `docs/explorations/2026-06-16-ctc-rescorer-phase1-diagnosis.md`
**Corpus added:** `bench/corpus/colliding.json` (16 utterances → 48 clips × 3 voices) — short colliding dictionary terms genuinely spoken in context.

## TL;DR

- **The Phase 1 gap is closed.** A new "colliding" corpus puts the short collision-prone terms (CRAN/Redis/Snyk/k8s/E2E/worktree/ultrathink) into clips where they are *actually spoken*, so we can finally measure what the lexicon gate costs in recall.
- **A refined gate separates over-fire from recovery perfectly on this data: suppress a replacement iff the original word is a SINGLE real English word.** Across all three corpora (54-clip over-fire + 48-clip Phase-1 recall + 48-clip colliding): **15/15 over-fires killed, 31/31 true positives kept — zero recall cost, no margin threshold required.**
- **Why it's clean:** over-fires are *always* a single common word being overridden (`ran`,`cram`,`crane`,`radish`); true recoveries are *never* that — they are ASR garble (`Parlek`,`Verdex`,`redisc`) or **multi-word compounds** (`work tree`→worktree, `ultra think`→ultrathink, `fluid audio`→FluidAudio). The naive Phase-1 gate ("any real word") wrongly threatened the compounds; restricting to **single-token** fixes it.
- **Two honest limits remain:** (1) the single-word-collision *recovery* path (user says "CRAN", ASR hears "ran") is eliminated by fiat — this corpus shows it's nearly empty (ASR renders distinctive terms correctly on its own: CRAN 9/9, E2E 6/6, k8s 6/6), but it is not provably zero, so the gate consciously favors the common word and leaves per-term `llmOnly` as the escape. (2) **Snyk is a total recall miss (0/9, rescorer included)** — an orthogonal recall hole, unrelated to over-fire.
- **Net:** strong greenlight for the A3/A2 build with a concrete, validated rule. Production form should key on **word frequency** (suppress only *common* single words) rather than "any dictionary word," and is naturally paired with the `llmOnly` escape for genuine common-word collisions.

## The new corpus

`bench/corpus/colliding.json`: 16 utterances, each genuinely containing a short dictionary term whose mis-ASR collides with a common word — e.g. "Install the forecast package directly from CRAN.", "We cache the session tokens in Redis.", "Create a new worktree for that feature branch." Synthesized × 3 voices (48 clips) via the existing `say` pipeline. Scored with `dictionary-overfire.json` (the 8 short terms).

**Caveat:** macOS `say` may pronounce abbreviations (k8s, E2E) unlike a human, so those terms' numbers are lower-confidence than the word-like terms (CRAN/Redis/Snyk/worktree). It remains the best creds-free proxy and matches the existing bench methodology.

## Per-term recall (raw ASR → vocab-boosted), colliding corpus

| term | raw | boosted | rescorer's role |
|---|---|---|---|
| CRAN | 9/9 | 9/9 | ASR already correct — rescorer not needed |
| E2E | 6/6 | 6/6 | ASR already correct |
| k8s | 6/6 | 6/6 | ASR already correct |
| Redis | 8/9 | 9/9 | +1 recovery (`redisc`→Redis, garble) |
| worktree | 0/6 | 6/6 | **+6 recovery** (`work tree`→worktree) |
| ultrathink | 0/3 | 3/3 | **+3 recovery** (`ultra think`→ultrathink) |
| Snyk | 0/9 | 0/9 | **total miss — rescorer can't spot it** |

The rescorer's genuine value here is **+10** (worktree +6, ultrathink +3, Redis +1). Critically, **9 of those 10 recoveries are multi-word compounds; the 10th is garble. None is a single common word.** The only single-real-word firings on this corpus were 3 *over-fires* (`ran`→CRAN on a Redis clip — "The Redis instance **ran** out of memory").

## The gate sweep (all three corpora, unified)

Gate: *suppress the replacement iff `original` is a single real English word* (lexicon = `/usr/share/dict/words`; no margin term).

| corpus | population | survive (fire) | want |
|---|---|---|---|
| over-fire | 12 FP | 0 | 0 |
| colliding | 3 FP | 0 | 0 |
| Phase-1 recall | 21 TP | 21 | 21 |
| colliding | 10 TP | 10 | 10 |

**Over-fires killed: 15/15. True positives kept: 31/31. Recall cost: 0.** Compare Phase 1's pure competitor-margin gate, which could not separate at any threshold.

## Interpretation

The discriminating structure is categorical, which is why no tuned margin is needed:

- **Over-fire = a single, common, correctly-transcribed word gets overridden** by an acoustically-similar dictionary term carried over the line by the flat `+cbw`. The original is, by definition, a real word.
- **Legitimate recovery = the original is *not* a plain single word** — it's ASR garble (a non-word the ASR emitted because the real term is OOV) or a multi-word rendering of a compound term. Neither trips a single-token real-word rule.

This makes "is the original a single common word?" a near-perfect proxy for "is this an over-fire?", with the margin/duration features (A2) reserved as secondary signals for the residual.

## Limits to carry forward (do not over-claim)

1. **Single-word-collision recovery is sacrificed.** The gate cannot recover "CRAN" when ASR cleanly hears "ran". The corpus shows ASR almost never does that for distinctive terms (they transcribe correctly on their own), so the sacrificed recall is near-zero *here* — but real-world contexts may differ. Conscious trade: favor the common word; `biasing: "llmOnly"` remains the per-term escape, and the cleanup LLM's context is the other recourse.
2. **Frequency, not just dictionary membership.** Production should suppress only for *common* single words (a frequency table), so a rare real word that's actually ASR garble-ish can still be corrected. This corpus doesn't stress that distinction.
3. **Snyk 0/9** is a separate recall bug (the rescorer never spots it) — worth its own look, independent of the gate.
4. **Small, synthetic, 3 voices.** The separation is categorical (robust to noise) but more voices/terms would harden it. Voice expansion was deprioritized precisely because the result is categorical rather than threshold-tuned.

## Revised build picture (issue #100, Option 4)

- **Validated lead lever:** a single-token, frequency-aware lexicon gate on the replace decision — "a dictionary term may override a common single word only with strong evidence (or never; defer to LLM)." Beats 12/98.3% (→ 0 over-fires / full recall on the measured set).
- **A1 (competitor margin):** secondary, used only inside the real-word branch if a soft (non-categorical) version is wanted.
- **Hybrid with LLM/`llmOnly`** for the irreducible common-word collisions stands.
- **Next (Phase 3):** prototype the gate in the rescore path (own the replace decision per #100) and re-measure end-to-end; expand voices + add a frequency table; investigate the Snyk recall miss separately.

## Reproduce

```bash
python3 bench/gen_fixtures.py --corpora colliding --manifest bench/fixtures/manifest-colliding.json
parleq-app/.build/debug/asr-bench --manifest bench/fixtures/manifest-colliding.json \
  --wav-dir bench/fixtures --paths batch --dictionary bench/dictionary-overfire.json \
  --cbw 2.0 --min-similarity 0.65 --out /tmp/coll.json --dump-replacements /tmp/coll-dump.jsonl
python3 bench/score_recall.py /tmp/coll.json bench/fixtures/manifest-colliding.json
# gate analysis: classify dump rows by single-real-word original (see this doc's tables)
```
