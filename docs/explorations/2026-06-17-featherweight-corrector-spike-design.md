# Featherweight Corrector — A+B De-risking Spike (design)

**Date:** 2026-06-17
**Status:** Approved design; implementation pending. **Research spike, not a shipping build** — productionization (app integration, on-device LoRA personalization) is a separate, maintainer-gated effort contingent on this spike's go/no-go.
**Program context:** Item 3 of the intent-recovery program (issue #100). Builds directly on the corrector arc — Phase 20 (featherweight spike: model easy, data is the wall), Phase 21 (realism-enriched: 42→75% via error-injection), Phase 22 (LoRA personalization + license-clean dataset recipe) — and the TRUNK capstone. Extends the existing `bench/spike/` artifacts.

## Why this spike exists

The research recommended a **hybrid** on-device corrector — deterministic rules (precision) + an injection-trained learned model (recall) + a rule-stack precision post-filter — built in three tiers (general base → dev-jargon injection → per-user LoRA). But it left **two unanswered, build-gating questions**:

- **(A) Does a *strong* base deliver?** The validated spike used a deliberately *weak* base (multivoice-only synthetic, ~3k rows), capping recall at 58–75%, and the learned model over-fired at 17% (vs rules/LLM at 0). Does a base trained on the real public-data recipe + a precision post-filter close both the recall *and* precision gaps on held-out real clips?
- **(B) Can it be served on-device?** The spike trained/ran flan-t5-small in PyTorch. Shipping requires serving a small seq2seq in Swift at hot-path latency — an unproven path (the app's MLX stack serves decoder-only models; T5 is encoder-decoder).

This spike answers both **before** committing to the large app-integration build. It needs **no journal data** (uses public data + the existing real clips), so it runs now while the data flywheel fills for the later personalization tier.

## Goal

Produce a **go/no-go** with numbers and a **recommended production architecture**:
1. Whether `strong-base + injection + precision-filter` reaches near-LLM recovery at low over-fire on held-out real clips (cross-validated).
2. Whether — and how (CoreML vs MLX, T5 vs decoder-only) — such a model is servable on-device at acceptable latency/size.

## Non-goals

- No app integration, no shipping, no config/UI. Stays in `bench/`.
- **No on-device LoRA personalization** in this spike — that is Phase C, gated on the correction-journal flywheel accumulating real per-user data. (The existing `lora_user/` adapter remains a reference artifact only.)
- Not a cross-speaker *proof* — the cross-speaker arm is a first signal, not a guarantee (N will be small).

## Architecture decisions (settled)

- **Decouple the two risks.** Use **flan-t5-small (77M, encoder-decoder)** for Phase A to validate the *recipe* with continuity to Ph20–22 (the research's finding is that the recipe/data, not the architecture, is the wall). Probe **on-device serving (Phase B) independently** across candidate architectures. Choose the *production* model only after seeing both results — no premature architecture bet.
- **Precision post-filter = rule-stack veto.** The learned model *proposes* edits; the rule stack *vetoes* any edit whose changed span is not dictionary-grounded — accept a model edit only if the span is near a dictionary term (grapheme **or** phonetic proximity ≥ the tuned gate) **and** is either low-confidence (class-2) or context-fit-supported (class-3). This targets exactly the spike's observed over-fires (`reddish→redis`, `Cates→CRAN` — edits to non-dictionary words). Model supplies recall; rules supply precision. *Documented fallbacks if it underperforms: negative-example training; decoder copy-bias.*

## Phase A — strong base + recipe validation (Python/bench)

Extends the existing `bench/spike/` pipeline (`build_v2.py`, `train_v2.py`, `confusion.json`, `real_test.jsonl`, the `score_*.py` harness) — swap the weak base for a strong public-data base, re-run injection + eval, add the precision filter.

1. **Acquire datasets** (record license + provenance for each in `THIRD_PARTY_LICENSES.md` if it informs a shippable artifact):
   - **HyPoradise v0** (MIT) + **Robust-HyPoradise** (Apache 2.0) — full; text hypothesis→reference pairs.
   - **LibriSpeech `train-clean-100`** (CC-BY 4.0) — audio; expand to `-360` only if results justify.
   - **People's Speech** (CC-BY) — a small curated slice (~10–20 hr).
   - *Explicitly avoided (license): GigaSpeech-derived HyPoradise-v1, TED-LIUM, SPGISpeech, SLURP, Spoken-Wikipedia (SA).*
2. **Build the base corpus.** HyPoradise/Robust text pairs + **LibriSpeech→FluidAudio** pairs (run our actual engine over the audio slice → `(FluidAudio-output → reference)` in our real error distribution) + the People's Speech slice.
3. **Train the strong base** (flan-t5-small) on the base corpus — replacing the multivoice-only base that capped the spike.
4. **Add the dev-jargon domain layer** via confusion-injection (reuse `build_v2.py`/`confusion.json` — mine the real confusion table, inject into clean text at scale).
5. **Implement the precision post-filter** as a new `bench/` module wrapping the rule stack (`correct_frontier.py` gates) over the model's diffed edits.
6. **Score** via the existing `score_recall.py` / `score_overfire.py` / `score_wer.py` + `trust_metric.py`.

## Eval methodology (the "thorough" core)

- **k-fold cross-validation over all ~74 real clips** — the single 50/24 split is too small to trust one draw. Report per-fold and aggregate (mean ± spread).
- **Full ablation matrix**, each scored on recovery / over-fire / WER **+ the trust metric**:
  `raw → rule-stack → base → base+inject → base+inject+multivoice → +precision-filter → (reference) LoRA`, against the **LLM ceiling**.
- **Cross-speaker arm (recommended, not blocking).** Capture a **second speaker's** clips (maintainer, a volunteer, or an early flywheel contributor) and run the held-out eval on them — the first real signal on the program's biggest unproven claim (single-speaker generalization). If no second speaker is reachable within the spike, document single-speaker as the standing bound and note the flywheel will supply multi-contributor data later. **Do not block the spike on it.**

## Success bar (greenlight criteria)

Proceed to productionization (Phases C/D) only if **all three** hold:
1. **Recall:** hybrid (base+inject+precision-filter) recovery clearly beats the rule stack — target **≥ ~65–70%** vs the rules' ~50% on the hard held-out subset.
2. **Precision:** over-fire pulled to **≤ ~5% (ideally 0)** by the precision filter — closing the named blocker (the spike's 17%).
3. **Serving:** Phase B shows acceptable on-device latency/size for at least one architecture.

Miss any → document the reason and **fall back** to shipping the cheap, validated **rule stack + trust surface** (the deferred "item 2") as the local tier.

## Phase B — on-device serving feasibility (Swift)

Independent of Phase A's outcome; can run in parallel using a representative model.
- **B1.** flan-t5-small → **CoreML**: conversion path, model size, load time, per-utterance latency (typical + p95), peak memory, on Apple Silicon.
- **B2.** a small **decoder-only** candidate → **MLX-swift** (reuse the Gemma serving infra), correction framed as a constrained decode; same measurements.
- **B3.** (if `mlx-swift-lm` supports it) flan-t5 via **MLX**.
- **Targets:** latency comparable-to-or-better-than the local Gemma cleanup tier (~139 ms TTFT) and well under a cloud round-trip; resident size **≪** the 4 GB Gemma tier. Output: which architecture(s) are servable at what cost → informs the production model choice.

## Deliverables

1. **Phase-A results doc** — CV ablation matrix, the precision-filter's effect on over-fire, cross-speaker signal (if obtained), and the recall/precision go/no-go.
2. **Precision-filter module** added to committed `bench/` tooling (reusable by the eventual product).
3. **Phase-B serving-feasibility doc** — latency/size/memory per candidate architecture.
4. **Recommendation** — production model architecture + proceed-to-C/D or fall-back-to-item-2, with the numbers behind it.

## Risks & honest bounds

- **Single-speaker** remains the core caveat — *mitigated, not eliminated* by k-fold CV + the cross-speaker arm.
- **Compute:** dataset downloads + the LibriSpeech→FluidAudio pass are the cost (overnight-runnable at the `train-clean-100` scale; multi-day if expanded).
- **T5-on-device is genuinely uncertain** — that is precisely why Phase B exists; a negative result there reshapes the production architecture (push toward decoder-only).
- **Injection naturalness** — some injected sentences are slightly unnatural; a cleaner pipeline reduces this noise (carried from Ph21).
- This is research; productionization is separate, maintainer-gated, and contingent on the go/no-go.

## Reuse map (existing → spike)

| Existing (`bench/`) | Role in the spike |
|---|---|
| `spike/build_v2.py`, `confusion.json` | Confusion mining + injection (step 4) |
| `spike/train_v2.py`, `.venv` | Training harness (steps 3–4) |
| `spike/real_test.jsonl`, `wav/` | Held-out real clips → fold into k-fold CV |
| `score_recall.py` / `score_overfire.py` / `score_wer.py` / `trust_metric.py` | Eval scoring |
| `correct_frontier.py`, `compound_join.py`, `phonetic_trigger.py` | Rule stack → wrapped as the precision post-filter (step 5) |
| `record_corpus.py` | Capturing a second speaker's clips (cross-speaker arm) |
