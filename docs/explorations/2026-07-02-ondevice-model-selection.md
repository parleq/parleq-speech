# On-device cleanup model selection — benchmark, prompt tuning, and cloud validation

**Date:** 2026-07-02 → 07-03 · **Status:** research complete; productization (a user-selectable second on-device model) in progress on `feat/on-device-model-selection`.

## Summary / decisions

Parleq's on-device cleanup tier shipped with a single model (Gemma 4 E4B, ~7 GB peak, needs 12 GB+ RAM). RAM is the number-one on-device adoption blocker, so we searched for a lighter model that stays "close enough" on cleanup quality to open 8 GB Macs. Outcome:

- **Ship a second, lighter on-device model: `Qwen3-4B-Instruct-2507` (4-bit).** ~3.9 GB peak footprint (~45% less than Gemma E4B), *faster*, and quality close to Gemma on the cleanup task — with a genuinely lighter RAM floor (~8 GB tier).
- **Keep Gemma 4 E4B as the default / quality tier.** After tuning, Qwen is a strong lightweight option but not a quality *replacement* — Gemma still leads on hard ASR corrections, technical terms, and world knowledge.
- **One shared, firmed-up cleanup prompt** (the "BOTH" prompt below) replaces the previous `SystemPrompts.baseCleanup`, validated safe from the smallest on-device model up through all cloud providers.
- **Llama-3.2-3B was evaluated and dropped** — marginally lighter than Qwen but measurably worse, with an unpromptable self-correction defect (see Phase 2).

---

## Phase 1 — model benchmark (real in-process Swift/MLX cleanup path)

A prior on-device model evaluation (May–June 2026) had tested several candidates for the cleanup task via an Ollama prototype harness and concluded "no smaller model met the cleanup bar → the 12 GB gate is justified" — **except `Qwen3-4B-Instruct-2507` was flagged as an untested cleanup sweet spot.** This phase validated candidates in the *actual* in-process Swift/MLX cleanup path (not Ollama), via a `PARLEQ_LOCAL_CHECKPOINT` env override on `LocalModelDefaults.checkpoint` plus the app's eval harness (a `@@CLEANUP@@` sentinel routes to the real `SystemPrompts.cleanup()`), over 12 hard synthetic fixtures.

**Results (12 cases; warm latency = cases 2–N; peak `phys_footprint`):**

| model | cleanup quality | peak footprint | avg total | avg TTFT |
|---|---|---|---|---|
| **Gemma 4 E4B** (baseline) | best | 7040 MB | 751 ms | 135 ms |
| **Qwen3-4B-Instruct-2507** | close to baseline — best **fidelity** | **3938 MB (~45% less)** | **467 ms** | **102 ms** |
| Llama-3.2-3B-Instruct | close — best formatting/caps; lightest | 3466 MB | 429 ms | 121 ms |
| Gemma 3 4B QAT | ✗ weak (leaves lowercase/unpunctuated; botched a self-correction) | 4963 MB | 2525 ms | 2043 ms |
| Phi-4-mini | ✗ paraphrases + DROPS content | 4164 MB | 1529 ms | 1057 ms |

**Verdict:** Qwen3-4B-Instruct-2507 is the viable lighter option — quality close to Gemma, ~45% less memory, and faster. (3.9 GB peak > the ~2.5 GB weights floor because MLX's Metal GPU buffer pool counts against `phys_footprint` on unified memory — the same reason Gemma shows ~7 GB vs its ~5.5 GB weights floor; the GPU-cache cap bounds the visible peak.) Qwen and Llama both loaded through the **stock `mlx-swift-lm` registry** (`qwen3` / `llama`) with **no vendoring** — unlike Gemma 4, which needs the in-tree `VendoredGemma4Text.swift` KV-shared-layer patch. That registry breadth is the key enabler: adding a model is a checkpoint swap, not a new Swift model class.

---

## Phase 2 — prompt tuning (does a firmed-up prompt fix the lighter models' soft spots?)

The 12-case eyeball surfaced two model-specific soft spots:
- **Qwen3-4B:** occasionally skips sentence-start **capitalization** / **final punctuation**. Fidelity already excellent.
- **Llama-3.2-3B:** mild **rewording/reordering** (reordered a list, `deploy→deployment`, dropped a preamble) and a **self-correction** miss (kept the retracted name instead of the corrected one).

We drafted two surgical edits to the shared prompt — a **CAPS firm-up** (a first-char/last-char postcondition plus tightened caps/punctuation bullets) and a **FIDELITY firm-up** (turn the abstract "don't paraphrase" into a positive "every word, in order, changed only where a rule requires" invariant, and make self-correction *positional*: keep the version spoken *after* the cue) — and tested the 2×2 matrix (V0 / +CAPS / +FIDELITY / +BOTH) against both models over an expanded **58-case synthetic** corpus, scored by a blind cloud LLM-judge (pairwise vs the Gemma-V0 reference) plus deterministic caps/punctuation metrics.

**Key findings:**
- **The two edits interact — you need both.** CAPS fixes caps/punctuation cleanly (Qwen sentence-start 59% → 98%, final-punctuation 64% → 98%) at zero fidelity cost. **FIDELITY-alone backfires** on small models — makes them so cautious they echo the raw transcript unformatted. **BOTH** formats reliably *and* has the lowest fidelity-violation rate. → **one shared "BOTH" prompt**, not per-model.
- **Qwen3-4B-BOTH is a strong lightweight #2, not a Gemma replacement.** vs the Gemma reference: ties ~59%, worse ~33%, better ~9%. Its residual losses cluster in the hard-ASR / world-knowledge / ITN tail (e.g. `SQL`→"sequel", `every 30 seconds`→"thirty seconds") — a 4B capability ceiling, not a prompt problem.
- **Llama-3.2-3B dropped.** After tuning it lagged Qwen (worse ~59% vs Gemma), is only ~470 MB lighter (same 8 GB tier), and has an **unpromptable defect**: it resolves "cc Rob, I mean Rita" to the *wrong* (retracted) name even with the fidelity fix. The 12-case "best formatting" read did not survive the 58-case corpus (its baseline caps/punctuation was as weak as Qwen's).

---

## Phase 3 — flagship + cloud validation (is the BOTH prompt safe app-wide?)

`SystemPrompts.baseCleanup` is shared by every provider, so promoting the firm-up required confirming it doesn't regress the strong models.

- **Flagship (Gemma 4 E4B):** BOTH vs V0 — identical mechanical caps/punctuation, zero echo-raw, judge net-positive (6 better / 3 worse), and *fewer* fidelity violations than V0. The FIDELITY-alone echo failure is small-model-specific and does not reproduce.
- **Cloud (within-model A/B on the three providers the app uses — Gemini 2.5 Flash, Claude Haiku 4.5, GPT-OSS 120b — faithful to the app's real request settings):** net-neutral-to-positive on all three; mechanical caps/punctuation flat; zero echo-raw; the first-position self-correction over-conservatism seen on Gemma did **not** reproduce on cloud (GPT-OSS BOTH actually *fixed* it). The only observable downside is GPT-OSS omitting some discretionary introductory-phrase commas (cosmetic; still fully punctuated).

**Verdict:** BOTH is safe to promote to the universal `baseCleanup`. Its benefit is concentrated on the small on-device models (the cloud models were already near-maxed); the promotion is net-neutral-to-positive elsewhere and architecturally simpler (one prompt, no per-path branch).

---

## Methodology notes (what made the eval trustworthy)

- **Synthetic fixtures only** (house data-hygiene rule — no real dictations in the cases file).
- **No teaching-to-the-test:** the prompt's illustrative examples were kept disjoint from the eval fixtures (a fixture never shares its distinguishing token with a prompt example), so the fixtures measure generalization, not memorization.
- **Blind pairwise LLM-judge** (randomized A/B, model identity stripped) with a separate fidelity-violation flag.
- **Judge-family cross-check:** the judge (Gemini) and the on-device reference (Gemma) are both Google models; on the one close decision, a different-family (Claude) blind re-judgment caught that ~3/10 disagreements were the Gemini judge scoring byte-identical text differently — a same-family affinity artifact that would otherwise have flipped a conclusion.
- **Deterministic metrics alongside the judge:** first-char-uppercase and terminal-punctuation rates quantified the caps/punctuation soft spot independent of the LLM-judge.

## Caveats & follow-ups

- The 58-case corpus is synthetic; it differentiates models well but isn't a real-usage distribution. Real-world quality remains cloud-led (the standing posture: cloud = quality default, local = privacy/offline/zero-cost tier).
- **Qwen's exact RAM floor is pending a real 8 GB-Mac footprint measurement** (with the GPU-cache cap applied). The dev-machine peak was 3.9 GB; the productization uses an 8 GB floor with the 8 GB tier treated as "cautioned."
- Some of Qwen's residual losses (technical ITN, specific terms) may be addressable later via the user dictionary / vocabulary biasing rather than the model.
- Confirm the `-2507` checkpoint honors `enable_thinking:false` (it is a non-thinking Instruct variant, so likely moot).

## Artifacts

Spike scaffolding and per-case outputs live on the `model-spike` branch under `parleq-app/spike/` (`cleanup-cases.json`, the 58-case corpus, `prompt-{v0,caps,fidelity,both}.txt`, `out-*.json`, `out-cloud-*.json`, the judge scripts, and summaries). Prior single-model footprint/quality findings are in the earlier on-device model research memos in this directory.
