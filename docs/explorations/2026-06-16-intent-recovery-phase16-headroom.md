# Intent-recovery Phase 16 — headroom / oracle (should we build our own small LLM?)

**Date:** 2026-06-16
**Status:** Decision experiment. Quantifies the accuracy a *custom small correction model* could add over what Parleq already has, to answer the "build our own small LLM?" question with evidence. Uses the shipped cleanup LLM (Vertex `gemini-2.5-flash`) over the **public** clips only (no proprietary text to the cloud). Single speaker, 74 clips — directional.

## The argument being tested

A custom small model's accuracy is **bounded above by a good general LLM** (it won't exceed one; it aims to approach it cheaply/locally). So the residual error left by the *already-shipped* LLM is the hard part a small model would have to beat — and almost certainly can't. If that residual is small, a custom model has **~no accuracy headroom**; its only remaining case is non-accuracy (size/speed/privacy, or less over-fire).

## Results (74 public clips, WER after Whisper normalization)

| stage | WER | note |
|---|---|---|
| oracle (perfect) | 0.0% | the ceiling |
| **cloud cleanup LLM** | **2.1%** | **what Parleq already ships** |
| local deterministic only | 5.5% | compound/acronym join (Ph7/15), **no model** |
| raw ASR | 6.3% | baseline |

- **The shipped LLM removes 66% of raw word errors**, leaving a **2.1% residual**.
- **Term recovery** (term-intended clips): raw **39% → 89%** after LLM — it recovers most dictionary terms (Snyk, etc.).
- **Over-fire** (common-intended clips where a term is wrongly inserted): **0/38 raw, 0/38 after LLM.** `gemini-2.5-flash` with the vocab hint did **not** hallucinate terms here — *more* faithful than the `flash-lite` that over-fired 2/18 in Phase 8.

## Verdict: don't build a custom small model for accuracy

1. **Accuracy headroom ≈ 0.** The shipped general LLM already hits 2.1% WER / 89% term recovery / 0% over-fire. A custom *small* model is bounded above by a general LLM, so it cannot meaningfully beat this. The 2.1% residual is the genuinely-hard part a small model is *less* likely to get than the LLM, not more.
2. **The faithfulness case also weakened.** The main worry about the LLM was over-correction (Ph8/4a: flash-lite over-fired ~10%). The shipped flash model over-fired 0/38 here. So "a faithful specialized model avoids the LLM's over-fire" has little to stand on with the current model.
3. **The deterministic local layer does real but limited *fixing*** (6.3%→5.5%, class-1 only). The bulk of error-*fixing* — class-2 garble, 68% of errors (Ph14) — needs a model. (Note the distinction from Ph12: the trust surface *flags* class-2 cheaply; it doesn't *fix* it. Fixing garble needs the LLM.)

**The only real case for a custom small model is non-accuracy:** replacing the ~4 GB cloud/Gemma cleanup dependency with a *featherweight on-device* corrector, for low-RAM / offline / privacy. That's a **size/deployment** play — exactly the "lighter model" deferred in the 0.26 decision — not an accuracy play, and it already competes with the shipped on-device Gemma tier. It's a large bet that should be gated on the RAM-adoption signal, not undertaken because the cleanup quality needs it (it doesn't).

## What WOULD be worth a (much smaller) learned component

Not a full LLM — a **narrow learned phonetic/edit distance** for the ~17% trigger residual Ph11 still misses (a tiny supervised model over grapheme+phonetic+context features). That's bounded, cheap, and targets a real gap, unlike a general corrector.

## Honest bounds

- Single speaker, 74 short clips, adversarial (dense collisions); raw WER 6.3% is low because the clips are short and clean. Real-world dictation WER and the LLM residual will differ — but "the shipped LLM already captures most of it, leaving a small hard residual a custom model can't beat" is the structural conclusion.
- One model (`gemini-2.5-flash`); a stronger model would only *lower* the residual (less headroom), a weaker one raise it (but then it's the model's weakness, not a custom-model opportunity).
- WER is normalized; term recovery/over-fire are substring checks on public terms only.

## Reproduce

```bash
bench/.venv/bin/python bench/llm_cleanup_probe.py --results /tmp/pub.json \
  --dictionary bench/blurbs-overfire.json --model gemini-2.5-flash --out /tmp/pub-llm.jsonl
bench/.venv/bin/python bench/headroom.py --results /tmp/pub.json \
  --llm /tmp/pub-llm.jsonl --dictionary bench/blurbs-overfire.json
```
