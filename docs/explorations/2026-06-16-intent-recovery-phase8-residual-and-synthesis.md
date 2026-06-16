# Intent-recovery program — Phase 8: the confident-near-homophone residual, and the synthesis

**Date:** 2026-06-16
**Status:** Final research result of the intent-recovery spike — resolves error-class 3 (confident near-homophones) and synthesizes the whole program. No app code changed. Uses `bench/llm_cleanup_probe.py` on the real recordings.

## The residual (class 3)

`Snyk`→`sneak`, `k8s`→`Kate's`: the model is *confidently* wrong because the term genuinely sounds like a real word. Acoustic confidence can't flag it (Phase 6: real Snyk mishears scored 0.95). Two priors beyond acoustics could resolve it — **sentence context** and **personal usage history**.

## Context (LLM) resolves it — at a precision cost

Ran the real cleanup prompt over the **real human recordings** (Vertex flash-lite, dict hint on):

- **`Snyk`→`sneak` recovered 3/3** from context ("run the **sneak** scan before you merge" → Snyk). The confident near-homophone confidence couldn't flag *is* resolvable from meaning.
- **Overall real-audio term recall 46% → 96%** (25/26) — context recovers nearly everything, across all three classes.
- **But it over-fires 2/18** on genuine-common over-fire clips (`crane`→CRAN, `radish`→Redis — ignoring "lifted the steel beams"/"garden salad"), the same context-blind over-fire as synthetic Phase 4a (~9–11%).

So the cleanup LLM Parleq **already runs for cloud users largely solves class 3** — but it is not free: it re-introduces over-fire on genuine common words, so it can't be trusted blindly (it needs the gate/escalation discipline).

## The local alternative: a usage-frequency personal prior

The privacy-preserving, no-heavy-model path. A noisy-channel decision for a confident word `w` that is a near-homophone of term `T`:

> decode `T` when  `P(heard w | T) · P(T)  >  P(heard w | w) · P(w)`,  i.e. usage ratio `P(T)/P(w) > 1/c`, where `c` = confusion rate (prob the model writes `w` when you said `T`).

Both quantities are *personal and local*: `c` is estimable from the user's own corrections; `P(T)/P(w)` is their usage history (dictionary + correction journal). **Grounded estimate from our data:** on the real Snyk clips the model wrote "sneak" 3/3 (c ≈ high), so the threshold `1/c` ≈ ~1.2 — meaning *any* user who says "Snyk" even slightly more than the word "sneak" should have it decoded as Snyk. For a developer (who says "Snyk" often and "sneak" ~never) the prior overwhelmingly favors the term. So a local usage-prior would recover class 3 for the users who care — **no cloud, no acoustics, no context model.** (Needs deployment data to validate the real usage ratios; principled but not yet empirically run.)

## Synthesis — the whole intent-recovery picture, validated on real audio

The reframe (`intent ≈ argmax P(intent | acoustics, transcript, personal, context)`) resolves into **three error classes, each with a matched handler**:

| class | example | handler | status (real audio) | needs heavy model? |
|---|---|---|---|---|
| 1. Compound split | `work tree`→worktree | deterministic join (Ph7) | recall 40%→84%, 0 false-join | **no** (text+dict) |
| 2. Clean-common-word mishear | `number`→Numba | confidence × dictionary (Ph6) | AUC 0.96, 100% recovery @ ~15% false-flag | **no** (local signals) |
| 3. Confident near-homophone | `Snyk`→`sneak` | context (LLM) **or** usage-prior | LLM 3/3; usage-prior principled | LLM yes / usage-prior **no** |

**The featherweight thesis is substantiated:** a 100%-local engine handles classes 1 and 2 outright with no heavy model (a deterministic join + a confidence×dictionary gate). Only class 3 needs more — and even that has a local answer (the usage-prior). So the heavy model (Gemma/cloud) is needed *only* for the class-3 residual the local usage-prior can't yet cover — which is exactly the "cheap local by default, escalate the genuinely-hard remainder" architecture the program set out to find.

**The over-fire/precision story** also resolves cleanly: classes 1 and 2 don't over-fire (join is dictionary-scoped; the confidence gate flags-not-replaces). The only over-fire source is the LLM resolver (class 3), mitigated by invoking/trusting it only on flagged (near-term) spans rather than blindly.

## Honest bounds (carried from the program)

- Single real speaker, modest N; synthetic systematically overstated false-flag rates and missed failure modes — real-audio is the gating reality (all headline numbers here are real-audio).
- The usage-prior (local class-3 path) is **principled but unvalidated** — it needs real usage data (deployment / a populated correction journal) to confirm the ratios.
- Class-2 false-flag (~15% real) and crude grapheme proximity want phonetic proximity + tuning before any product use.
- This is research, not a build. The honest scope of work to ship any of it is in the trunk consolidation (#1) and is maintainer-gated.

## Program status

Experimental arc **complete**: foundation (Ph5) + all three error classes characterized and solved/path-identified on real audio (Ph6/7/8). Remaining are **design/consolidation**, not experiments:
- **#1 TRUNK** — write the evidence-combination model + 3-class handler architecture into a spec (the capstone).
- **#2 SURFACE** — the calibrated-uncertainty "check only the flagged words" UX + trust/effort metric.
- **#4 LOOP** — productionizing the usage-prior from the correction journal (the local class-3 path).
- **#3 DESTINATION** — destination-conditioned cleanup.

## Reproduce

```bash
bench/.venv/bin/python bench/llm_cleanup_probe.py --results /tmp/human.json \
  --dictionary bench/dictionary-overfire.json --out /tmp/human-llm.jsonl
bench/.venv/bin/python bench/llm_cleanup_probe.py --results /tmp/stresshuman.json \
  --dictionary bench/dictionary-stress.json --out /tmp/stresshuman-llm.jsonl
# then: per-term raw-vs-cleaned recall, and term-insertion (over-fire) on the o* clips
```
