# Flywheel Contribution Capture — Design

**Date:** 2026-06-17
**Status:** Approved design; implementation pending.
**Branch:** `feat/flywheel-contribution-capture`
**Program context:** Item 1 of the intent-recovery program (issue #100). This is the **data flywheel** — the critical-path enabler that unblocks both the featherweight corrector (item 3) and the usage-prior. See `docs/explorations/2026-06-1[67]-intent-recovery-*` for the research narrative.

## Purpose

An opt-in, explicitly-armed **contribution mode** that durably captures every dictation — audio + transcripts + ASR metadata — into a local corpus. The corpus bootstraps and evaluates the on-device intent-recovery corrector (error-injection training, held-out WER/recovery eval, cross-speaker validation, and over-fire forensics for the FluidAudio-decoupling decision).

The feature is **off by default, invisible to normal users, and walled off from the shipped product invariants**. It exists for deliberate contributors who have chosen to share their dictation data — initially the maintainer, possibly a small set of collaborators later.

### Non-goals

- Not a shipping product feature. Not surfaced in Settings, the wizard, README, public docs, or `CLAUDE.md`'s documented config shape.
- **No network transmission.** Capture is purely local. "Contributing" the corpus to the project is a separate, manual act the contributor performs by hand. The recorder contains no network code.
- Not a replacement for the in-memory `CorrectionJournal` / `LearnedStore` learning loop — that remains the shipped, in-memory-only learning path. This is a distinct, durable, contributor-only sink.

## Why audio (not text-only)

The `(raw ASR → final)` text pair is a *frozen derivative* — locked against whatever ASR version produced it. **Audio is the re-runnable source**, and it is the scarce asset:

1. **Re-derive raw transcripts against any future model.** Judge whether FluidAudio 0.15.x / 0.16 / a vendored CTC rescorer over-fires on *real* dictation (not just the synthetic bench corpus) by re-running over retained clips. Directly serves the dependency-upgrade / biasing-decoupling decision (issue #100).
2. **Build a true held-out eval set** (audio + ground-truth final text) to measure WER/recovery of any candidate corrector or ASR model.
3. **Attack the program's biggest caveat** — "single speaker; cross-speaker generalization unproven." Multi-contributor audio is the only source of acoustic diversity.
4. **Regenerate word-confidence/timing** for the trust-surface and contextual-fit work.

Text pairs are cheap to regenerate *from* audio; audio can never be regenerated from text. We capture the source.

## Components

### `ContributionRecorder` (new file, `Sources/ParleqAppCore/ContributionRecorder.swift`)

Single responsibility: when **armed**, persist one record per dictation lifecycle to the local corpus.

- **Passive observer.** Never blocks, never breaks a paste. Hooks fire at the dictation's terminal states only.
- **Off the hot path, fail-silent.** Writes happen asynchronously after the terminal state. Any failure (disk full, permissions) is swallowed and logged **count-only** — never surfaces to the user, never interrupts the product path.
- **Deliberately separate** from the in-memory `CorrectionJournal`, so invariant #7's "never to disk" promise for the shipped learning loop stays literally true. The security-review story is then crisp: *one* clearly-named component writes dictation data to disk, and *only* when armed.

## Storage layout

```
~/.parleq/flywheel/
├── manifest.jsonl        ← append-only, one JSON line per dictation
└── audio/
    └── <uuid>.wav        ← 16 kHz mono int16, verbatim AudioRecorder output
```

- **Unbounded; manual pruning.** No automatic cap, ring, or retention. The contributor prunes `~/.parleq/flywheel/` by hand. Rationale: this is a research corpus where every sample (especially rare error cases) has value; an automatic cap would silently discard the most valuable data. Each manifest line records cumulative corpus size (`corpus_bytes`) so growth is visible at a glance.
- `<uuid>` is shared between the manifest record `id` and its audio filename.

## Per-record schema (one JSON object per `manifest.jsonl` line)

```json
{
  "id": "<uuid>",
  "ts": "2026-06-17T12:34:56Z",
  "disposition": "accepted",

  "audio": "audio/<uuid>.wav",

  "asr_transcript": "...",
  "cleaned": "...",
  "final": "...",
  "cleanup_failed": false,

  "asr": {
    "confidence": 0.0,
    "duration_sec": 0.0,
    "processing_sec": 0.0,
    "token_timings": [
      { "token": "...", "token_id": 0, "start_time": 0.0, "end_time": 0.0, "confidence": 0.0 }
    ],
    "replacements": [
      { "original": "sync", "replacement": "Snyk", "reason": "CTC-vs-CTC", "applied": true }
    ]
  },

  "vocabulary": ["Snyk", "CRAN"],
  "asr_model": "parakeet-tdt-v3",
  "fluidaudio_version": "0.14.5",
  "llm": "gemini-2.5-flash",
  "app_bundle": "com.apple.dt.Xcode",

  "reference_windows_attached": false,
  "transform_applied": false,
  "refined": false,
  "corrector_pair_eligible": true,

  "refine_turns": [
    { "instruction": "...", "before": "...", "after": "..." }
  ],
  "spellout_terms": ["Mira"],

  "corpus_bytes": 123456789
}
```

### Field semantics

| Field | Meaning |
|---|---|
| `disposition` | `"accepted"` (user accepted → full pair) or `"discarded"` (Esc/cancel → `final: null`, audio + ASR still captured). |
| `audio` | Relative path to the WAV; `null` only if audio is somehow unavailable. |
| `asr_transcript` | The **post-CTC-rescore** transcript — i.e. exactly what the product emits after vocab biasing (and the corrector's real input distribution). Named `asr_transcript`, not `raw_asr`, so it can't be mistaken for the unbiased Parakeet baseline. |
| `cleaned` | The LLM cleanup output, **before** any manual overlay edit or refine turn. `null` when cleanup failed or `provider=none`. Separating this from `final` lets a consumer attribute each change to its true source: ASR error (raw→cleaned via LLM) vs human correction (cleaned→final via manual edit). |
| `final` | The text the user actually accepted (cleanup + any manual overlay edits + any refine turns). `null` for `discarded`. |
| `asr` | ASR diagnostics (`ASRDiagnostics`, `Codable`). `tokenTimings` is the per-token confidence/timing feature set for the trust surface, the confidence×dictionary gate, contextual-fit, and the phonetic trigger. **`replacements`** is the over-fire forensics signal — Parleq's own CTC vocab-rescorer output, one entry per considered replacement with `original` → `replacement` + `reason` + `applied` (whether it was substituted in). This is *richer* than FluidAudio's term-list-only `ctcDetectedTerms`/`ctcAppliedTerms`, which stay nil on our path because Parleq runs its own rescorer (`VocabBox`). Populated only on the bundled path; the external-HTTP ASR path leaves the whole `asr` object null. **(On disk all keys are snake_case via `convertToSnakeCase`, e.g. `token_timings`, `processing_sec`.)** |
| `asr_model` / `fluidaudio_version` | Stamp the baseline so any re-run against a future model knows what it is comparing against. |
| `app_bundle` | Destination app bundle id — useful for per-app analysis (which apps a dictation was destined for). |
| `reference_windows_attached` | `true` if clipboard/image/file reference context was fed to the LLM for this utterance. |
| `transform_applied` | `true` if a preset or per-app-default styling transform was folded into the cleanup prompt. |
| `refined` | `true` if ≥1 refine/command turn occurred (i.e. `refine_turns` is non-empty). |
| `corrector_pair_eligible` | **Derived**, conservative convenience flag: `final != null && cleaned != null && !cleanup_failed && !reference_windows_attached && !transform_applied && !refined`. Excludes discarded records (no `final`) and failed-cleanup records (whose `final` is the raw fallback → a degenerate `asr_transcript == final` identity pair). See "Corrector-pair eligibility" below. |
| `refine_turns` | All refine turns for this utterance (instruction + before/after), bundled into the single record. |
| `spellout_terms` | Spell-out candidates detected by `SpellOutDetector` in the raw transcript. |
| `corpus_bytes` | Cumulative on-disk size of `~/.parleq/flywheel/` at write time, for growth visibility. |

### Deliberate omission: pre-CTC-rescore base text

The captured `asr_transcript` is the **post**-rescore transcript. The pre-rescore base text (pure Parakeet output, before vocab substitution) exists only as a local variable inside `LocalASR` and is **not** captured. Reasoning:

- The only use for exact base text is studying the CTC rescorer **in isolation**, and that study inherently requires re-running audio against *multiple* FluidAudio versions — which yields base text for free, for any version. Live capture only ever gives one version's base.
- The corrector trains on `(asr_transcript → final)` where `asr_transcript` is the post-rescore product output — base text is not its input.
- "Is this utterance interesting for over-fire?" is already answered by the `asr.replacements` list (original→replacement+applied).
- Re-derivation is **exact**: base text (biasing off) depends only on the deterministic Parakeet decode + model version (stamped in `fluidaudio_version`), not on `minSimilarity`/`cbw`.

So base text is reconstructable on demand and never needed live. Omitted to avoid plumbing it through `LocalASR → ASRClient → AppState` for no marginal benefit.

## Corrector-pair eligibility

The central data-quality refinement. Two classes of dictation produce a `final` that is **LLM-transformed, not ASR-corrected** — treating their `(asr_transcript → final)` as a corrector training pair would poison the model (teaching it to invent content not present in the audio):

1. **Reference windows attached** — output is driven by external clipboard/image/file context, not by correcting the transcript.
2. **Cleanup commands during refinement** — a refine turn is a transformation instruction ("make it shorter"), not a correction.

In both cases the **lower layers remain valuable**: audio → ASR → CTC is clean data for ASR eval, re-runs, over-fire forensics, and the corrector's *input* distribution. So we **capture every record fully** and **tag provenance**, letting downstream consumers separate "valid correction pair" from "ASR-layer-only data."

`corrector_pair_eligible` is **derived** from the recorded objective facts (`final != null && cleaned != null && !cleanup_failed && !reference_windows_attached && !transform_applied && !refined`), so the rule can be revised later by recomputing from the stored fields — no judgment is irreversibly baked in. It is deliberately **conservative**: false negatives (a usable pair not auto-tagged) are safer than false positives (a degenerate pair polluting training). Consequences:

- A **plain dictation with a manual overlay edit** (no reference, no transform, no refine, cleanup succeeded) stays `eligible`; the `cleaned`-vs-`final` delta is the gold human-correction signal.
- A **reference-window** dictation → `eligible: false`, lower layers retained.
- A **refine/command** dictation → `eligible: false`, lower layers retained.
- A **discarded** dictation (`final: null`) → `eligible: false`; audio + ASR retained for re-runs/eval.
- A **failed-cleanup** dictation → `eligible: false` (its `final` is the raw fallback, so `(asr_transcript → final)` would be a degenerate identity pair). A consumer wanting the rarer *hand-edited-after-failure* pairs recomputes them from `cleanup_failed == true && final != asr_transcript`.
- A **`provider = none`** dictation (cleanup skipped, raw pasted) → `eligible: false` via `cleaned == null`; `final == asr_transcript` would otherwise be a degenerate identity pair.

## Arming — hidden, acknowledgment-gated

The feature is armed by a hand-edited, acknowledgment-string-gated key in its own top-level config block:

```json
"contribution": {
  "capture": "i-understand-this-writes-my-audio-and-transcripts-to-disk"
}
```

- **Only the exact acknowledgment phrase arms it.** A bare `true`, an unset block, an MDM push, or a copied config template all do nothing. This makes the enabling gesture deliberate and informed, and the value itself documents the consequence to anyone auditing a config.
- **Own top-level block, not the `features` block.** The Settings save path rewrites `features` and would silently drop an unknown key there; it preserves unknown *top-level* blocks. So a hand-edited `contribution` block round-trips and Settings never clobbers it or re-exposes it in the UI. *(Round-trip behavior to be verified against `Config.save()` at implementation time — see Open implementation questions.)*
- **Documented only in `docs/SECURITY_REVIEW.md`.** Never in README, public docs, or `CLAUDE.md`'s documented config shape. The point is to make inadvertent enablement in a corporate environment effectively impossible.

## Capture lifecycle

- One record per dictation lifecycle, written **once at the terminal state**, bundling that utterance's refine turns + spell-out signals.
- Hooked at **both** terminal states:
  - `AppState.accept()` — full pair, `disposition: "accepted"`.
  - the discard/cancel path — `disposition: "discarded"`, `final: null`, audio + ASR retained.
- Discarded utterances are captured because their audio is just as re-runnable against future ASR models as accepted ones; the `disposition` tag lets a consumer filter to accepts-only when it needs pairs.

### Required plumbing (detailed in the implementation plan)

- **Full `ASRResult`** must be carried from `ASRClient` → `AppState` (today only `.text` is retained as `lastRawTranscript`). The bundled `LocalASR` path produces the full result; the HTTP path produces `text`-only.
- The **raw WAV `Data`** must be retained to the terminal state (including the discard path).
- A runtime signal for **"were reference windows attached to *this* utterance"** must be available at capture time (not merely whether the feature is enabled in config). Confirm/extend in the plan.

## Compliance / invariant updates

This is a **documented carve-out** to three hard invariants, in effect **only when the contribution flag is armed**:

- **#1** (audio memory-only end-to-end)
- **#2** (transcript content never to disk)
- **#7** (correction signals never to disk)

Required documentation work:

- Annotate invariants #1, #2, #7 in `CLAUDE.md` to point at the armed-contribution-mode exception (the invariant still holds literally for every user who has not armed the flag).
- Write the disclosure in `docs/SECURITY_REVIEW.md`: what is captured, where, the arming gesture, the no-network-transmission property, and that it is off by default and absent from all user-facing surfaces.

## Testing / verification

No formal test target exists; verification is `swift build` + manual end-to-end:

1. **Disarmed by default:** with no `contribution` block (and with a bare `"capture": true`), run dictations → confirm `~/.parleq/flywheel/` is never created and nothing is captured.
2. **Armed:** set the exact acknowledgment phrase, run dictations covering: accept, discard, refine, preset/transform, reference-window. Confirm one `manifest.jsonl` line + one WAV per dictation, with correct `disposition`, the `asr` block populated (bundled path), and `corrector_pair_eligible` correctly false for reference/transform/refine cases and true for a plain accept (incl. manual edit).
3. **Settings round-trip:** open and close Settings while armed → confirm the `contribution` block survives untouched in `config.json` and never appears in the UI.
4. **Fail-silent:** simulate an unwritable corpus dir → confirm the dictation/paste path is unaffected and the failure is logged count-only.

## Open implementation questions (resolve in the plan)

- Confirm `Config.save()` preserves unknown top-level blocks (the `contribution` round-trip assumption).
- Confirm/locate the runtime "reference windows attached this utterance" signal in `AppState`.
- Confirm the raw WAV `Data` is still in scope at the discard/cancel terminal state.
- Decide the exact write mechanism (append to `manifest.jsonl` + write WAV) and its actor/threading model so it is genuinely off the hot path.
