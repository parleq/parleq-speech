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
| personal usage | P(term) vs P(common word) for this user | dictionary + correction journal | **[needs real data, Ph10]** a *data-free* (frequency proxy) usage-prior is non-discriminative for class 3 — the mishear is itself a common word, so frequency is blind. Only a TRUE per-user ratio from the correction journal could help; deployment-data prerequisite, not a bench result |
| contextual fit | utterance ↔ term's context blurb similarity | dictionary `context` field + cheap local embedder/keyword overlap | **[moderate, Ph9]** tiny embedder separates term/common at ~0.87 on the confident slice with rich blurbs (keyword overlap fails); real `context` blurbs > terse ones; a useful local *contributor* to class 3, not a standalone solver |
| context (heavy) | full sentence understanding | cleanup LLM | **[validated]** recovers Snyk 3/3, recall 46→96% real, but over-fires 2/18 (Ph8/4a) |

## The error taxonomy → matched handlers

Every term-recovery falls into one of three classes, each with a handler of escalating cost:

**Class 1 — compound split** (`work tree`→worktree). The model heard it right, didn't join. **Handler: deterministic compound-join** — match a term's spoken form (camelCase split + aliases) in the transcript, join to canonical. Local, no acoustics, dictionary-scoped (can't over-fire to a term the user doesn't have). **[validated Ph7]** recall 40→84%, 0 false-joins, real-audio-robust. **[Ph14 gap → Ph15 FIXED]** the joiner missed acronym-letter-splits with digit homophones (`E to E`→`E2E`, the most common confident error, 6/14); Phase 15 added digit-homophone acronym forms (`2`→"two"/"to") — **E2E now recovers, 0 false-joins**, and it correctly leaves `k8s`→"Kate's" *mishears* to class-3 (clean boundary: splits→join, mishears→context).

**Class 2 — clean-common-word mishear** (`number`→Numba). The model wrote a common word but was *measurably unsure*. **Handler: confidence × dictionary gate** — a word near a user term with confidence below the correct-word floor (~0.97) ⇒ recover toward the term; near a term but *high* confidence ⇒ leave it (it's the genuine common word — this is simultaneously the over-fire fix). Local. **[validated Ph6]** real-audio AUC 0.96, 100% recovery @ ~15% false-flag.

**Class 3 — confident near-homophone** (`Snyk`→`sneak`). Confidently wrong; acoustics useless. **Handler (local):** *contextual fit* (utterance matches the term's context blurb) — the workhorse — with an **abstain-and-escalate** band. **Handler (escalation):** the cleanup LLM's full context. **[Ph8/9/10]** LLM validated (3/3, Ph8); contextual-fit is a *moderate* local signal (~0.73–0.87 on the confident slice, richer blurbs better — Ph9); the **personal usage-prior does NOT contribute without real per-user data** (Ph10: a frequency-based prior is structurally blind here because the mishear is *itself* a common word — only true personal usage or context breaks it). Net: context-led local handling clears ~56% of confident class-3 error-free and escalates ~44% to the LLM (directional, small N).

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

**Featherweight (100%-local) engine = steps 1, 2, 3b, 4.** No heavy model. The heavy model (Gemma/cloud) is invoked **only** for step 3c — the class-3 residual local context can't resolve (~44% of confident class-3, Ph10). This is the "cheap-local by default, escalate only the genuinely hard remainder" architecture the program set out to find, and classes 1–2 (the bulk) are validated fully local. **Phase 10 correction:** step **3a (usage-prior) is struck from the data-free engine** — a frequency-based usage-prior is non-discriminative for class 3 (the mishear is itself a common word); it returns only if a *true* per-user usage ratio becomes available from a populated correction journal. So the data-free class-3 local handler is **3b (contextual-fit) alone**, abstaining-and-escalating the rest.

## The surface (#2): uncertainty as a first-class output

Because confidence is calibrated (≥0.99 ⇒ ~99% correct, Ph5), the engine can mark *what to double-check* rather than forcing the user to re-read everything. New metric for evaluation: **proofreading effort / trust** (fraction of output the user must verify; errors caught vs missed at a confidence threshold) — not WER. This is the most original *product* thesis in the program and is enabled by, not separate from, the trunk.

**[measured, Ph11→12]** `...phase12-trust-metric.md`: re-reading the lowest-confidence **5%** of words catches **38%** of errors (**7.5× over random**); 10%→50%. Big, cheap value at the low-effort end. The curve's **long tail** (catching 100% needs ~50% re-read) is the **confident** errors — and those are exactly **class-1 compound splits + class-3 near-homophones**, i.e. the recovery handlers' job. **Closure:** the trust surface flags the *unsure* errors; the handlers fix the *confident* ones; together they cover the space. Ship the surface + pair it with the class-1/3 handlers; report "re-read X% → catch Y%", not WER.

## Destination conditioning (#3)

Destination is a conditioning prior on intent: clean-for-code ≠ clean-for-chat ≠ clean-for-doc (number formatting, casing, symbol expansion all shift). A late-stage, additive conditioning input once the core exists. **[feasible, Ph17]** `...phase17-destination.md`: conditioning the cleanup prompt on destination produces appropriately different output (6/8 utterances diverge, 92% of expected markers) — but the value is in **formatting/tone** (chat markdown, code casing/flags/framing, email greeting), not number/symbol normalization (those are correctly destination-*invariant*). Cheap, additive prompt lever, no new model/network hop; maps onto the **existing per-app preset mechanism** (`preset_app_defaults`) — a destination/app carries a formatting profile folded into the same single cleanup call.

## What's validated vs. what needs building

- **Validated on real audio:** confidence localizes error (Ph5); class-1 join (Ph7); class-2 confidence×dictionary (Ph6); class-3 via LLM context (Ph8); contextual-fit as a moderate local class-3 signal (Ph9); phonetic trigger (Ph11); the trust surface (Ph12); **error-space coverage — the 3 classes + surface account for ~100% of real errors, ≈0 genuinely-uncovered confident residual (Ph14)**; **the full local pipeline end-to-end recovers 72–75% of dict terms with NO LLM on the hot path (Ph18; LLM ceiling 89%)**; destination conditioning feasible (Ph17).
- **The small-model question (Ph16/18/19):** a custom model to *beat the cleanup LLM* — **no** (Ph16, accuracy headroom ≈0). A small *posterior-conditioned ASR-correction* model to **approximate the LLM's dictionary-aware correction LOCALLY and skip an LLM pass per dictation — motivated, now quantified** (Ph18/19). The rule stack tuned to its frontier (Ph19, best config: context-gate every recovery, near 0.7, floor 0.90) tops out at **~70% term recovery / ≥1 over-fire / 4.8% WER** and **structurally cannot reach the LLM's 89% / 0 / 2.1% corner** — no threshold combo hits 0 over-fire. So the **decision is a product-bar question:** if ~70% local recovery (no LLM, instant, raw-beating WER) is good enough as the fast default → **ship the tuned rules, no model**; if the bar is ≥~85% at ~0 over-fire → train a learned corrector (target: close a ~20pt recall gap), noting the **candidate-gen limit** (Ph11: a constrained corrector can't recover terms ASR mangles beyond grapheme+phonetic reach — only open-vocab gen / the LLM can) caps it below the LLM. **[POC tested, Ph20]** a flan-t5-small dict-conditioned corrector trains easily and is *excellent in-distribution* (95.9% recovery / 1.1% WER on synthetic) but **fails to transfer to real audio (42% on the real clips, ~raw)** — it memorized synthetic TTS confusion patterns, not real ASR ones. **The model is the easy part; the wall is DATA.** Verdict: don't build it on synthetic — it's gated on real `(raw→corrected)` pairs from the production data flywheel (`CorrectionJournal`/`LearnedStore` + LLM distillation), the *same* gate as the usage-prior (Ph10). Architecture correction: rules handle the deterministic classes (the spike model was *worse* than the join on class-1); a learned model is only for the hard class-3 residual, on real data.
- **Principled, needs data/build:** class-3 local **usage-prior is non-discriminative without real per-user data** (Ph10); the acronym-join extension shipped in Ph15; the **learned local corrector** (Ph18, needs correction-journal data — which the LLM dictionary-auto-build loop produces); the app-side uncertainty surface + destination profiles via presets.
- **Ruled out earlier:** competitor-CTC-margin gate (Ph1); blanket frequency suppression as a universal fix (Ph4c); a data-free (frequency) usage-prior for class 3 (Ph10).

## Open questions / next experiments (post-trunk)

1. **Contextual-fit probe** — ~~does utterance ↔ dictionary-context-blurb similarity discriminate class 3?~~ **ANSWERED (Phase 9, `...phase9-contextual-fit.md`): yes, moderately.** A tiny sentence embedder separates term- from common-intended at ~0.86–0.91 overall and ~0.73–0.87 on the confident class-3 slice (richer real blurbs → 0.87; terse blurbs → 0.73). Free keyword overlap fails (0.50 on the slice) — the embedder is required, but it's still featherweight (on-device `NLContextualEmbedding`, no heavy LLM). Verdict: a real but *moderate* local class-3 signal — escalate the residual to the LLM. Actionable side-finding: encourage users to write descriptive dictionary `context` blurbs (they materially help). **Follow-on ANSWERED (Phase 10, `...phase10-combine-residual.md`):** combining with the usage-prior does NOT help absent real per-user data — a frequency-based usage-prior is structurally blind to class 3 (the mishear is itself a common word). Contextual-fit is the local workhorse; context-led local handling clears ~56% of confident class-3 error-free and escalates ~44% to the LLM. New open follow-on: **a *true* per-user usage-prior from a populated correction journal** (deployment-data prerequisite), and **phonetic-aware triggering + richer blurbs** to push contextual-fit further.
2. **Usage-prior validation** — needs real usage ratios (deployment / populated journal).
3. **Trust-metric harness** — ~~define + measure proofreading-effort~~ **DONE (Phase 12, `bench/trust_metric.py`):** re-read 5%→catch 38% (7.5× random), 10%→50%; long tail = confident class-1/3 errors. Open: a normalized (ITN/casing-folded) variant to strip WER alignment noise; measure on *ordinary* (non-adversarial) dictation where the surface should look even better; per-speaker recalibration.
4. **Phonetic proximity** — ~~replace grapheme Levenshtein in the trigger~~ **ANSWERED (Phase 11, `...phase11-phonetic-trigger.md`): add it as an OR-clause, don't replace.** A near-exact phonetic (Metaphone) match OR'd with the grapheme gate recovers the divergent-spelling near-homophones grapheme misses (`Snyk`↔"sync", grapheme 0.50 → phonetic 1.00 — the Phase-3 candidate-gen gap) at **zero added spurious-fire cost** (trigger recall 79%→83%). Strictly dominant; the cheapest win in the program. Phonetic *alone* is worse (lower recall) — it's a complement, not a replacement. Open: double-metaphone / learned phonetic distance for the residual ~17% still missed by both gates.

## Honest bounds (carried from the whole program)

- All headline numbers are **real-audio, single speaker, modest N**; synthetic systematically overstated false-flag rates and missed failure modes — real audio is the gating reality.
- This is a research synthesis, not a shipping design. Productionizing any handler (esp. owning the rescorer per #100, and the local priors) is maintainer-gated work with real surface area.
- The local class-3 path (usage-prior + contextual-fit) is the program's most promising-but-least-validated claim — the highest-value thing to test next.

## Phase docs consolidated here

`...phase1-diagnosis`, `...phase2-corpus`, `...phase3-gate-prototype`, `...phase4-llm-leg`, `...phase4-real-audio`, `...phase4-threshold-stress`, `...phase5-confidence-foundation`, `...phase6-personal-prior`, `...phase7-compound-join`, `...phase8-residual-and-synthesis`, and the `#100` over-fire summary.
