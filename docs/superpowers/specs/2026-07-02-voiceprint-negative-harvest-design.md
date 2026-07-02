# Voiceprint Negative Auto-Harvest — Design

**Date:** 2026-07-02
**Status:** Design — ready for implementation planning. SPEC ONLY; no code has been written.
**Roadmap:** item 3.4 in `~/Dev/concord/docs/cleanup-improvement-roadmap-2026-07.md` (priority raised: claude↔cloud is the maintainer's #1 measured hand-fix, ×9 in both directions in the user-edit seam, §1b).
**Related:** the voiceprint-privacy ADR (`~/Dev/concord/docs/decisions/voiceprint-privacy.md`), durable-voiceprints spec (`2026-06-27-durable-voiceprints-design.md`), Corrector B design seed (`~/Dev/concord/docs/CORRECTOR-PROGRAM-HANDOFF.md` §2).

## Problem

The one-class voiceprint path is weak by our own measurement (coin-flips): with no negative
prototypes, `VoiceprintGate.decide` falls back to a bare `cos ≥ 0.80` threshold, and
`evaluate(.validation)` **can never revert** (revert requires `usedContrastive`). Real
consequences, both measured in the user-edit seam (roadmap §1b):

- **cloud→Claude over-fires** (Concord substitutes the alias; the weak one-class gate accepts).
- **claude→cloud over-fires that survive cleanup** (biasing makes the ASR emit "Claude"
  verbatim; the validation pass runs, but a one-class template structurally cannot revert, so
  the user hand-fixes it ×7 in 135 edit-seam records).

The proven fix is the **contrastive** path — per-confusable negative prototypes — but today
negatives are only gathered in the enrollment wizard (extra carrier recordings per confusable).
Users don't know their confusables in advance and won't re-run the wizard per over-fire.

**Goal in one sentence:** when the user corrects a dictionary-term over-fire (per-correction
overlay undo, or an E-edit that changes an enrolled term back to a common word), capture that
word's audio-span embedding and attach it as a negative prototype to the term's voiceprint
(`VoiceprintTemplate.withNegative`), so real usage converts weak one-class voiceprints into the
proven contrastive kind — no new enrollment UX.

## Non-goals

- Harvesting **positives** (adapting the term voiceprint itself from corrections) — riskier
  (positive drift corrupts the anchor every decision compares against); future work.
- Harvesting for terms with **no** enrolled voiceprint (that path already nudges toward
  enrollment via `VoiceEnrollNudge`; unchanged).
- Multi-word / `sayAsPhrase` spans — v1 is single-word `.dictionary`-stage edits only.
- Any Concord package change. The whole feature is app-side (`ParleqAppCore`, `#if Concord`);
  it composes existing public Concord API (`withNegative`, `DoubleMetaphone.encode`,
  `VoiceprintTemplate.init`).

## Code facts the design rests on (verified 2026-07-02)

1. **`withNegative` replaces, never accumulates.** `VoiceprintTemplate.withNegative(label:embeddings:)`
   (Concord `VoiceprintGate.swift:110`) pools the supplied embeddings into a centroid and
   **overwrites** `negatives[label]`. Accumulation across corrections therefore needs an
   app-side store of the raw harvested embeddings so the centroid can be recomputed on each
   attach (and healed on a mistaken harvest).
2. **The gate's contrastive rule needs no calibration.** `decide` accepts iff
   `cos(candidate, voiceprint) > cos(candidate, negProto)` for every negative — attaching even
   one negative flips the term from the weak one-class threshold to the validated contrastive
   rule, and **unlocks validation revert** (the claude→cloud direction).
3. **The revert label is surface text.** `AcousticGateOutcome.revert(to: label)` replaces the
   term with the label string in the transcript (ConcordEngine.swift:574-585). Harvest labels
   MUST therefore be the plain confusable word (`"cloud"`), never a synthetic key — which means
   a harvest for a label that already has an enrollment-derived prototype must **merge**, not
   shadow under a suffixed label.
4. **Encoder features are NOT retained at correction time** (the load-bearing gap). The
   pooling source, `ASRDiagnostics.encoderFeatures` (`EncoderFeatureSequence`, ~0.8 MB,
   in-memory only, excluded from `Codable`), is drained by `ConcordCleanupProvider`'s
   per-utterance side-channel inside the one cleanup call. At undo/E-edit time (overlay
   `.awaitingAccept`), neither the features nor the raw audio survive on AppState (the sole
   exception, `pendingContribution`, exists only when the hidden flywheel capture is armed).
   **Resolution: retain the utterance's `ASRDiagnostics` on AppState from cleanup completion
   until the overlay reaches a terminal state** (accept / discard / next dictation / refine
   turn / quit), Concord builds only, only when a voiceprint is enrolled and harvest is
   enabled. Pooling at correction time is then `EncoderFeatureSequence.pooledEmbedding(
   startSeconds:endSeconds:)` — pure in-memory mean-pooling, microseconds, no re-transcribe,
   no audio retention. Precedent for in-memory retention through review: v0.25.0's "Recover
   last dictation" retains the full audio bytes until the next dictation.
5. **The engine validates every ASR-emitted canonical term** (ConcordEngine.swift:560-587)
   when a gate is installed, in `.validation` mode. A revert emits
   `EditRecord(stage: .dictionary, original: <term>, replacement: <confusable>,
   reason: "acoustic-validate revert")` — so at undo time, "the user undid a revert" is
   detectable purely from the span shape: `hasVoiceprint(span.original)` (term on the
   *original* side) instead of the normal `hasVoiceprint(span.replacement)`.
6. **The correct persist path is `VoiceprintCoordinator.commit(_:)`** — it upserts into the
   in-memory `VoiceprintStore`, unions with `pendingMigration`, saves through
   `EncryptedVoiceprintStore`, and re-fires `onStoreChanged` → AppState re-installs the gate
   factory (which snapshots the store **by value** — a mutation that skips `commit` never
   reaches the live gate).
7. **The undo handler already recognizes the event.** `AppState.undoCorrection(number:)`
   (AppState.swift:1872-1921) has `span.replacement` (the canonical term — Concord has no
   separate termID; the replacement string *is* the termID), `span.original` (the heard
   confusable), `span.stage`, and already branches on
   `.dictionary/.acousticDictionary/.sayAsPhrase` to fire `VoiceEnrollNudge`.
8. **E-edits are unstructured.** `commitEdit(accept:)` (AppState.swift:1796) has only the
   before/after full strings (`editPreEditText` / `overlay.model.editableText`); any word-level
   diff is ours to compute.

## Design

### D1 — Harvest triggers (constraint 1)

**Trigger (a) — per-correction undo (⌥1–⌥9), first-class.** In `undoCorrection(number:)`,
when the undone span satisfies ALL of:
- `span.stage == .dictionary` (v1 excludes `.sayAsPhrase` — multi-word spans — and
  `.acousticDictionary` is currently unused by the shipped engine; include it if/when it emits),
- `voiceprint.hasVoiceprint(span.replacement)` (the term has a template to attach to),
- `span.original` is a single alphabetic word (affix-stripped),

→ locate the heard word's audio span in the retained diagnostics (D3), pool the embedding, run
validation (D4), attach (D5).

**Trigger (b) — E-edit replacing an emitted term with a common word, ALSO v1.** This is not
phase 2 — it is **the bootstrap for the biggest measured direction** (claude→cloud ×7): a
biasing over-fire makes the ASR emit "Claude" verbatim; a one-class template cannot revert
(fact 5), so **no edit exists to undo** — the E-edit is the user's only correction surface,
and the first harvested negative is precisely what unlocks the revert path for every later
occurrence. Deferring (b) would leave the #1 measured error class unharvestable until the
rarer substitution-direction over-fire happened to fire first. The marginal cost is one small
pure diff utility (D2); everything else (retention, locator, validation, attach) is shared
with (a). In `commitEdit(accept:)`, after `edited != editPreEditText`:
- compute conservative 1:1 word replacements (D2); for each `(before: X, after: Y)` where
  `hasVoiceprint(X-core)` and `Y-core` is a single alphabetic word → treat X as the term,
  Y as the confusable label; locate X's emitted span (D3), validate (D4), attach (D5).
- Refine turns never harvest: the retained diagnostics are cleared when a refine turn starts
  (the shown text no longer maps to the raw utterance).

**Trigger (a′) — healing (undo of a validation revert).** When the undone span has the
*inverted* shape — `span.stage == .dictionary && hasVoiceprint(span.original)` (the gate
reverted term→confusable and the user restored the term) — the newest harvested embedding for
`(term: span.original, label: span.replacement)` is **removed** and the label centroid
recomputed (or the label detached if nothing remains — D5). This makes a poisoned harvest
self-correcting through the exact same one-keystroke gesture that exposed it, and it is cheap
because the ring stores raw embeddings (D5).

### D2 — E-edit diff (conservative, zero-junk)

A pure utility: split before/after on whitespace; **require equal word counts**; collect
position-wise mismatching pairs; return them only if there are ≤ 3 (a hand-fix, not a rewrite);
otherwise return nil (insertions, deletions, reorders, and rewrites never harvest). Word cores
are compared affix-stripped/lowercased. This deliberately misses some genuine fixes (e.g. the
user also deleted a filler word) — zero-junk over recall, same posture as the rest of Concord.

### D3 — Span location + pooling (the retention design)

New per-utterance retention on AppState (Concord builds only):

- After a **cleanup** (non-refine) turn completes and correction highlights are applied, retain
  the utterance's `ASRDiagnostics` in a new `reviewDiagnostics` property — **only when**
  `encoderFeatures != nil`, at least one voiceprint is enrolled, and harvest is enabled
  (D6) — so users without voiceprints never pay the ~0.8 MB.
- Cleared at every terminal/invalidating state: `accept()`, discard/cancel, the start of the
  next dictation, the start of a refine turn, and app quit. (Same lifecycle discipline as
  `pendingContribution`.)

**Locating the span.** Rebuild word groups from `reviewDiagnostics.tokenTimings` via the
existing `VoiceprintDemo.wordGroups(from:)` (the same machinery `buildGate` and enrollment's
`localizedSpan` use, keeping the harvest span source identical to the enrollment span source),
then find the group for the corrected word by **normalized text + raw ordinal**:

- For trigger (a): the heard word (`span.original`) is the ASR's own output, so the raw groups
  contain it. Its raw ordinal is computable exactly from the overlay state:
  `rawOrdinal = (count of literal core-matching words before span.range in the shown text)
  + (count of spans with the same original before this span, in number order)` — because the
  dictionary stage preserves word order, un-substituted occurrences remain literal in the
  cleaned text and substituted ones are exactly the correction spans.
- For trigger (b): the term was emitted verbatim, so raw groups contain the term text. Its
  raw-emitted ordinal is `(count of literal core-matching words before the edited position in
  the before-text)` **minus** substituted spans don't count — they were NOT emitted:
  `rawOrdinal = literalMatchesBefore − substitutionSpansWithReplacementEqualTermBefore`.
- **Consistency guard (zero-junk):** the total number of matching raw groups must equal the
  expected total derived the same way; on any mismatch (a compound/number stage consumed an
  occurrence, ordinal drift — the known boundary documented in ConcordEngine), **skip the
  harvest silently**. A skipped harvest costs a future correction; a mislocated one poisons a
  template.

Pool via `features.pooledEmbedding(startSeconds: group.startSeconds, endSeconds:
group.endSeconds)`. All of this is in-memory float math on the MainActor at correction time —
synchronous, sub-millisecond, off the dictation hot path (constraint 5).

*Considered and rejected:* (i) capturing embeddings in a gate-time side-channel (tiny memory,
but misses trigger (b) whenever the validation pass wasn't contrastive-consulted, and couples
harvest to engine call-site behavior); (ii) retaining raw audio + re-transcribing at harvest
time, the enrollment pattern (works, but costs an encoder pass per correction and retains
biometric *audio* longer than the embeddings-only posture needs); (iii) extending Concord's
`EditRecord` with the gate's exact time span (best fidelity, but requires a Concord release —
noted as a fast-follow that would remove the ordinal-guard skips).

### D4 — Validation before attach (constraint 2, zero-junk)

A harvest candidate `(term, label, embedding)` is attached only if ALL hold:

1. **Phonetic confusability** (the Corrector-B validation idea): the label must *sound like*
   the term — `DoubleMetaphone.encode(label).primary == DoubleMetaphone.encode(term).primary`
   (both non-empty; Concord's public matcher, the same test the dictionary stage gates on) —
   **or** the label is already one of the term's aliases, **or** the label already has a
   negative prototype on the template (enrollment-declared confusable). A user undoing for
   semantic reasons ("Claude" → "assistant") fails this and never poisons the template.
2. **Embedding usability:** non-empty, all-finite (`VoiceprintMath.isUsable` semantics), and
   `count == template.dim` (checked before attach so a silent `withNegative` no-op can't
   masquerade as success).
3. **Single-word label**, alphabetic core (v1).
4. Harvest enabled + template present (D6).

*Considered and rejected — an acoustic self-similarity ceiling* ("skip if the embedding is too
close to the term voiceprint, it's probably the term itself"): measured confusable spans score
up to **0.922** against the term voiceprint (the Keavi/kiwi study), and every trigger-(a)
candidate was *by construction* accepted by the gate (one-class ⇒ cos ≥ 0.80), so any usable
ceiling would block genuine harvests. The junk defenses are instead: the user's explicit
correction gesture, the phonetic gate above, the bounded ring (one bad sample among ≤ 8 shifts
a centroid modestly), the revert path's own confident-margin requirement, and the healing rule
(D1 a′).

### D5 — Accumulation: bounded per-label harvest rings (constraint 3)

`withNegative` replaces the label centroid (fact 1), so the app keeps the raw material:

**New encrypted store** `~/.parleq/harvested-negatives.enc` — same AES-256-GCM + shared
`VoiceprintCryptoKey` (frozen Keychain constants, untouched) + `0600` temp + atomic-replace
pattern as `voiceprints.enc`. Content (embeddings only, never audio, never transcript):

```
HarvestedNegatives
└─ rings: [termID: [label: HarvestRing]]
   HarvestRing:
     embeddings:          [[Float]]   // FIFO, newest last, capped at maxPerLabel = 8
     enrollmentPrototype: [Float]?    // snapshot of the label's pre-harvest enrollment
                                      // centroid, if the wizard had enrolled this confusable
     modelVersion:        String      // voiceprintEncoderIdentity at first harvest
```

**On attach:** append the embedding; evict the oldest beyond **N = 8**; recompute
`negatives[label] = centroid(enrollmentPrototype? + ring embeddings)`; route through
`template.withNegative(label:embeddings:)` → `coordinator.commit(updated)` (fact 6 — the only
correct upsert+persist+gate-reinstall path).

**Why N = 8:** enrollment builds a prototype from 3–5 carrier clips, so 8 real over-fire
samples comfortably exceeds enrollment-grade statistical support; storage is bounded at
8 × 1024 × 4 B = 32 KB per label; and 8 bounds the half-life of a single junk sample (⅛ weight,
washed out by continued use). **Why FIFO (oldest-out):** voiceprints are mic/room/voice-drift
sensitive (ADR §6) — the newest samples are the most representative of the user's current
setup; quality-ranked eviction was rejected because there is no per-sample quality signal at
harvest time that isn't already the gate's own (circular).

**Merging with enrollment negatives (fact 3):** the label must stay the plain confusable word,
so an enrollment-derived prototype for the same label is snapshotted into
`enrollmentPrototype` on first harvest and thereafter contributes as one element of the
centroid. Harvested samples are real in-context over-fires — the exact distribution the gate
must reject — so weighting them ≥ the carrier-sentence prototype is intended, not a compromise.

**Healing:** remove the newest ring embedding; recompute; if the ring is empty →
`enrollmentPrototype` alone if present, else **detach the label** (rebuild the template via
`VoiceprintTemplate.init` with the label removed — `withNegative` cannot remove).

**Re-enrollment:** `commit` of a freshly-enrolled template for a term with existing rings
refreshes each ring's `enrollmentPrototype` from the new template's negatives (or nil) and
re-attaches the recomputed centroids, so a wizard re-run doesn't silently discard harvests.

**Encoder change:** rings are stamped with `voiceprintEncoderIdentity`; a ring whose stamp is
neither current nor legacy-compatible is **discarded** (embeddings can't cross feature spaces,
and — deliberately, for privacy — there is no stored audio to re-derive harvests from; they
regenerate from real usage). After durable-voiceprints migration re-derives a template, its
negatives are enrollment-derived only; stale rings are dropped in the same pass.

### D6 — Privacy & consent (constraint 4)

**Verdict: the existing voiceprint consent scope covers harvesting; a consent-copy amendment
and a kill-switch are required; a NEW consent flag is not.** Reasoning against the ADR:

- **Same data class, same posture.** A harvested negative is a pooled ~1024-float embedding —
  exactly the artifact class the ADR governs (embeddings-not-audio ✓), stored in the same
  encrypted-at-rest form under the same device-only non-synchronizable Keychain key
  (encrypted ✓), never transmitted (zero-egress ✓), on-device end-to-end (✓), and wiped by the
  existing per-term "Remove voiceprint" and "Delete all voiceprints" actions **plus** the new
  store is cleared in the same coordinator paths (deletable ✓). Durable-voiceprints required a
  *fresh amended* consent because it introduced a **new data class on disk** (audio); harvest
  introduces none.
- **What IS new:** the *source* — the embedding derives from a ~0.5 s span of a **dictation**
  utterance (the single corrected word only, never the sentence), not an enrollment carrier.
  That is a real disclosure delta, so: (i) the enrollment consent + Settings copy gains a line
  ("when you undo a correction on an enrolled term, Parleq refines that term's voiceprint
  using the corrected word's sound — never stored as audio, deleted with the voiceprint");
  (ii) `docs/SECURITY_REVIEW.md` §5.4 gains a "Correction-time negative harvest" paragraph +
  the §5 written-to-disk table gains the `harvested-negatives.enc` row.
- **Kill-switch:** new `voiceprintHarvestEnabled` (default **true** for enrolled terms —
  harvesting is the feature's entire value and only activates for terms the user explicitly
  enrolled under biometric consent), user-visible in the voice-enrollment Settings section and
  MDM-manageable, **fail-closed** on a malformed managed value (the
  `voiceprintClipStorageEnabled` pattern); toggling off stops harvesting and offers to clear
  harvested data (the rings + harvested contributions to templates).
- **Logging is count-only:** `[voiceprint] harvest: negative attached for '<term>' (ring k/8)`
  — the term name matches existing `[voiceprint]` practice (user-authored dictionary
  identifier); the confusable **label is never logged** (it is dictation-derived text).
- ⚠️ **Explicit maintainer sign-off requested** on the "no new consent flag" call — it is a
  judgment that "embedding of one corrected word from dictation" sits inside the enrolled
  user's existing biometric consent. If the maintainer disagrees, the fallback is a
  `voiceprintHarvestConsented` flag presented once (a one-line sheet on first harvestable
  correction), which slots into D6 without touching D1–D5.

Both invariants stay intact: audio is memory-only (nothing here touches audio at rest), and
the dictation hot path is unchanged (harvest runs at correction time; the only hot-path delta
is *retaining* an already-computed in-memory struct a little longer).

### D7 — Interaction with existing behavior

- `VoiceEnrollNudge` (unenrolled terms) is untouched; harvest handles the enrolled branch.
- `CorrectionJournal` records at undo/E-edit keep working unchanged (harvest is additive).
- The gate factory re-installs automatically via `commit` → `onStoreChanged` — the very next
  dictation runs contrastive.
- With harvest disabled or nothing enrolled, behavior is byte-identical to today (no
  retention, no new writes) — the corrector regression baseline is unaffected.

## Affected components

| Unit | Change |
|---|---|
| `HarvestedNegatives.swift` (new, ParleqAppCore) | ring model + `EncryptedHarvestStore` (shared key, 0600 atomic) + `HarvestedNegativePersistence` protocol |
| `VoiceprintDemo.swift` (`VoiceprintCoordinator`) | `harvestPersistence` injection; `harvestNegative(termID:label:embedding:aliases:)`; `healHarvestedNegative(termID:label:)`; ring reload/stamp check in `loadPersisted`; re-attach on `commit` of a re-enrollment; wipe wiring in `removeVoiceprint`/`removeAll`; drop stale rings in `migrateIfNeeded` |
| `AppState.swift` | `reviewDiagnostics` retention + lifecycle clears; trigger (a) + (a′) in `undoCorrection`; trigger (b) in `commitEdit`; span-locator use |
| `HarvestSpanLocator.swift` (new, pure) | ordinal math + word-group match + consistency guard (unit-testable without AppState) |
| `EditDiff.swift` (new, pure) | conservative 1:1 word-replacement diff |
| `Config.swift` / `ManagedConfig.swift` / `ManagedConfigAuditView.swift` | `voiceprintHarvestEnabled` (default true, MDM fail-closed, audit row) |
| `SettingsWindow.swift` | harvest toggle + amended consent/section copy; clear-harvests offer on toggle-off |
| `main.swift` | inject `EncryptedHarvestStore` into the coordinator |
| `docs/SECURITY_REVIEW.md` | §5 table row + §5.4 paragraph |

## Eval / validation (constraint 6)

**Unit tests (synthetic embeddings, `swift test --traits Concord`, `keyOverride` seams,
in-memory persistence spies):**
- Ring mechanics: append/FIFO-evict at 8/recompute; heal removes newest; empty-ring →
  prototype-only or label detached; re-enrollment re-attach; encoder-stamp mismatch drops ring.
- Attach path: harvest → `negatives[label]` centroid correct (with and without
  `enrollmentPrototype`); template `modelVersion`/`voiceprint`/`dim` preserved; persisted via
  the commit path (spy asserts one `save` with the union) — never a direct `persistence.save`.
- Validation: cloud/Claude passes DM; "assistant"/Claude rejected; alias and existing-label
  bypasses; wrong-dim / NaN / empty embeddings rejected *with a reported outcome* (not a
  silent no-op); multi-word labels rejected.
- Locator (pure): ordinal math for (a) and (b) incl. multiple occurrences, substituted +
  literal mixes; consistency-guard skip on count mismatch; affix stripping.
- EditDiff (pure): 1:1 replacement found; insert/delete/reorder/4+-change → nil.
- Gate effect: template with one harvested negative → `decide` goes contrastive;
  `evaluate(.validation)` reverts on a confident negative margin (synthetic vectors).
- Wipe: `removeVoiceprint`/`removeAll` clear rings + file; harvest disabled → no writes, no
  retention; kill-switch off clears on request.
- Compliance greps: no `[voiceprint]` log line contains a label/embedding; nothing under
  `~/.parleq/flywheel/` or `usage.jsonl` gains harvest content.

**Maintainer walkthrough script (real audio, both directions):**
1. Enroll "Claude" positive-only (skip the confusable step) → one-class template.
2. *Substitution direction:* add alias "cloud" to the Claude term; dictate "the cloud provider
   bills monthly" until the one-class gate over-fires (cloud → Claude in the overlay,
   highlighted). Press ⌥<n> to undo. Expect log `[voiceprint] harvest: negative attached for
   'Claude' (ring 1/8)` and `~/.parleq/harvested-negatives.enc` to appear.
3. Dictate the same sentence again → expect NO substitution this time (contrastive veto;
   `[concord]` shows the dictionary edit considered/rejected).
4. *Validation direction:* dictate a sentence where biasing makes the ASR emit "Claude" for a
   spoken "cloud" (vocabulary boosting active). Pre-harvest this survives; E-edit (E), change
   "Claude" → "cloud", ⌘⏎. Expect a second harvest log. Dictate again → expect the
   validate-revert to fire (overlay shows Claude→cloud as a numbered correction).
5. *Healing:* undo that revert (⌥<n>) → expect `[voiceprint] harvest: healed 'Claude'
   (ring 1/8)` and the next dictation to keep the emitted term.
6. Settings → Delete all voiceprints → confirm `harvested-negatives.enc` is gone.
7. Toggle "Refine voiceprints from corrections" off → confirm corrections stop harvesting.

**Regression gate:** `CorrectorRegressionHarnessTests` (real flywheel audio) vs the committed
`corrector-baseline.json` must show no per-intent recovery/over-fire change — the harness runs
with no harvested rings, where the feature is inert by construction (D7). Full app test suite
green under both build configs (with and without `--traits Concord`).

## Open questions (maintainer)

1. **Consent verdict sign-off** (D6): amend-copy + kill-switch, or a one-time
   `voiceprintHarvestConsented` sheet?
2. **Default for `voiceprintHarvestEnabled`** — spec says ON for enrolled terms; confirm.
3. Should trigger (a′) healing ALSO decrement on undo of a *vetoed-then-manually-redone* case?
   (Out of v1; listed for awareness.)
4. Fast-follow appetite: extend Concord `EditRecord` with the gate's exact time span (removes
   the ordinal-guard skips) — ride the next Concord release?
