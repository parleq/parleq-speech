# CTC rescorer — Phase 4c: threshold stress test overturns "near-zero recall cost"

**Date:** 2026-06-16
**Status:** Research finding (issue #100). Phase 4c — expand the dictionary to stress the zipf gate across the collision-frequency spectrum. **This is the most important refinement of the whole investigation: it falsifies the earlier "zero recall cost" and reveals the gate's true precision/recall character.** No app code changed.
**Builds on:** Phases 1–4b. **Added:** `bench/dictionary-stress.json` (10 dev terms), `bench/corpus/stress-overfire.json` + `stress-colliding.json` (10 + 10 utterances × 5 voices = 100 clips).

## TL;DR

- **The gate's over-fire precision is perfect and robust across the entire frequency spectrum: 40 → 0** (next 5.7, god 5.6, number 5.6, task 4.6, odd 4.4, dusk 3.4, dino 3.4 — every one suppressed; zero leak). This is now confirmed on four independent corpora (synthetic curated 12→0, 5-voice 19→0, real-audio 4→0, stress 40→0).
- **But the gate's recall cost is NOT near-zero — it is large for terms whose natural mis-ASR is a common word: stress colliding recall rescorer 82% → gated 56% (13 of 17 recoveries destroyed).** `Numba`→"number", `Dask`→"desk"/"dusk", `Deno`→"Dino" are legitimate recoveries the gate wrongly suppresses because their original surface form is a common word.
- **The earlier "zero recall cost" (Phase 2/3) was an artifact of corpus selection.** Those true recoveries happened to be multi-word compounds (`work tree`→worktree) or non-word garble (`Parlek`→Parleq) — neither trips the single-token gate. The stress corpus deliberately includes single-common-word collisions, and there the gate is costly.
- **It is irreducible at the rescorer level — proven by a single word:** `"number"` is simultaneously an over-fire original (s03 "your phone **number**" → keep) and a recovery original (s13 "sped up the loop with **Numba**" → heard "number" → should become Numba). **Same surface, same zipf, opposite correct actions.** No frequency threshold, and no purely text/acoustic rescorer signal, can be right on both — only context (LLM) or per-term user policy resolves it.

## Numbers

| arm | metric | baseline | gated (zipf 2.5) |
|---|---|---|---|
| stress over-fire (50 clips) | over-fires | 40 | **0** |
| stress colliding (50 clips) | recall | raw 48% → rescorer **82%** | **56%** |

Of the 17 rescorer recoveries, the gate kept 4 and suppressed 13. The 4 kept all had originals below 2.5 (garble/rare): `Noxt`→Nuxt (0.0), `ZAD`→Zod (1.72), `pinna`→Pinia (2.10 ×2). The 13 lost had common-word originals at zipf 3.39–5.62 — **well above the threshold, so lowering/raising 2.5 cannot recover them without re-admitting over-fires** (the over-fire originals occupy the same 3.4–5.7 band).

## Why the curated corpora hid this

| corpus | true-recovery originals | gate cost |
|---|---|---|
| Phase 2/3 biasing | `Parlek`,`Verdex` (garble), `fluid audio` (compound) | ~0 |
| Phase 2/3 colliding | `work tree`→worktree, `ultra think`→ultrathink (compounds) | ~0 |
| **Phase 4c stress** | `number`→Numba, `desk`→Dask, `Dino`→Deno (**single common words**) | **large (82→56%)** |

The gate is blind to a term whose mis-ASR collapses onto a single common word. Whether that matters depends entirely on the **dictionary's collision profile**: distinctive terms (Parleq, FluidAudio) and compound terms (worktree) cost ~0; common-word-colliding terms (Numba/number, Dask/desk, Deno/Dino, CRAN/ran) cost a lot.

## Reframed conclusion (supersedes the Phase 2/3 "clean win")

The single-token frequency gate is a **precision instrument with a dictionary-dependent recall cost**, not a free lunch:

- **As a precision fix it is excellent and robust** — it eliminates over-fire across every corpus and frequency, at zero cost *for terms that don't collide with common words*.
- **It is a prior that favors the common word.** For a term whose natural mis-ASR is a common word, the gate suppresses the legitimate recovery. The stress corpus (100% term-intent) shows the worst case (76% of such recoveries lost); real usage cost = the fraction of common-word utterances that are actually term-intent — the irreducible ambiguity.
- **Therefore it must not be a blanket hard-suppress.** Design options:
  1. **Per-term policy** — terms the user knows collide with common words opt out of the gate (or use `biasing: "llmOnly"`); distinctive/compound terms keep it. Cheapest, and the user has the knowledge.
  2. **Lean on the LLM context leg** for common-word colliders — Phase 4a showed the cleanup LLM recovers some context terms (incl. Snyk) but also over-fires 8/90 and misses the hardest collisions, so it is a partial, not complete, recourse.
  3. **Soft gate** (raise the acoustic-margin bar for common-word originals instead of suppressing) — but Phase 1 showed the CTC margin does not separate true from false in this regime, so a soft gate likely reverts toward the original over-fire. Least promising.

## Implications for the build (issue #100)

- The over-fire problem **is** solvable cleanly and robustly (the gate, 40→0). That part of opportunity #1 is validated beyond doubt.
- "Beat 0.14.5's 12/98.3% with zero recall cost" is **too strong as a universal claim** — true only for dictionaries without common-word colliders. The honest target: **eliminate over-fire while making the recall trade per-term explicit** (gate on by default; common-word-colliding terms detected — e.g. canonical or alias has high zipf — and either auto-exempted or surfaced to the user as `llmOnly` candidates).
- The dictionary-stress harness should join the over-fire gate (#97/#98) as a standing regression guard, so future tuning sees both the precision win and the recall cost.

## Caveats

- Synthetic `say` audio; abbreviation pronunciations lower-confidence (Phase 4b showed `say` overstates recall). The stress corpus is deliberately adversarial (every colliding clip is term-intent), so 56% is a worst-case recall floor for these terms, not an expected real-world figure.
- 10 terms, 5 voices. The qualitative finding (single-common-word collisions defeat the gate) is structural and corpus-independent; the exact percentages are not.

## Reproduce

```bash
python3 bench/gen_fixtures.py --corpora stress-overfire,stress-colliding \
  --voices Samantha,Daniel,Karen,Rishi,Tara --manifest bench/fixtures/manifest-stress.json
parleq-app/.build/debug/asr-bench --manifest bench/fixtures/manifest-stress.json \
  --wav-dir bench/fixtures --paths batch --dictionary bench/dictionary-stress.json \
  --cbw 2.0 --min-similarity 0.65 --out /tmp/stress.json --dump-replacements /tmp/stress-dump.jsonl
bench/.venv/bin/python bench/apply_gate.py --results /tmp/stress.json --dump /tmp/stress-dump.jsonl \
  --zipf 2.5 --out /tmp/stress-gated.json
bench/.venv/bin/python bench/score_recall.py /tmp/stress-gated.json bench/fixtures/manifest-stress-colliding.json
```
