# Intent-recovery — the trunk: an evidence-combining, uncertainty-aware dictation cleanup architecture

**Date:** 2026-06-16
**Status:** Capstone design spec for the intent-recovery program (consolidates Phases 5–8 + the #100 over-fire work). **Design, not a build** — the shipping decision is maintainer-gated. All component claims below are tagged with their empirical status.

## The reframe (#1)

Stop treating dictation cleanup as *repairing a transcript*. Treat it as **recovering intent from a lossy channel**, combining evidence under uncertainty:

> **intent ≈ argmax P(intent | acoustics, transcript, personal history, destination)**

The transcript is one lossy view (a prior), not ground truth. The model's **acoustic confidence** is the likelihood. The user's **dictionary + usage history** is a personal prior. The **destination** is a conditioning prior. The output is intent **plus calibrated uncertainty** — the system says what it's unsure of instead of silently guessing.

## Evidence terms (what we combine)

| term | signal | source | empirical status |
|---|---|---|---|
| acoustic confidence | per-token TDT `confidence` | already emitted, was discarded | **[validated]** localizes error: AUC 0.80 real / 0.88–0.96 synth, calibrated (Ph5) |
| dictionary proximity | grapheme/phonetic nearness to a user term | dictionary | **[validated]** as the *trigger* (Ph6); over-fires alone (Ph1/4c) |
| personal usage | P(term) vs P(common word) for this user | dictionary + correction journal | **[principled]** noisy-channel; needs deployment data (Ph8) |
| contextual fit | utterance ↔ term's context blurb similarity | dictionary `context` field + cheap local embedder/keyword overlap | **[moderate, Ph9]** tiny embedder separates term/common at ~0.87 on the confident slice with rich blurbs (keyword overlap fails); real `context` blurbs > terse ones; a useful local *contributor* to class 3, not a standalone solver |
| context (heavy) | full sentence understanding | cleanup LLM | **[validated]** recovers Snyk 3/3, recall 46→96% real, but over-fires 2/18 (Ph8/4a) |

## The error taxonomy → matched handlers

Every term-recovery falls into one of three classes, each with a handler of escalating cost:

**Class 1 — compound split** (`work tree`→worktree). The model heard it right, didn't join. **Handler: deterministic compound-join** — match a term's spoken form (camelCase split + aliases) in the transcript, join to canonical. Local, no acoustics, dictionary-scoped (can't over-fire to a term the user doesn't have). **[validated Ph7]** recall 40→84%, 0 false-joins, real-audio-robust.

**Class 2 — clean-common-word mishear** (`number`→Numba). The model wrote a common word but was *measurably unsure*. **Handler: confidence × dictionary gate** — a word near a user term with confidence below the correct-word floor (~0.97) ⇒ recover toward the term; near a term but *high* confidence ⇒ leave it (it's the genuine common word — this is simultaneously the over-fire fix). Local. **[validated Ph6]** real-audio AUC 0.96, 100% recovery @ ~15% false-flag.

**Class 3 — confident near-homophone** (`Snyk`→`sneak`). Confidently wrong; acoustics useless. **Handler (local, preferred):** resolve with the *personal usage prior* (decode the term when usage ratio > 1/confusion-rate) **and/or** *contextual fit* (utterance matches the term's context blurb). **Handler (escalation):** the cleanup LLM's full context. **[Ph8]** LLM validated (3/3); local path principled/proposed.

## Architecture (the pipeline)

```
audio
 └─ TDT ASR ──► transcript + per-token confidence + timings   (+ CTC posterior, optional)
      │
      ▼
 1. compound-join        (deterministic, dictionary-scoped)      ── class 1, local
      ▼
 2. confidence×dictionary gate                                   ── class 2, local
      │   near-term & low-conf  → recover toward term
      │   near-term & high-conf → candidate class 3 (don't resolve yet)
      ▼
 3. class-3 resolution of the high-conf near-term candidates:
      a. usage-prior strongly favors term?      → recover        ── local
      b. contextual-fit matches term's blurb?    → recover        ── local
      c. else, if heavy model available          → escalate (LLM context)
         else                                    → keep common word (safe default)
      ▼
 4. calibrated-uncertainty surface (#2):
      flag low-confidence + unresolved class-3 spans for the user to glance at
      ▼
 cleaned text + per-span trust annotation
```

**Featherweight (100%-local) engine = steps 1, 2, 3a, 3b, 4.** No heavy model. The heavy model (Gemma/cloud) is invoked **only** for step 3c — the class-3 residual the local priors can't resolve. This is the "cheap-local by default, escalate only the genuinely hard remainder" architecture the program set out to find, and classes 1–2 (the bulk) are validated fully local.

## The surface (#2): uncertainty as a first-class output

Because confidence is calibrated (≥0.99 ⇒ ~99% correct, Ph5), the engine can mark *what to double-check* rather than forcing the user to re-read everything. New metric for evaluation: **proofreading effort / trust** (fraction of output the user must verify; errors caught vs missed at a confidence threshold) — not WER. This is the most original *product* thesis in the program and is enabled by, not separate from, the trunk.

## Destination conditioning (#3)

Destination is a conditioning prior on intent: clean-for-code ≠ clean-for-chat ≠ clean-for-doc (number formatting, casing, symbol expansion all shift). A late-stage, additive conditioning input once the core exists. (Bridges to the private routing vision — keep that framing out of public artifacts.)

## What's validated vs. what needs building

- **Validated on real audio:** confidence localizes error (Ph5); class-1 join (Ph7); class-2 confidence×dictionary (Ph6); class-3 via LLM context (Ph8).
- **Principled, needs data/build:** class-3 local usage-prior (needs a populated correction journal); contextual-fit (needs the experiment below); the uncertainty surface + trust metric; destination conditioning.
- **Ruled out earlier:** competitor-CTC-margin gate (Ph1); blanket frequency suppression as a universal fix (Ph4c).

## Open questions / next experiments (post-trunk)

1. **Contextual-fit probe** — ~~does utterance ↔ dictionary-context-blurb similarity discriminate class 3?~~ **ANSWERED (Phase 9, `...phase9-contextual-fit.md`): yes, moderately.** A tiny sentence embedder separates term- from common-intended at ~0.86–0.91 overall and ~0.73–0.87 on the confident class-3 slice (richer real blurbs → 0.87; terse blurbs → 0.73). Free keyword overlap fails (0.50 on the slice) — the embedder is required, but it's still featherweight (on-device `NLContextualEmbedding`, no heavy LLM). Verdict: a real but *moderate* local class-3 signal — **combine with the usage-prior** rather than treat as a standalone solver; escalate the residual to the LLM. Actionable side-finding: encourage users to write descriptive dictionary `context` blurbs (they materially help). Open follow-on: **combine usage-prior + contextual-fit and measure the residual the LLM still must handle.**
2. **Usage-prior validation** — needs real usage ratios (deployment / populated journal).
3. **Trust-metric harness** — define + measure proofreading-effort on real dictation.
4. **Phonetic proximity** — replace grapheme Levenshtein in the trigger to widen class-2/3 coverage and cut class-2 false-flags.

## Honest bounds (carried from the whole program)

- All headline numbers are **real-audio, single speaker, modest N**; synthetic systematically overstated false-flag rates and missed failure modes — real audio is the gating reality.
- This is a research synthesis, not a shipping design. Productionizing any handler (esp. owning the rescorer per #100, and the local priors) is maintainer-gated work with real surface area.
- The local class-3 path (usage-prior + contextual-fit) is the program's most promising-but-least-validated claim — the highest-value thing to test next.

## Phase docs consolidated here

`...phase1-diagnosis`, `...phase2-corpus`, `...phase3-gate-prototype`, `...phase4-llm-leg`, `...phase4-real-audio`, `...phase4-threshold-stress`, `...phase5-confidence-foundation`, `...phase6-personal-prior`, `...phase7-compound-join`, `...phase8-residual-and-synthesis`, and the `#100` over-fire summary.
