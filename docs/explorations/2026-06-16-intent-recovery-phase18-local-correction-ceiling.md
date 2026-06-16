# Intent-recovery Phase 18 — the local correction ceiling (the *real* small-model question)

**Date:** 2026-06-16
**Status:** Decision experiment + a correction to Phase 16. Answers the actual "build our own small ML model?" question: not *replace the cleanup LLM*, but get **dictionary-aware ASR correction good enough to skip an LLM pass on every dictation** — fast, on-device, with the LLM relegated to off-hot-path dictionary-building and explicit refine commands. Public clips only. Single speaker, 74 clips — directional.

## Reframe (why Phase 16 answered the wrong question)

Phase 16 asked "can a custom small model beat the cleanup *LLM* at cleanup?" → no. But the goal isn't to beat the LLM — it's to **match its dictionary-aware correction LOCALLY**, so most dictations never pay an LLM round-trip. The right baseline isn't "the LLM is already good"; it's "how close does pure-local correction get, and where's the gap a learned model could close?"

## Method

Ran the **whole handler stack as one end-to-end corrector** over raw ASR (no LLM on the hot path):
per word near a dict term (grapheme **or** near-exact phonetic, Ph11): if **low-confidence** → recover to the term (class-2, Ph6); if **confident** → recover only if **context fits** the term's blurb (class-3, Ph9 embedder); then a deterministic **compound/acronym join** (class-1, Ph7/15). Scored against the cloud LLM (Ph16 ceiling) and raw ASR. Two operating points: confidence-gated class-2, and **context-gated everything** (precision mode).

## Results (74 public clips)

| corrector | WER | term recovery | over-fire |
|---|---|---|---|
| raw ASR | 6.3% | 14/36 (39%) | 0 |
| **local, conf-gated** | 7.2% | **27/36 (75%)** | 9 |
| **local, context-gated** | **5.1%** | 26/36 (72%) | 2 |
| cloud cleanup LLM (ceiling) | 2.1% | 32/36 (89%) | 0 |

## The finding (corrects Phase 16)

**Local dictionary-aware correction genuinely works — and the remaining gap to the LLM is exactly the headroom a small *learned* model is built to close.**

1. **It recovers most terms with no LLM:** 39% → **72–75%** (LLM 89%). The bulk of the dictionary-respecting value is achievable on-device, instantly.
2. **The gap is precision, not recall reach.** Confidence-gating over-fires **9** (and *raises* WER to 7.2%); context-gating drops over-fire to **2** and WER to **5.1%** (below raw) while holding 72% recovery. **No single hand-tuned rule hits the LLM's 89%-recall / 0-over-fire / 2.1%-WER corner** — the thresholds trade recall against precision and can't win both.
3. **That corner is what a learned model targets.** Trained to *jointly* combine the same local signals — per-token **confidence**, the **CTC posterior**, dictionary **grapheme+phonetic proximity**, and the **context embedding** — a small model can push recall toward 89% at ~0 over-fire, finding the operating point the hand rules can't. This is the FastCorrect/posterior-conditioned-corrector idea, and **the experiment now motivates it with evidence** (the hand-built frontier is visibly suboptimal).

So the corrected verdict: a small ML correction model is **not** justified to beat the cleanup LLM at cleanup (Ph16 stands for *that* question) — but it **is** well-motivated as the **fast on-device path that approximates the LLM's dictionary-aware correction without an LLM per dictation**, closing the precision/recall gap the rule stack leaves. That's the user's actual thesis, and it's supported.

## The virtuous loop (why this compounds)

The local corrector's quality scales with the **dictionary** (more terms, richer `context` blurbs → better proximity + contextual-fit). Installations with a cleanup LLM can **grow the dictionary off the hot path** — exactly what `CorrectionJournal` + `LearningAnalyzer` + `LearnedStore` already do (the LLM periodically mines corrections into dictionary terms). So: LLM builds the dictionary occasionally; the small local corrector uses it on every dictation. The LLM-per-dictation cost disappears; the LLM becomes a background teacher + on-demand refiner.

## What to build next (evidence-ordered)

1. **Tune the rule stack to its own frontier first** (cheap): context-gate everything, sweep the embed + proximity + confidence thresholds jointly — Ph18 already shows context-gating alone beats raw WER at 2 over-fires. Establish the best *rule-based* operating point as the bar.
2. **Then weigh a learned corrector** against that bar. It needs paired (raw→clean) + correction-journal data — which the dictionary-auto-build loop produces. Gate the model build on whether the tuned rules fall short of the product bar, not on novelty.
3. The model is small and **posterior-conditioned** (the CTC matrix is already extracted for biasing — a free re-listen signal), so it's featherweight and local by construction.

## Honest bounds

- Single speaker, 74 short clips, adversarial corpus (dense collisions → high term density). Real dictation has fewer terms per utterance, so over-fire pressure differs; re-measure on ordinary dictation before productionizing.
- The "learned model would close the gap" is an *inference from the visible rule-frontier suboptimality*, not yet a trained-model result. The honest next step is tuning the rules to their ceiling, then training only if that ceiling is short of the bar.
- WER normalized; recovery/over-fire are substring checks on public terms.

## Reproduce

```bash
bench/.venv/bin/python bench/local_correct.py --tokens /tmp/pub-tokens.jsonl \
  --results /tmp/pub.json --llm /tmp/pub-llm.jsonl --blurbs bench/blurbs-overfire.json [--ctx-all]
```
