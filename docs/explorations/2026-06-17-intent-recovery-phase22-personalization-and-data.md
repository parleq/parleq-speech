# Intent-recovery Phase 22 — incremental personalization (LoRA) + the data recipe for a shippable base

**Date:** 2026-06-17
**Status:** Two results that define the *build path* for the featherweight corrector: (1) a personalization spike — does on-device adaptation need a full retrain, or a small supplement? and (2) a survey of public datasets that could bootstrap the general base. Spike artifacts local in `bench/spike/` (git-ignored). Single speaker, tiny test (12/12) — directional.

## Part 1 — Personalization: supplement, don't retrain

Two-tier model: a shared **base** (general correction skill) + a **personal** layer per user. Question: full retrain each time, or an incremental supplement — and can it be *free* (inference-time conditioning) vs *trained* (a small adapter)?

Built four systems, evaluated on the 24 held-out real clips:

| system | recovery (12 c*) | over-fire (12 o*) | WER |
|---|---|---|---|
| BASE (multivoice-only, no user data) | 50% | 33% | 10.3% |
| BASE + conditioning (4-shot, no training) | 50% | 25% | 8.7% |
| **BASE + LoRA (adapter on user data)** | 58% | **8%** | **6.2%** |
| FULL fine-tune (all data) | **75%** | 25% | 7.0% |

**LoRA adapter: 2.77 MB — 688K trainable params (0.89% of the 77M base).**

### Findings

1. **Incremental personalization works and is tiny.** A **2.77 MB** LoRA overlay, base frozen, trained in minutes — no full retrain. This is the mechanism for "the model gets smarter at *your* speech over time": periodically refresh the adapter from the correction journal; the shared base never changes. Catastrophic forgetting is structurally avoided (base frozen).
2. **On a small model, free conditioning does NOT suffice.** BASE+conditioning gave **zero** recovery gain over BASE — flan-t5-small can't do in-context learning well (512-token window; it treats the few-shot prefix as noise). So for a *featherweight* model the personal tier must be a **trained LoRA refresh**, not prompt-conditioning. (A larger model could lean on conditioning — but that defeats the size goal.)
3. **LoRA is the precision winner; full-finetune is the recall winner.** LoRA over-fires **8%** vs full's 25% (and BASE's 33%) — training on the user's *real* confusion teaches it what **not** to fire on, directly attacking Ph21's over-fire weakness. Full-finetune recovers more terms (75% vs 58%) but hallucinates 3× more. The recall gap is mostly because **the base here was weak** (multivoice-only ~3k synthetic rows) — a strong base (Part 2) should lift LoRA's recall while keeping its precision.
4. **Shared recall ceiling (~75%) from candidate-gen** (Ph11 again): `k8s`→"Kate's"/"Cates" is too phonetically distant — *all four* systems (incl. full + LLM) miss it. A seq2seq corrector can't bridge it without a stronger dictionary/phonetic prior.

### Architecture verdict
**Frozen shared base + a small per-user LoRA adapter, refreshed periodically from the correction journal.** Free conditioning is a bonus for new terms but not sufficient alone on a small model. The rule stack remains the precision safety net / fallback. This is "one model that gets smarter over time" with a 2.77 MB supplement, never a from-scratch retrain.

## Part 2 — Datasets to bootstrap the general base

We have almost no data of our own; the spike's weak base (synthetic only) is why recall capped at 58–75%. Public data can build a much stronger base for the *general* "correct ASR near-misses" skill. (License matters — this may ship in a product.)

### Ready-made (ASR-hypothesis → reference) pairs — the direct signal
- **HyPoradise v0** — 334K+ (N-best → reference) pairs across speech domains (LibriSpeech/CHiME/TED-LIUM-like), **MIT license — commercial OK.** The fastest path: text pairs, no audio pipeline.
- **Robust-HyPoradise** — 100K–1M noisy-domain pairs, **Apache 2.0 — commercial OK.**
- *(HyPoradise-v1-GigaSpeech exists but rests on GigaSpeech audio, which is non-commercial — gray area, avoid for shipping.)*

### Large general ASR corpora to run FluidAudio over (engine-specific errors)
- **LibriSpeech** (~960 hr, **CC BY 4.0**, commercial) — clean; running *FluidAudio* over it yields `(FluidAudio output → reference)` pairs in our **actual** ASR's error distribution (more useful than HyPoradise's Whisper-based hyps).
- **People's Speech** (30k+ hr, **CC-BY**, commercial) — speaker/accent/style diversity; use a curated slice.
- **Avoid for product training:** GigaSpeech audio (NC), TED-LIUM (NC-ND), SPGISpeech (proprietary NC), SLURP (NC), Spoken Wikipedia (CC-BY-**SA** → share-alike would force open model weights).

### The honest gap
**No public dataset covers our niche** — `(raw → ref)` where a technical/tool name is misheard as a homophone (`Snyk`→sneak, `k8s`→Kate's). Closest are Contextual Earnings-22 (finance jargon + biasing lists, CC-BY-SA) and SLUE-VoxPopuli (named entities), neither on-point. **This tier must be synthesized — exactly the confusion-injection recipe (Ph21).**

## The full build path (now concrete and license-clean)

1. **Base — general skill:** fine-tune the small seq2seq on **HyPoradise v0 + Robust-HyPoradise** (MIT/Apache), then adapt with **LibriSpeech → FluidAudio** pairs (CC-BY; our engine's real errors), optionally + a **People's Speech** slice (CC-BY) for diversity. Attribution in `THIRD_PARTY_LICENSES.md`.
2. **Domain — dev terms:** synthesize via **confusion-injection** (Ph21) — no public data exists; this is the Parleq-specific layer.
3. **Personal — per user:** a **2.77 MB LoRA adapter** (Ph22) refreshed from the correction journal on-device. Free conditioning for brand-new terms; rule-stack fallback for safety.

This is the whole arc: public GER data → strong base → injection for jargon → tiny per-user LoRA. Each tier is feasible, the licenses are clean, and only the niche layer needs synthesis (which we've already shown works).

## Honest bounds

- Spike base was deliberately weak (synthetic multivoice only); the recall numbers will move once trained on HyPoradise/LibriSpeech — the *relative* findings (LoRA tiny + precise; conditioning insufficient on small model) are the durable part.
- Single speaker, 12/12 test, same-speaker confusion recurrence (per-user recipe, not cross-speaker proof).
- Dataset licenses summarized from a research pass — **verify each before shipping** (esp. the GigaSpeech-derived HyPoradise-v1 and any SA clauses).

## Reproduce / artifacts

Local (git-ignored `bench/spike/`): `spike_personalization.py`, `model_base/`, `lora_user/` (2.77 MB), `model_v2_full/`. Dataset links in the Phase-22 research notes (this doc's Part 2).
