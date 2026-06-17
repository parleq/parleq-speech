# Featherweight Corrector — A+B De-risking Spike: Implementation Plan

> Implements `docs/explorations/2026-06-17-featherweight-corrector-spike-design.md`. This is a **research + serving spike**, not app code: tasks are runnable stages with a concrete metric/output checkpoint (not TDD cycles). Committed `bench/` tooling gets commits; `bench/spike/` data/models/datasets stay git-ignored. Heavy stages (dataset download, LibriSpeech→FluidAudio, training) run in the background.

**Goal:** Produce a go/no-go on the on-device corrector — does `strong public-data base + injection + rule-stack precision post-filter` reach near-LLM recovery at low over-fire on cross-validated real clips (Phase A), and can a small seq2seq be served on-device at hot-path latency (Phase B)?

**Architecture:** Extend the existing `bench/spike/` pipeline — swap the weak synthetic base for a strong public-data base, reuse the confusion-injection + scoring harness, add a new rule-stack precision filter, and evaluate with k-fold CV + a full ablation matrix. Independently probe on-device serving (CoreML T5 vs MLX decoder-only). Decouple the recipe risk (flan-t5-small) from the serving risk (architecture TBD by Phase B).

**Tech Stack:** Python 3.9 (`bench/.venv`): HuggingFace `transformers`/`datasets`/`peft`, `torch`, `sentence-transformers`, `jellyfish`. Swift: FluidAudio (batch transcription), `coremltools` (B1), `mlx-swift`/`mlx-swift-lm` (B2/B3). Existing `bench/*.py` scoring + rule-stack tooling.

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `bench/spike/fetch_datasets.py` | Download + normalize HyPoradise v0, Robust-HyPoradise, LibriSpeech-100, People's Speech slice → pair JSONL. | Create (git-ignored data) |
| `bench/batch_transcribe.swift` (or extend `asr-bench`) | Run FluidAudio over an audio dir → `(asr_output, reference)` pairs JSONL. | Create/extend |
| `bench/spike/build_base.py` | Assemble the base training corpus from all pair sources. | Create |
| `bench/spike/train_base.py` | Train the strong flan-t5-small base (extends `train_v2.py`). | Create |
| `bench/precision_filter.py` | **Committed.** Rule-stack veto over a model's diffed edits. | Create |
| `bench/spike/eval_cv.py` | k-fold CV + ablation matrix over the real clips, scored via `score_*.py`. | Create |
| `bench/spike/serving/export_t5_coreml.py` | flan-t5-small → CoreML. | Create |
| `bench/spike/serving/ServingProbe/` | Swift micro-harness: load a model, time inference on sample utterances. | Create |
| `docs/explorations/2026-06-18-corrector-spike-results.md` | Phase-A + Phase-B results + go/no-go. | Create at end |
| `THIRD_PARTY_LICENSES.md` | Note dataset licenses if a shippable artifact results. | Modify (Phase C, conditional) |

---

## Phase 0 — Environment & reuse audit

### Task 0.1: Verify the Python env and reusable artifacts

- [ ] **Step 1: Confirm the venv + libraries.**
  Run: `bench/.venv/bin/python -c "import transformers, torch, datasets, peft, sentence_transformers, jellyfish; print(transformers.__version__, torch.__version__)"`
  Expected: prints versions, no ImportError. If `datasets`/`peft` missing: `bench/.venv/bin/pip install datasets peft`.
- [ ] **Step 2: Confirm reusable spike artifacts exist.**
  Run: `ls bench/spike/{build_v2.py,train_v2.py,confusion.json,real_test.jsonl} && ls bench/spike/wav | wc -l && wc -l bench/spike/real_test.jsonl`
  Expected: files present; ~1100 wavs; ~24 lines in `real_test.jsonl`.
- [ ] **Step 3: Reproduce one baseline number** to confirm the eval harness works before changing anything.
  Run the existing eval on the existing `model_v2_inject` against `real_test.jsonl` (via `eval_only.py` / `score_recall.py`).
  Expected: inject-only ≈ 58% recovery / 0 over-fire (Ph21). If it doesn't reproduce, fix the harness before proceeding — every later number depends on it.
- [ ] **Step 4: Confirm FluidAudio batch transcription is runnable.**
  Run: `swift build --product asr-bench 2>&1 | tail -3` (the over-fire-gate bench tool that already loads FluidAudio).
  Expected: builds. Note its CLI surface — we extend it (or add `batch_transcribe`) in Task A.2.

---

## Phase A — strong base + recipe validation

### Task A.1: Fetch the public datasets

- [ ] **Step 1: Implement `bench/spike/fetch_datasets.py`** — pulls and normalizes each source to a common `{"hyp": ..., "ref": ...}` JSONL:
  - HyPoradise v0 (HF `hub` / repo; MIT) → take the top-1 hypothesis as `hyp`.
  - Robust-HyPoradise (Apache) → same shape.
  - LibriSpeech `train-clean-100` (HF `datasets` `librispeech_asr`, `clean/train.100`; CC-BY) → keep `{audio, text}` for the FluidAudio pass (A.2), not pairs yet.
  - People's Speech (HF `MLCommons/peoples_speech`, CC-BY) → stream a ~10–20 hr slice of `{audio, text}`.
- [ ] **Step 2: Run it.** `bench/.venv/bin/python bench/spike/fetch_datasets.py --out bench/spike/datasets/`
  Expected: `datasets/hyporadise.jsonl` (~334K lines), `robust_hyporadise.jsonl`, `librispeech100/` (audio+text), `peoples_slice/`. Log counts. **Long-running download — run in background.**
- [ ] **Step 3: Sanity-check** a few rows of each pair file (`hyp` ≠ `ref`, both non-empty). No commit (git-ignored data); the *script* is git-ignored under `spike/` too — that's fine.

### Task A.2: LibriSpeech → FluidAudio pairs (our engine's real errors)

- [ ] **Step 1: Add a batch-transcribe path.** Extend `asr-bench` (or add `bench/batch_transcribe.swift`) to take an audio dir + reference manifest and emit `{"hyp": <FluidAudio output>, "ref": <reference>}` JSONL, using the **0.14.5-pinned** FluidAudio + the same decode config the app uses (no custom vocab — we want the base error distribution).
- [ ] **Step 2: Run over `train-clean-100`** (resample to 16 kHz mono as needed).
  Run in background: emits `bench/spike/datasets/librispeech100_fa.jsonl`.
  Expected: ~28k pairs; spot-check that `hyp` shows realistic FluidAudio errors vs `ref`. **Hours of ANE compute — background.**
- [ ] **Step 3: Repeat for the People's Speech slice** → `peoples_fa.jsonl`.
- [ ] **Step 4: Commit** the committed Swift harness (not the data): `git add` the `batch_transcribe`/`asr-bench` change; `git commit -m "bench(asr): batch-transcribe harness for LibriSpeech->FluidAudio pairs"`.

### Task A.3: Assemble the base corpus

- [ ] **Step 1: Implement `bench/spike/build_base.py`** — concatenate + dedupe + shuffle: HyPoradise + Robust-HyPoradise + `librispeech100_fa` + `peoples_fa` into `bench/spike/base_train.jsonl`, in the same input/target format `train_v2.py` expects (correction prompt → reference). Hold out a small dev split for early-stopping.
- [ ] **Step 2: Run + checkpoint.** Print total rows + per-source counts. Expected: ≫ the spike's ~3k (target ~hundreds of k from HyPoradise alone).

### Task A.4: Train the strong base

- [ ] **Step 1: Implement `bench/spike/train_base.py`** by adapting `train_v2.py`: same flan-t5-small, train on `base_train.jsonl`, early-stop on the dev split, save to `bench/spike/model_base_strong/`. Log train/dev loss.
- [ ] **Step 2: Train** (background; GPU/MPS if available else CPU). Checkpoint: dev loss decreases and plateaus.
- [ ] **Step 3: Smoke-eval** the strong base alone on `real_test.jsonl`. Expected: recovery **> the weak base's 50%** (a strong base should lift it) — if not, investigate data/format before adding layers.

### Task A.5: Add the dev-jargon injection layer

- [ ] **Step 1: Reuse `build_v2.py`** to mine the confusion table from real-train clips and inject into the strong base corpus (or as a second fine-tune stage on top of `model_base_strong/`). Produce `model_base_strong_inject/`.
- [ ] **Step 2: Smoke-eval** on `real_test.jsonl`. Expected: recovery ≥ inject-only spike (58%) and ideally higher with the strong base under it.

### Task A.6: Build the rule-stack precision post-filter

- [ ] **Step 1: Implement `bench/precision_filter.py`** (committed, reusable). API:
  ```python
  def filter_edits(raw: str, model_out: str, dictionary, token_conf=None) -> str:
      """Accept a model edit only if its changed span is dictionary-grounded.
      Diff raw vs model_out into edited spans; for each span, keep the model's
      version iff the span is near a dict term (grapheme OR phonetic >= gate,
      reusing correct_frontier/phonetic_trigger) AND (low-conf class-2 OR
      context-fit-supported class-3); else revert that span to raw."""
  ```
  Reuse `correct_frontier.py`'s proximity gates + `phonetic_trigger.py`'s Metaphone `pho()`. Start with the Ph19 tuned params (near_gate 0.7, phonetic_gate 0.90).
- [ ] **Step 2: Unit-check it** on the known spike over-fires: assert `filter_edits` reverts `reddish→redis` and `Cates→CRAN` (non-dictionary-grounded) but keeps a legitimate `sneak→Snyk` (Snyk in dict). Run as a `__main__` self-test with asserts.
  Run: `bench/.venv/bin/python bench/precision_filter.py --selftest`  Expected: asserts pass.
- [ ] **Step 3: Commit.** `git add bench/precision_filter.py && git commit -m "bench(asr): rule-stack precision post-filter (vetoes non-dict-grounded model edits)"`

### Task A.7: k-fold CV + ablation matrix

- [ ] **Step 1: Implement `bench/spike/eval_cv.py`** — k-fold (e.g. 5-fold) over **all ~74 real clips**: for each fold, re-mine confusion from the train folds, re-inject, (re)train or reuse the base, and score each system on the held-out fold. Systems (columns): `raw`, `rule-stack`, `base`, `base+inject`, `base+inject+multivoice`, `base+inject+filter`, `(reference) LoRA`, `LLM`. Metrics (rows): recovery (`score_recall.py`), over-fire (`score_overfire.py`), WER (`score_wer.py`), trust (`trust_metric.py`). Report per-fold + mean ± spread.
- [ ] **Step 2: Run** (background — retraining per fold is the expensive part; if full per-fold retrain is too costly, document the compromise, e.g. fixed base + per-fold confusion/inject only, and `log()` it as a limitation).
- [ ] **Step 3: Checkpoint against the success bar.** Record whether `base+inject+filter` hits recovery ≥ ~65–70% AND over-fire ≤ ~5%. This is the core go/no-go signal.

### Task A.8: Cross-speaker arm (recommended, non-blocking)

- [ ] **Step 1: Capture a second speaker.** Use `bench/record_corpus.py` to record a modest set (the same prompt sentences) from a second speaker — or substitute an early flywheel contributor's clips if available.
- [ ] **Step 2: Transcribe + score** that speaker's clips with the *first* speaker's trained `base+inject+filter` (no re-personalization) → the first cross-speaker generalization signal.
- [ ] **Step 3: Record the result** (even "recovery drops to X% cross-speaker" is a valuable finding). If no second speaker is reachable, write one sentence documenting single-speaker as the standing bound and move on — **do not block**.

---

## Phase B — on-device serving feasibility (Swift)

Runs independently of A (use `model_v2_inject` or `model_base_strong` as a representative model).

### Task B.0: Serving micro-harness

- [ ] **Step 1: Create `bench/spike/serving/ServingProbe/`** — a tiny SwiftPM executable that loads a converted model + tokenizer, runs N sample utterances (from `real_test.jsonl`), and prints load time, per-utterance latency (mean + p95), and peak resident memory. One protocol, one impl per backend.

### Task B.1: flan-t5-small → CoreML

- [ ] **Step 1: `bench/spike/serving/export_t5_coreml.py`** — convert flan-t5-small (encoder + decoder, with a greedy/beam decode loop) to CoreML via `coremltools`. T5 seq2seq export is the risky bit — if a single-package export fails, export encoder and decoder-step separately and drive the loop from Swift.
- [ ] **Step 2: Run the ServingProbe** with the CoreML model on Apple Silicon. Record size, load, latency (mean/p95), memory.
- [ ] **Step 3: Record** pass/fail + numbers. A failed/clumsy conversion is itself a finding (pushes production toward decoder-only).

### Task B.2: small decoder-only → MLX-swift

- [ ] **Step 1: Pick a small decoder-only candidate** MLX-swift already serves (e.g. Qwen2.5-0.5B-Instruct or Llama-3.2-1B), reusing the app's existing `mlx-swift-lm` integration pattern (see `VendoredGemma4Text`/`LocalLLMProvider`). Frame correction as an instruction decode ("Correct this ASR transcript using these terms: …").
- [ ] **Step 2: Run the ServingProbe** via the MLX path. Record size, load, latency, memory.
- [ ] **Step 3: Record** numbers vs the ~139 ms Gemma TTFT and the 4 GB size budget.

### Task B.3: flan-t5 via MLX (if supported)

- [ ] **Step 1: Check** whether `mlx-swift-lm` supports T5/seq2seq. If yes, load + probe. If no, record "unsupported" and skip — B.1 (CoreML) and B.2 (decoder-only) bracket the decision.

### Task B.4: Serving feasibility report

- [ ] **Step 1: Tabulate** size / load / latency(mean,p95) / memory per candidate, against the targets (≤ ~Gemma TTFT, ≪ 4 GB). Identify which architecture(s) are servable.

---

## Phase C — synthesis & go/no-go

### Task C.1: Results doc + recommendation

- [ ] **Step 1: Write `docs/explorations/2026-06-18-corrector-spike-results.md`** — the Phase-A CV ablation matrix, the precision-filter's over-fire reduction, the cross-speaker signal, the Phase-B serving table, and the verdict against the three-part bar (recall ≥~65–70%, over-fire ≤~5%, serving feasible).
- [ ] **Step 2: State the recommendation** — production model architecture + **proceed to Phases C/D (productionization)** or **fall back to shipping the rule stack + trust surface (item 2)** — with the numbers behind it.
- [ ] **Step 3: Commit** the results doc. (Push to origin only on maintainer approval — the hard gate stands.)

---

## Self-review notes

- **Spec coverage:** datasets (A.1), LibriSpeech→FluidAudio (A.2), base corpus + strong base (A.3/A.4), injection layer (A.5), precision filter (A.6), k-fold CV + ablation matrix (A.7), cross-speaker arm (A.8), serving probes CoreML/MLX/T5-MLX (B.1–B.3), serving report (B.4), go/no-go results doc (C.1). Success bar checked in A.7 + C.1. All spec sections mapped.
- **No placeholders:** every stage has a concrete command + checkpoint; exploratory serving steps state the fallback explicitly (separate enc/dec export; "unsupported→skip").
- **Naming consistency:** `model_base_strong` → `model_base_strong_inject`; `precision_filter.filter_edits`; `eval_cv.py` ablation columns named once and reused.
- **Reuse honored:** extends `build_v2.py`/`train_v2.py`/`confusion.json`/`real_test.jsonl`/`score_*.py`/`correct_frontier.py`/`phonetic_trigger.py`/`record_corpus.py` rather than rebuilding.
- **Honest limits flagged:** per-fold-retrain cost compromise is to be `log()`'d if taken (A.7); single-speaker bound documented if A.8 finds no second speaker; T5-CoreML conversion may fail (B.1) and that's a recorded finding.
