# CTC rescorer — Phase 4a: the LLM-context leg (does cleanup recover/over-fire?)

**Date:** 2026-06-16
**Status:** Research finding (issue #100). Phase 4a — measure the cleanup LLM's role in the hybrid: does it recover terms the rescorer/gate miss, and does it introduce its own over-fires? **No app code changed.**
**Builds on:** Phases 1–3. **Tooling added:** `bench/llm_cleanup_probe.py` — runs the REAL cleanup prompt (extracted live from `SystemPrompts.swift`: `baseCleanup` + `vocabularyHint`) over raw-ASR transcripts via Vertex `generateContent` (gemini-2.5-flash-lite, temp 0, thinkingBudget 0, dict hint on), gcloud ADC auth. Mirrors `VertexProvider`.

## TL;DR

- **The cleanup LLM is a strong but imperfect recall layer, and it is NOT over-fire-free.** With the dictionary hint on (the realistic config), over the 5-voice corpora:
  - **Colliding recall: raw 54% → LLM 82%** (recovers 23 terms from context + hint).
  - **It recovers Snyk 0→5/15** — the exact candidate-generation gap the rescorer cannot touch (ASR emits "snake"/"SNCC"; no grapheme candidate, but the LLM fixes it from context).
  - **It over-fires 8/90** — "The **crane** lifted the steel beams" → CRAN; "The **radish** in the garden salad" → Redis — ignoring its own prompt rule to leave homophones alone. Fewer than the rescorer's 19, but non-zero, and on the same collision terms.
- **`CRA → CRAN` is missed by the LLM too** (CRAN stays 13/15) — the same irreducible single-token collision the gate suppresses. **All three layers (rescorer, gate, LLM) fail it**, confirming it is genuinely irreducible, not a layer-specific weakness.
- **Implication for the build:** the rescorer gate and the LLM are *complementary, not substitutes*. The gate gives a clean ASR-side replace decision (0 over-fire) but has recall holes (Snyk, candidate-gen); the LLM fills context-recall holes (incl. Snyk) but adds its own over-fire. A clean end-to-end result needs **both** — and the LLM's vocabulary hint needs the *same* "don't override a common word" discipline the gate encodes, because flash-lite does not reliably self-apply it.

## Method

`llm_cleanup_probe.py` extracts `baseCleanup` + the `vocabularyHint` header from `SystemPrompts.swift` (so the prompt can't drift from the app), appends the dictionary-overfire terms as the hint bullets, and POSTs each raw-ASR transcript as `Transcript to clean up:\n\n<raw>` to Vertex. Two arms, dict hint ON:

- **Colliding (recall):** 80 raw transcripts that genuinely contain a short term → does the cleaned text contain the canonical term?
- **Over-fire (precision):** 90 raw transcripts with a common word and no term → does the cleaned text *insert* a dictionary term?

## Recall (colliding corpus): raw 43/80 (54%) → LLM 66/80 (82%)

| term | raw | LLM-cleaned |
|---|---|---|
| CRAN | 13/15 | 13/15 *(no gain — incl. the irreducible CRA→CRAN miss)* |
| Redis | 11/15 | 14/15 |
| Snyk | **0/15** | **5/15** *(rescorer gets 0 — candidate-gen gap)* |
| k8s | 9/10 | 9/10 |
| E2E | 10/10 | 10/10 |
| worktree | 0/10 | 10/10 |
| ultrathink | 0/5 | 5/5 |

The LLM recovers the multi-word compounds (worktree/ultrathink) like the rescorer, recovers more Redis garble, and uniquely recovers some Snyk (where ASR emits "snake"/"SNCC" — no grapheme candidate for the rescorer, but enough context for the LLM). It does **not** recover `CRA → CRAN`.

## Precision (over-fire corpus): LLM inserts a term on 8/90

All 8 are the two hardest single-word collisions, with clear disambiguating context the LLM overrode:
- `crane → CRAN` ("The crane lifted the steel beams into place…") — all 5 voices.
- `radish → Redis` ("The radish in the garden salad was crisp…") — 3 voices.

The cleanup prompt explicitly instructs *"when context indicates a different word was intended … leave the speaker's actual word alone,"* yet flash-lite corrected `crane → CRAN` in an unmistakable construction context. **The dictionary hint is itself an over-fire source**; the rescorer gate (19→0) does not protect against this LLM-side over-fire, because the LLM runs after it.

## Consolidated picture (5-voice corpora)

| approach | over-fires /90 | colliding recall /80 | Snyk /15 | CRA→CRAN |
|---|---|---|---|---|
| raw ASR | 0 | 43 (54%) | 0 | miss |
| rescorer 0.14.5 | 19 | (recovers) | 0 | over-fires |
| **rescorer + single-token freq gate** | **0** | ~62 | 0 | suppressed (miss) |
| **LLM cleanup (dict hint)** | 8 | **66 (82%)** | **5** | miss |

## What this means for issue #100

1. **Gate and LLM are complementary.** Ship the rescorer gate for a clean ASR-side decision (0 over-fire); rely on the LLM for context recall (Snyk, compounds) — but recognize the LLM adds ~8/90 over-fire of its own.
2. **The cleanup vocabulary hint needs the gate's discipline.** Since flash-lite over-applies the hint on common words (crane/radish), the prompt (or a post-LLM guard) should encode the same "don't override a common single word without strong support" rule — or accept the residual LLM over-fire. Worth testing a `--no-dict-hint` run to quantify how much over-fire the hint causes vs. recall it buys.
3. **`CRA→CRAN` is irreducible across all layers.** No rescorer, gate, or LLM recovers it. Recourse is an explicit alias (`CRAN` ← `CRA`) or user awareness — not a general mechanism.
4. **Snyk is recoverable after all — by the LLM, not the rescorer.** The candidate-generation gap (phonetic) is real for the rescorer but the LLM covers a third of it from context. Phonetic candidate generation would help the rescorer leg further.

## Caveats

- gemini-2.5-flash-lite specifically; a stronger model may over-fire less / recover more. Synthetic `say` audio. Dict hint = the over-fire dictionary (8 terms).
- The probe extracts the prompt from source as of this date; re-extract if `SystemPrompts.swift` changes.
- A `--no-dict-hint` arm (pure-context recovery, no vocabulary bias) is the obvious next measurement to separate "hint-driven over-fire" from "model-driven recovery."

## Reproduce

```bash
bench/.venv/bin/python bench/llm_cleanup_probe.py --results /tmp/coll5.json \
  --dictionary bench/dictionary-overfire.json --out /tmp/coll5-llm.jsonl
bench/.venv/bin/python bench/llm_cleanup_probe.py --results /tmp/of5.json \
  --dictionary bench/dictionary-overfire.json --out /tmp/of5-llm.jsonl
# score: term-presence recall on colliding; term-insertion count on over-fire
```
