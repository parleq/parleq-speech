# Flywheel Contribution Capture — Implementation Plan

> Implements `docs/explorations/2026-06-17-flywheel-contribution-capture-design.md`. No formal test target exists in this repo (CLAUDE.md: verification = `swift build` + manual end-to-end), so each task's gate is `swift build` (from `parleq-app/`) and the behavioral checks are bundled into the final walkthrough section for the maintainer.

**Goal:** An opt-in, acknowledgment-gated contribution mode that durably persists per-dictation audio + transcripts + ASR diagnostics + provenance into `~/.parleq/flywheel/`, walled off from the shipped product invariants.

**Architecture:** A per-utterance `pendingContribution` builder accumulates on `AppState` through the cleanup pipeline (reset on fresh capture, appended on refine), then is flushed once to a `ContributionRecorder` actor at the terminal state (accept/discard). The recorder does all disk I/O off the MainActor, fail-silent. ASR diagnostics are plumbed `LocalASR → ASRClient → AppState`. Arming is a hand-edited top-level `contribution` config block matched against an exact acknowledgment string; the block is preserved verbatim across Settings saves.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, FluidAudio `ASRResult`/`TokenTiming`, `JSONEncoder`/`JSONSerialization`.

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `Sources/ParleqAppCore/ContributionRecorder.swift` | New. Actor owning `~/.parleq/flywheel/`; `ContributionRecord` model; manifest append + WAV write; cumulative-bytes tracking; fail-silent. | Create |
| `Sources/ParleqAppCore/ASRClient.swift` | Add `ASRDiagnostics` + `VocabReplacement` Codable structs; enrich `ASRTranscript` with optional `diagnostics`. | Modify |
| `Sources/ParleqAppCore/LocalASR.swift` | `transcribe(wav:vocabulary:)` returns text + diagnostics (base `ASRResult` subset + `rescored.replacements`). | Modify |
| `Sources/ParleqAppCore/Config.swift` | Add `contributionCaptureArmed: Bool`; load from `contribution.capture` vs exact phrase; preserve `contribution` block in `mergeForSave`. | Modify |
| `Sources/ParleqAppCore/AppState.swift` | `pendingContribution` builder; populate through pipeline; flush at `accept()`/`cancel()`; add retained `lastCleanedText`. | Modify |
| `CLAUDE.md` | Annotate invariants #1/#2/#7 with the armed-contribution carve-out. | Modify |
| `docs/SECURITY_REVIEW.md` | Disclosure section for contribution mode. | Modify |
| `docs/explorations/2026-06-17-flywheel-contribution-capture-design.md` | Correct schema: `vocab_replacements` (our rescorer) replaces the FluidAudio `ctc*` fields, which stay nil on our path. | Modify |

---

## Task 1: Config — arming flag

**Files:** Modify `Sources/ParleqAppCore/Config.swift`

- [ ] **Step 1: Add the acknowledgment constant + field.** Near the top-level Config constants, add:
```swift
/// Exact acknowledgment phrase that arms the (hidden, undocumented)
/// flywheel contribution-capture mode. A bare `true` or any other
/// value does NOT arm it — the gesture must be deliberate and
/// informed. Documented only in docs/SECURITY_REVIEW.md.
static let contributionCaptureAck = "i-understand-this-writes-my-audio-and-transcripts-to-disk"
```
Add to the `Config` struct (default false, NOT in the `features` block):
```swift
/// Armed contribution mode (flywheel capture). Off unless the user
/// hand-edits config.json with the exact acknowledgment phrase.
/// Never surfaced in Settings/wizard; carve-out to invariants #1/#2/#7.
public var contributionCaptureArmed: Bool = false
```

- [ ] **Step 2: Load it.** In `load()`, after the `features` block parse, add:
```swift
if let contribution = parsed["contribution"] as? [String: Any],
   let capture = contribution["capture"] as? String {
    c.contributionCaptureArmed = (capture == Config.contributionCaptureAck)
}
```

- [ ] **Step 3: Preserve the block on save.** In `mergeForSave(_:existing:)`, just before `return dict`, add:
```swift
// Preserve the hidden contribution-capture block verbatim across
// saves. It is intentionally NOT modeled in serializeToDictionary
// (so Settings never writes or re-exposes it); copy it through from
// disk so a Settings save can't silently drop a contributor's flag.
if let contribution = existingDict["contribution"] {
    dict["contribution"] = contribution
}
```

- [ ] **Step 4: Gate.** `cd parleq-app && swift build` → expect success. Commit.

---

## Task 2: ASR diagnostics plumbing

**Files:** Modify `Sources/ParleqAppCore/ASRClient.swift`, `Sources/ParleqAppCore/LocalASR.swift`

- [ ] **Step 1: Define Codable diagnostics types** (in `ASRClient.swift`, near `ASRTranscript`):
```swift
/// One CTC vocab-rescorer replacement (Parleq's own rescorer, richer
/// than FluidAudio's term-list-only ctcApplied/Detected). Captured
/// only into the armed flywheel corpus — NEVER logged (the existing
/// count-only [vocab] log line is unchanged).
public struct VocabReplacement: Codable, Sendable {
    public let original: String
    public let replacement: String?
    public let reason: String
    public let applied: Bool
}

/// Per-token timing + confidence, mirrored from FluidAudio.TokenTiming
/// so our on-disk shape doesn't bind to the dependency type.
public struct ASRTokenTiming: Codable, Sendable {
    public let token: String
    public let tokenId: Int
    public let startTime: Double
    public let endTime: Double
    public let confidence: Float
}

/// ASR diagnostics for the flywheel. Populated only on the bundled
/// LocalASR path; nil on the external HTTP path.
public struct ASRDiagnostics: Codable, Sendable {
    public let confidence: Float
    public let durationSec: Double
    public let processingSec: Double
    public let tokenTimings: [ASRTokenTiming]
    public let replacements: [VocabReplacement]
}
```

- [ ] **Step 2: Enrich `ASRTranscript`.** Add `public let diagnostics: ASRDiagnostics?` with a defaulted initializer param so existing constructions stay valid.

- [ ] **Step 3: `LocalASR.transcribe` returns diagnostics.** Change the return type to `(text: String, diagnostics: ASRDiagnostics)`. Build the diagnostics from the in-method `asrResult` (confidence/duration/processingTime/tokenTimings) and, after rescoring, from `rescored.replacements` (map `originalWord`/`replacementWord`/`reason`/`shouldReplace`). When vocabulary is empty / no timings (early return), return diagnostics with empty `replacements`. Map `FluidAudio.TokenTiming` → `ASRTokenTiming`.

- [ ] **Step 4: ASRClient threads it.** In `transcribe`, the bundled branch builds `ASRTranscript(text:latency:diagnostics:)`; the HTTP branch passes `diagnostics: nil`.

- [ ] **Step 5: Gate.** `swift build` → success. (LocalASR's only caller is ASRClient; verify no other callers broke.) Commit.

---

## Task 3: ContributionRecorder

**Files:** Create `Sources/ParleqAppCore/ContributionRecorder.swift`

- [ ] **Step 1: Record model.** A `Sendable` struct carrying all manifest fields + `wav: Data?` + `id: UUID` + `timestamp: Date`. Mirror the design schema field names. Include `disposition`, `rawASR`, `cleaned`, `final`, `cleanupFailed`, `diagnostics: ASRDiagnostics?`, `vocabulary: [String]`, `asrModel`, `fluidaudioVersion`, `llm`, `appBundle`, `referenceWindowsAttached`, `transformApplied`, `refined`, `refineTurns`, `spelloutTerms`. `corrector_pair_eligible` is derived at encode time.

- [ ] **Step 2: Actor.** `actor ContributionRecorder` with `static let shared`. Owns `~/.parleq/flywheel/` paths. Lazy-seed `cumulativeBytes` by scanning the dir once. `func capture(_ record: ContributionRecord) async`:
  - do/catch wrapping ALL I/O; on error, `logStderr("[parleq] contribution capture failed (write error)")` count-only and return.
  - create `flywheel/` + `flywheel/audio/` if missing.
  - write `audio/<id>.wav` if `record.wav != nil`.
  - build the JSON line via `JSONEncoder` (a private Codable DTO with snake_case keys + derived `corrector_pair_eligible` + `corpus_bytes`); append `\n` to `manifest.jsonl` (open-for-append `FileHandle`, or read-modify-write if small).
  - increment `cumulativeBytes` by written sizes; stamp `corpus_bytes` with the post-write total.
  - Use ISO8601 for `ts`. NO transcript content in any log line.

- [ ] **Step 3: Gate.** `swift build` → success. Commit.

---

## Task 4: AppState wiring

**Files:** Modify `Sources/ParleqAppCore/AppState.swift`

- [ ] **Step 1: Builder + retained cleaned text.** Add:
```swift
/// Retained LLM-cleaned text (pre manual-edit), for the flywheel's
/// `cleaned` field. Set alongside currentText in applyResult; cleared
/// in closeAndReset.
private var lastCleanedText: String?

/// Per-utterance flywheel accumulator. Reset on fresh capture,
/// appended on refine, flushed+cleared at the terminal state. nil
/// when no dictation is in flight or capture isn't relevant.
private var pendingContribution: PendingContribution?
```
Define a private struct `PendingContribution` holding: `id: UUID`, `rawASR`, `diagnostics: ASRDiagnostics?`, `vocabulary: [String]`, `referenceWindowsAttached: Bool`, `transformApplied: Bool`, `refined: Bool`, `refineTurns: [(instruction,before,after)]`, `spelloutTerms: [String]`, `appBundle: String?`, plus stamps (asrModel, fluidaudioVersion, llm). Audio is read from `lastDictationAudio` at flush time.

- [ ] **Step 2: Reset on fresh capture.** At the start of `runCleanupPipeline` for a fresh (non-refine) capture, after `lastRawTranscript` is set (~line 2991), create a new `PendingContribution(id: UUID(), ...)` and populate `rawASR`, `diagnostics` (from the `ASRTranscript`), `vocabulary`, stamps, `appBundle` (from the paste target). For a refine, DO NOT reset; instead append a refine turn.

- [ ] **Step 3: Capture diagnostics.** Plumb the `ASRTranscript.diagnostics` from the `asrClient.transcribe` result into `pendingContribution.diagnostics`. (Confirm the transcribe call site retains the full transcript, not just `.text`.)

- [ ] **Step 4: reference + transform + cleaned.** At the cleanup-invocation site (~line 3045), set `pendingContribution?.referenceWindowsAttached = !effectiveRefs.isEmpty`. At ~line 3135 set `pendingContribution?.transformApplied = (!asRefine && defaultPreset != nil && outcome.usedLLMOutput)`. In `applyResult`, set `lastCleanedText = text` when the result came from a successful cleanup (not a raw fallback). On a refine turn append `(instruction: asrResult.text, before: priorText, after: outcome.text)` to `refineTurns` and set `refined = true`. Capture `spelloutTerms` from `SpellOutDetector.candidates(in: rawASR)` for the fresh pass.

- [ ] **Step 5: Flush at accept().** After `appendTranscriptHistory(...)` (~line 1859), add:
```swift
flushContribution(disposition: .accepted, final: currentText)
```

- [ ] **Step 6: Flush at cancel().** Early in `cancel()` (before teardown), add:
```swift
flushContribution(disposition: .discarded, final: nil)
```

- [ ] **Step 7: flushContribution helper.**
```swift
private func flushContribution(disposition: ContributionDisposition, final: String?) {
    guard let pending = pendingContribution else { return }
    pendingContribution = nil
    guard !pending.rawASR.isEmpty else { return }           // need a completed ASR result
    guard Config.load().config.contributionCaptureArmed else { return }
    let record = pending.makeRecord(
        disposition: disposition,
        cleaned: lastCleanedText,
        final: final,
        cleanupFailed: lastCleanupFailed,
        wav: lastDictationAudio?.wav
    )
    Task.detached { await ContributionRecorder.shared.capture(record) }
}
```
Clear `pendingContribution`/`lastCleanedText` in `closeAndReset` too (defensive). Define `ContributionDisposition` enum (`accepted`/`discarded`).

- [ ] **Step 8: Gate.** `swift build` → success. Commit. Run RoboRev review on the branch so far.

---

## Task 5: Docs + spec correction

**Files:** Modify `CLAUDE.md`, `docs/SECURITY_REVIEW.md`, the design spec

- [ ] **Step 1: CLAUDE.md invariants.** Append to invariants #1, #2, #7 a sentence: an armed-contribution-mode carve-out exists (opt-in, hidden config, off by default, never network-transmitted) — see `docs/SECURITY_REVIEW.md`. The invariant holds literally for every user who has not armed the flag.

- [ ] **Step 2: SECURITY_REVIEW.md.** Add a §X "Contribution capture mode (opt-in, hidden)" disclosing: what's captured (audio + transcripts + ASR diagnostics + provenance), where (`~/.parleq/flywheel/`), the exact acknowledgment-string arming gesture, that it is off by default and absent from Settings/wizard/README/public docs, and that **the app never transmits the corpus** (capture is local; contributing is a manual act; the recorder has no network code).

- [ ] **Step 3: Spec correction.** In the design doc, replace the `ctcDetectedTerms`/`ctcAppliedTerms` schema fields with `vocab_replacements: [{original, replacement, reason, applied}]` and a note that FluidAudio's `ctc*` fields stay nil on our path because Parleq does its own richer rescoring.

- [ ] **Step 4: Commit.**

---

## Task 6: Verify + review

- [ ] **Step 1:** `cd parleq-app && swift build` (debug) → success.
- [ ] **Step 2:** RoboRev review of the full branch; address findings; re-review until clean.
- [ ] **Step 3:** Build the debug app (`scripts/make-app.sh --debug`) to confirm bundle builds.
- [ ] **Step 4:** Write the maintainer walkthrough steps (below) for behavioral verification — these require live dictation and are the maintainer's to run.

### Maintainer walkthrough (behavioral — deferred to maintainer)
1. **Disarmed:** no `contribution` block AND a bare `"contribution": {"capture": true}` → dictate → confirm `~/.parleq/flywheel/` is NOT created.
2. **Armed:** set the exact phrase → dictate (accept) → confirm one `manifest.jsonl` line + one WAV, `disposition:"accepted"`, `asr` populated, `corrector_pair_eligible:true`.
3. **Discard:** Esc a dictation → confirm a `disposition:"discarded"`, `final:null` record + WAV.
4. **Refine:** dictate then refine → confirm `refined:true`, `corrector_pair_eligible:false`, refine turn recorded.
5. **Reference window:** attach a reference → confirm `reference_windows_attached:true`, eligible false.
6. **Settings round-trip:** open/close Settings while armed → confirm the `contribution` block survives in config.json and never appears in the UI.
7. **Manual edit:** dictate, edit text in the overlay, accept → confirm eligible true, `cleaned` ≠ `final`.

---

## Self-review notes
- **Spec coverage:** audio+text+diagnostics capture (T2/T3/T4); skip base text (no task — intentional omission); unbounded manual storage (T3); acknowledgment-gated hidden block (T1); separate component (T3); both dispositions (T4); provenance→eligibility (T4 + recorder derive); invariant/security docs (T5). All covered.
- **Type consistency:** `ASRDiagnostics`/`ASRTokenTiming`/`VocabReplacement` defined in T2, consumed in T3/T4. `PendingContribution`/`ContributionDisposition` defined T4. `contributionCaptureArmed`/`contributionCaptureAck` defined T1, read T4.
- **No test target:** TDD steps replaced by `swift build` gate + maintainer walkthrough, per CLAUDE.md.
