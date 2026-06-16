# Intent-recovery program — Phase 5 foundation: the ASR knows where it's wrong

**Date:** 2026-06-16
**Status:** Foundational research result for the "intent-recovery" reframe (the featherweight/novel direction; supersedes treating cleanup as text-repair). **This is the linchpin experiment — it decides whether the whole reframe has legs. It does.** No app code changed.
**Reframe:** dictation cleanup as `intent ≈ argmax P(intent | acoustics, transcript, personal prior, destination)` — combine evidence under uncertainty, surface what can't be resolved. (Assumption-breaks #1 transcript-is-truth, #2 single-string, #3 destination, #4 loop; see session notes.)
**Tooling:** `asr-bench --dump-tokens` (per-token TDT confidence) + `bench/analyze_confidence.py`.

## The question

The reframe rests entirely on one empirical claim we'd never checked: **is the TDT ASR's own per-token confidence informative about where it is wrong?** If yes, we can route expensive effort and surface trust *acoustically* — seeing the uncertainty that text-only cleanup is blind to. If no (errors are uniform or confidence is miscalibrated), the acoustic pillar collapses.

## Method

The TDT model already emits a per-token `confidence` (FluidAudio `TokenTiming.confidence`) — we'd been discarding it. Dumped it for every token, grouped subword tokens into words (min-confidence per word), aligned hyp words to the reference, labelled each correct / error, and measured **separation** (ROC-AUC of "low confidence ⇒ error") and **calibration** (accuracy within confidence bins). Corpora: synthetic over-fire (911 words), synthetic colliding (721), adversarial stress (381), and **real human audio** (328).

## Result: confirmed, strongly

| corpus | ROC-AUC (low conf detects error) | correct-word conf (median) | error-word conf (median) |
|---|---|---|---|
| over-fire (synthetic) | **0.96** | 1.00 | 0.62 |
| colliding (synthetic) | **0.88** | 1.00 | 0.79 |
| stress (synthetic) | **0.95** | 1.00 | 0.71 |
| **real human audio** | **0.80** | 1.00 | 0.97 |

**Calibration is monotonic and usable:** the ≥0.99 confidence bin is 97–100% correct across corpora; the <0.5 bin is 36–50% correct. High confidence really does mean "right."

**It lights up at exactly the hard cases.** The lowest-confidence words are the term-collision mishears text-only cleanup can't touch: `CRN`/`CRAN` (0.33), `SNCC`/`SNC` for Snyk (0.36–0.49), `think`/`thing` for ultrathink (0.42), `readies` for Redis (0.51), `Kates` for k8s (0.27), `Vithay`/`Nugst`/`Zodbi` for Vite/Nuxt/Zod (0.25–0.43).

**Even the worst adversarial case holds — barely.** The cases that should defeat confidence are clean-common-word mishears (you say "Numba", ASR confidently writes "number"). Measured directly:
- `Dino`→Deno: 5/5 below the correct-word floor (0.68–0.78)
- `desk`/`dusk`→Dask: 5/5 below floor (0.54–0.95)
- `number`→Numba: 4/4 below floor (0.83–0.96)

Every clean-word mishear came in **below the ~0.99 correct-word floor** — the model is measurably less certain even when it lands on a common word. The margin is *tighter* there (0.85–0.96 vs 0.99+), not the chasm seen for garble mishears, but the separation survives.

## Honest bounds

- **Real audio is weaker than synthetic** (AUC 0.80 vs 0.88–0.96) and has a **confidently-wrong tail**: some genuine errors score high (`sneak` for Snyk 0.95, `Maine` 0.89). Confidence is a strong-but-imperfect detector — a minority of errors will be confidently wrong and slip past any threshold. The reframe must tolerate this (which #2 "surface uncertainty, don't claim perfection" and #4 "personal prior catches the residual" already do).
- Single speaker for the real-audio arm; modest N; "error" labels carry some alignment/punctuation noise. The qualitative result (confidence localizes error, incl. the hard collisions) is robust; exact AUCs are not.
- This is the TDT's confidence on the raw transcript — it tells us *where the ASR is unsure*, which is what we need for routing/trust. It does not by itself resolve intent (that's what the other evidence terms are for).

## What this unlocks (the program, now grounded)

The pillar stands, so the dependent pieces are worth building:

- **#1 trunk (evidence combination):** confidence is a usable likelihood signal — we can weight the transcript by how much the acoustics actually support each span.
- **#2 surface (calibrated uncertainty):** with ≥0.99 ⇒ ~99% correct, a confidence threshold gives a *trustable* "check only the highlighted words" UX — flagging the rare-term mishears that are otherwise invisible. New metric: proofreading effort, not WER.
- **bet A (acoustic gating):** escalate to the heavy model only on low-confidence spans — most of an utterance is ≥0.99 and needs nothing.
- **#4 loop / bet B:** the confidently-wrong tail is exactly where a *personal prior* (your error history) should add separability beyond acoustics — the natural next experiment (the arm we deferred).

## Next experiment

Re-run the separation test with a **personal-prior arm**: does "this user's known error patterns / vocabulary" add discriminability on top of confidence, especially on the confidently-wrong tail? That tests bet B and feeds #1/#4.

## Reproduce

```bash
parleq-app/.build/debug/asr-bench --manifest bench/fixtures/manifest-colliding.json \
  --wav-dir bench/fixtures --paths batch --out /tmp/coll5-tok.json --dump-tokens /tmp/coll5-tokens.jsonl
bench/.venv/bin/python bench/analyze_confidence.py --tokens /tmp/coll5-tokens.jsonl --results /tmp/coll5-tok.json
# (repeat for over-fire / stress-colliding / real-audio manifests; --inspect shows token format)
```
