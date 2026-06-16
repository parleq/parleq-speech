# Intent-recovery Phase 9 — contextual-fit probe (RESULTS)

**Date:** 2026-06-16
**Status:** Experimental result. Tests whether **sentence ↔ dictionary-blurb similarity** is a local signal for error-class 3 (confident near-homophones) — the cheap on-device alternative to the cloud cleanup LLM. Design doc: `2026-06-16-intent-recovery-phase9-contextual-fit-design.md`. No app code changed; bench tooling only (`bench/analyze_contextual_fit.py`).

## The question

When the recognizer is *confidently* wrong because your term sounds like a real word (`Snyk`→"sneak"), acoustics can't flag it (Phase 6: real Snyk mishears scored ~0.95, like a correct word). Does the **rest of the sentence** disambiguate it? Concretely: is a term's blurb (e.g. Snyk = "security scanner") more similar to the surrounding words when the term was actually meant than when a common near-homophone was meant?

We measure separation as **AUC** — how reliably the similarity score tells *term-intended* from *common-word-intended* apart. 0.5 = coin-flip, 1.0 = perfect. The headline is the **confident slice** (model confidence ≥ 0.97): the genuine class-3 residual where acoustics are useless and context is the only local hope.

## Data

Real human recordings, single speaker. Two scorers: a free **keyword-overlap** baseline (zero model) and a tiny **sentence embedder** (`all-MiniLM-L6-v2`, ~80 MB, a stand-in for the on-device Apple `NLContextualEmbedding`). Each clip's context = the ASR hypothesis **minus the ambiguous target word** (so the score can't cheat by reading the misheard word itself).

- **Public terms** (CRAN/Snyk/Redis/k8s/worktree/ultrathink/E2E/Sonnet): 74 clips (34 original + 40 new), scored against two blurb sets — the **public** definition-blurbs (committed `bench/blurbs-overfire.json`) and the maintainer's **real** work-dictionary blurbs (git-ignored; authentic, and written for daily use *before* this probe — an independent blindness).
- **Proprietary terms**: 18 clips against the real blurbs, reported as an **anonymized aggregate only** (customer-identifying; never broken out per-term).

**Recording-integrity note:** the first recording session silently lost 34 clips — the mic dropped mid-session and produced full-length **−91 dB silent** WAVs (vs −28 dB for speech) that ASR transcribed to empty strings. Caught by a volume sweep, deleted, and re-recorded. The re-records came in ~15 dB quieter (~−42 dB) than the originals (~−27 dB) — still well above the silence floor and transcribed fine, but a mild audio-quality asymmetry to keep in mind.

## Results

**Separation AUC (embedder | keyword), all scored clips, then the confident class-3 slice:**

| arm | scorer | all clips | confident slice (conf ≥ 0.97) | argmax top-1 |
|---|---|---|---|---|
| Public clips vs **public** blurbs | embedder | **0.910** (n=57) | 0.729 (n=30: 6 term/24 common) | 48% (chance 12%) |
| Public clips vs public blurbs | keyword | 0.638 | 0.500 | — |
| Public clips vs **real** blurbs | embedder | 0.875 (n=45) | **0.873** (n=25: 7 term/18 common) | 65% (chance 14%) |
| Public clips vs real blurbs | keyword | 0.587 | 0.500 | — |
| **Proprietary** (aggregate) vs real blurbs | embedder | 0.861 (n=12) | — (0 term clips in slice) | 67% (chance 14%) |

## What this says

1. **The contextual-fit signal is real and replicates at larger N — but it's moderate, not a clean solver.** The embedder separates term-from-common at **0.86–0.91 overall** across all three arms, and at **0.73–0.87 on the hard confident slice**. (The Phase-8/early-read flashes of 0.94–0.97 were small-N optimism; they regress to this honest range as N grows.) So context is a *useful local contributor* to class 3, not a standalone replacement for the cloud LLM (which got `Snyk` 3/3 in Phase 8).

2. **Richer, authentic blurbs help on the hard slice** — confident-slice embedder **0.873 (real blurbs) vs 0.729 (public blurbs)**. The dual-track bet pays off: a user's own descriptive `context` field is worth more than a terse definition. This is directly actionable — encourage real `context` blurbs in the dictionary.

3. **The free, model-less keyword overlap does not work** — 0.59–0.64 overall and a flat **0.500 on the confident slice** (blurbs are too short for literal word overlap to bite). So a local class-3 resolver needs at least the tiny embedder. That's still featherweight (on-device `NLContextualEmbedding`, no heavy LLM), but "zero model" is off the table.

4. **The argmax control corroborates real discrimination** — context ranks the *correct* blurb #1 in 48–67% of clips versus ~12–14% chance (4–5×). So when it fires, it's matching the *right* blurb, not just any technical-sounding one — defeating the "term speech is merely more technical" confound.

5. **Proprietary terms behave like the public ones** (aggregate embedder separation 0.861, argmax 67%) — the signal isn't an artifact of the public term set. (No confident-slice number: those term clips were either low-confidence mishears — class 2, which acoustics already catch — or transcribed cleanly, so none landed in the class-3 slice.)

## Verdict for the trunk

**Contextual-fit is a viable *featherweight local* signal for class 3, but a moderate one best used in combination, not alone.** Updated picture of the class-3 (confident near-homophone) handler:

- **Local, no heavy model:** usage-prior (Phase 8, principled) **+ contextual-fit (this probe, ~0.87 on the hard slice with rich blurbs)**. Two weak-to-moderate local signals that should be *combined* (and that benefit from good user `context` blurbs).
- **Escalation:** the cloud/Gemma cleanup LLM remains the strongest class-3 resolver (Phase 8: 3/3) for the residual the local signals can't settle.

So the featherweight thesis holds with a refinement: classes 1–2 are solidly local; **class 3 has a *real but moderate* local path** (usage-prior + contextual-fit via a tiny embedder), with the heavy model reserved for the genuinely ambiguous remainder. "Fully local class 3" is plausible but unproven — the honest claim is "local signals materially shrink the class-3 residual the LLM must handle."

## Honest bounds

- Single speaker, modest N (6–7 term clips in the confident slices); treat the confident-slice AUCs as directional, not precise.
- The re-recorded clips are ~15 dB quieter than the originals, which may slightly depress ASR/context quality in the new data.
- `all-MiniLM-L6-v2` is a *proxy* for the on-device embedder, not the shipped primitive — it bounds feasibility, doesn't certify it.
- Proprietary terms are anonymized aggregates by design — not independently auditable here.
- Research, not a build. Any resolver is maintainer-gated productionization.

## Reproduce

```bash
# transcribe (real audio) → tokens + results, split public vs proprietary, run 3 arms
./parleq-app/.build/debug/asr-bench --manifest bench/fixtures/manifest-contextfit-human.json \
  --wav-dir bench/fixtures-human --paths batch --dump-tokens /tmp/contextfit-tokens.jsonl --out /tmp/contextfit.json
# (merge with /tmp/human.{json,tokens}, split on ^[co]5 for proprietary; see session notes)
bench/.venv/bin/python bench/analyze_contextual_fit.py --tokens /tmp/pub-tokens.jsonl \
  --results /tmp/pub.json --blurbs bench/dictionary-work.json
```
