# Voiceprint Negative Auto-Harvest — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** When the user corrects a dictionary-term over-fire (⌥n per-correction undo, or an E-edit changing an enrolled term back to a common word), pool that word's audio-span embedding from the utterance's retained encoder features and attach it as a negative prototype to the term's voiceprint — converting weak one-class templates into the proven contrastive kind through real usage, with no new enrollment UX.

**Architecture:** A new encrypted app-side store (`~/.parleq/harvested-negatives.enc`, same AES-GCM + shared `VoiceprintCryptoKey` as `voiceprints.enc`) keeps a bounded FIFO ring (N=8) of raw harvested embeddings per (term, confusable label), so the label centroid can be recomputed on every attach and *healed* when the user undoes a gate revert. AppState retains the utterance's `ASRDiagnostics` (with in-memory `encoderFeatures`, ~0.8 MB) from cleanup completion until the overlay's terminal state, so correction-time pooling is pure in-memory math (`EncoderFeatureSequence.pooledEmbedding`) — no audio retention, no re-transcribe. Harvest candidates are validated before attach: DoubleMetaphone primary-code agreement (or alias / existing-label membership), single-word alphabetic label, usable right-dimension embedding, and a conservative ordinal consistency guard on span location (skip on ambiguity — zero-junk). All mutations persist through `VoiceprintCoordinator.commit(_:)` (the only path that unions `pendingMigration`, saves, and re-installs the gate factory).

**Tech Stack:** Swift 6, SwiftPM, XCTest, CryptoKit (AES-GCM), Security (Keychain), Concord (trait-gated, `#if Concord` — public API only: `VoiceprintTemplate.withNegative`/`init`, `DoubleMetaphone.encode`), FluidAudio fork (`EncoderFeatureSequence.pooledEmbedding`).

**Spec:** `docs/superpowers/specs/2026-07-02-voiceprint-negative-harvest-design.md`.

## Global Constraints

- All harvest code is `#if Concord`. Build/test with `swift test --traits Concord`; the public build (no trait) must stay green and byte-identical in behavior.
- **Persist only via `VoiceprintCoordinator.commit(_:)`** for template changes — never `persistence.save` directly (bypasses the `pendingMigration` union and the gate re-install; see durable-voiceprints SI-1).
- **Embeddings only, never audio, never transcript text** in the new store. No `[voiceprint]` log line may contain a confusable label or embedding values; term names + counts only (existing practice).
- **Zero-junk over recall:** every ambiguity (ordinal mismatch, multi-word, non-confusable, unusable embedding, refine turn) resolves to *skip harvest silently*, never to a best-effort attach.
- Frozen Keychain constants (`VoiceprintCryptoKey.keyService/.keyAccount`) are reused, untouched.
- Harvest gating read fresh at harvest time via `Config.load()` (managed overlay applies); `voiceprintHarvestEnabled` fails CLOSED on a malformed managed value.
- Tests use the `keyOverride:`/`fileURL:` seams (the `swift test` binary lacks Keychain access) and in-memory persistence spies.
- Commit style: `feat(voiceprint): …` / `test(voiceprint): …` / `docs(voiceprint): …`. Co-author: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Line-number anchors below were verified 2026-07-02 against `main` (da3aac4); re-verify before editing (code moves).

## File structure

- `Sources/ParleqAppCore/HarvestedNegatives.swift` — **new**. Ring model, `HarvestedNegativePersistence` protocol, `EncryptedHarvestStore`, `HarvestPolicy`.
- `Sources/ParleqAppCore/HarvestSpanLocator.swift` — **new, pure**. Core-word normalization, ordinal math for both triggers, consistency guard.
- `Sources/ParleqAppCore/EditDiff.swift` — **new, pure**. Conservative 1:1 word-replacement diff.
- `Sources/ParleqAppCore/VoiceprintDemo.swift` — **modify**. `harvestPersistence` injection; in-memory `harvested` cache; `harvestNegative` / `healHarvestedNegative` / `clearAllHarvests`; ring load + stamp check; re-attach on re-enrollment `commit`; wipe wiring; shared `groupSpans(from:)` helper.
- `Sources/ParleqAppCore/AppState.swift` — **modify**. `reviewDiagnostics` retention + lifecycle; trigger (a)/(a′) in `undoCorrection`; trigger (b) in `commitEdit`.
- `Sources/ParleqAppCore/Config.swift`, `ManagedConfig.swift`, `ManagedConfigAuditView.swift` — **modify**. `voiceprintHarvestEnabled` (default true, MDM fail-closed, audit row).
- `Sources/ParleqAppCore/SettingsWindow.swift` — **modify**. Toggle + copy amendment + clear-harvests offer.
- `Sources/parleq-app/main.swift` — **modify**. Inject `EncryptedHarvestStore()`.
- `docs/SECURITY_REVIEW.md` — **modify**. §5 table row + §5.4 paragraph.
- Tests: `Tests/ParleqAppCoreTests/HarvestedNegativesTests.swift`, `HarvestSpanLocatorTests.swift`, `EditDiffTests.swift`, `VoiceprintHarvestCoordinatorTests.swift`, `HarvestConfigTests.swift`.

---

# Phase 1 — Storage & coordinator

## Task 1: `HarvestedNegatives` model + `EncryptedHarvestStore`

**Files:** Create `Sources/ParleqAppCore/HarvestedNegatives.swift`; Test `Tests/ParleqAppCoreTests/HarvestedNegativesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  #if Concord
  public struct HarvestRing: Codable, Sendable, Equatable {
      public var embeddings: [[Float]]          // FIFO, newest LAST, capped at HarvestPolicy.maxPerLabel
      public var enrollmentPrototype: [Float]?  // pre-harvest enrollment centroid for this label, if any
      public var modelVersion: String           // BundledASREngine.voiceprintEncoderIdentity at first harvest
      public init(embeddings: [[Float]] = [], enrollmentPrototype: [Float]? = nil, modelVersion: String)
  }
  public struct HarvestedNegatives: Codable, Sendable, Equatable {
      public var rings: [String: [String: HarvestRing]]   // termID → label → ring
      public init(rings: [String: [String: HarvestRing]] = [:])
      public var isEmpty: Bool
  }
  public protocol HarvestedNegativePersistence: Sendable {
      func load() throws -> HarvestedNegatives
      func save(_ negatives: HarvestedNegatives) throws   // empty ⇒ deleteAll (file removed)
      func deleteAll() throws
  }
  public struct EncryptedHarvestStore: HarvestedNegativePersistence {
      public init(fileURL: URL = <~/.parleq/harvested-negatives.enc>, keyOverride: SymmetricKey? = nil)
  }
  public enum HarvestPolicy {
      public static let maxPerLabel = 8
      public static let maxEditReplacements = 3   // EditDiff cap (Task 5)
  }
  #endif
  ```

- [ ] **Step 1: Failing tests** in `HarvestedNegativesTests.swift` (`#if Concord`, `keyOverride` seam, temp `fileURL`):
  - round-trip: save a `HarvestedNegatives` with 2 terms / 2 labels / rings incl. `enrollmentPrototype` → load equals.
  - `save(HarvestedNegatives())` (empty) removes the file; `load()` on a missing file returns empty (not throw).
  - file mode is `0600` after save; a corrupted blob (`Data([0x00])`) throws (never silently truncates).
- [ ] **Step 2: Run, verify fail** — `swift test --traits Concord --filter HarvestedNegativesTests`.
- [ ] **Step 3: Implement** `EncryptedHarvestStore` mirroring `EncryptedVoiceprintStore.swift` structurally: `VoiceprintCryptoKey.key(override:)` for the key; `load()` = read → `AES.GCM.SealedBox(combined:)` → `open` → `JSONDecoder`; missing file → `HarvestedNegatives()`; `save` = encode → `seal` → `0600` temp + `replaceItemAt` (`.usingNewMetadataOnly`); empty ⇒ `deleteAll()`. Reuse the same error enum shape (`sealFailed`/`writeFailed`/`keychain`).
- [ ] **Step 4: Run** — green.
- [ ] **Step 5: Commit** — `feat(voiceprint): encrypted harvested-negatives store (bounded per-label rings)`.

## Task 2: Config key `voiceprintHarvestEnabled` (default true, MDM fail-closed)

**Files:** Modify `Config.swift`, `ManagedConfig.swift` (managed key list), `ManagedConfigAuditView.swift`; Test `Tests/ParleqAppCoreTests/HarvestConfigTests.swift`

**Interfaces:**
- Produces: `Config.voiceprintHarvestEnabled: Bool` (default `true`), managed key string `"voiceprintHarvestEnabled"`, fail-closed overlay behavior identical to `voiceprintClipStorageEnabled` (`applyManagedOverlay` uses the presence-aware helper: a managed value present-but-not-explicitly-true resolves OFF and marks managed).

- [ ] **Step 1: Failing tests** — decode a config JSON without the key → `true`; with `false` → `false`; managed overlay with a malformed value (string `"false"`) → resolves `false` + key in `managedKeys` (reuse the existing `ClipStorageMDMTests` pattern/harness).
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — add the field next to `voiceprintClipStorageEnabled` (Config.swift:660 area, default at :813 area); wire `applyManagedOverlay` (:937-961 area) with the same fail-closed branch; add the audit row in `ManagedConfigAuditView.swift`; add to the managed key list (`ManagedConfig.swift:127-133`).
- [ ] **Step 4: Run** — green (also run the full `--filter Config` set for regressions).
- [ ] **Step 5: Commit** — `feat(voiceprint): voiceprintHarvestEnabled config key (MDM fail-closed)`.

## Task 3: Coordinator harvest/heal/clear + ring lifecycle

**Files:** Modify `Sources/ParleqAppCore/VoiceprintDemo.swift`, `Sources/parleq-app/main.swift`; Test `Tests/ParleqAppCoreTests/VoiceprintHarvestCoordinatorTests.swift`

**Interfaces:**
- Produces (on `VoiceprintCoordinator`):
  ```swift
  public var harvestPersistence: HarvestedNegativePersistence?   // injected from main.swift

  public enum HarvestOutcome: Equatable {
      case attached(ringCount: Int)
      case healed(ringCount: Int)
      case rejected(HarvestRejection)
  }
  public enum HarvestRejection: Equatable {
      case noTemplate, phoneticMismatch, unusableEmbedding, multiWordLabel, disabled
  }

  /// Validate + append to the (termID,label) ring + recompute the label centroid + commit.
  @discardableResult
  public func harvestNegative(termID: String, label: String, embedding: [Float],
                              aliases: [String] = [], harvestEnabled: Bool) -> HarvestOutcome
  /// Remove the NEWEST harvested embedding for (termID,label); recompute or detach the label.
  @discardableResult
  public func healHarvestedNegative(termID: String, label: String) -> HarvestOutcome
  /// Remove every ring; restore each affected template's labels to enrollment prototypes only.
  public func clearAllHarvests()
  ```
- Modifies: `loadPersisted()` (load + stamp-check rings), `commit(_:)` (re-attach rings on re-enrollment), `removeVoiceprint(termID:)` / `removeAll()` (wipe rings), `migrateIfNeeded(transcribe:)` (drop stale rings).

- [ ] **Step 1: Failing tests** (synthetic embeddings — e.g. orthogonal unit vectors dim 4; in-memory `HarvestedNegativePersistence` + `VoiceprintPersistence` spies recording `save` payloads):
  - happy path: template one-class (no negatives) + `harvestNegative(term:"Claude", label:"cloud", …)` → `.attached(1)`; template now has `negatives["cloud"]` == the embedding; `VoiceprintDecision.usedContrastive == true` on a subsequent `decide`; template `modelVersion`/`voiceprint`/`dim` unchanged; the voiceprint-persistence spy saw exactly one save (via `commit`).
  - accumulation: 3 harvests → centroid of the 3 (compare against a hand-computed mean); 9 harvests → ring holds newest 8 (FIFO), oldest evicted.
  - enrollment merge: template with a wizard-enrolled `negatives["cloud"]` → first harvest snapshots it into `enrollmentPrototype` and the new centroid = mean(prototype + ring).
  - heal: after 2 harvests, `healHarvestedNegative` removes the NEWEST → centroid == first embedding (+prototype if present); heal to empty **with** prototype → label centroid == prototype; heal to empty **without** prototype → label **detached** (template rebuilt via `VoiceprintTemplate.init` without the label; `decide` returns to one-class).
  - validation: label `"assistant"` vs term `"Claude"` → `.rejected(.phoneticMismatch)`; label == a supplied alias bypasses DM; label already in `template.negatives` bypasses DM; NaN / wrong-dim / empty embedding → `.rejected(.unusableEmbedding)`; `"two words"` → `.rejected(.multiWordLabel)`; `harvestEnabled: false` → `.rejected(.disabled)` and **no** persistence call.
  - wipe: `removeVoiceprint(termID:)` clears that term's rings + persists; `removeAll()` empties the harvest store (file gone via spy).
  - re-enrollment: `commit` of a fresh template for a term with rings → labels re-attached from rings (and `enrollmentPrototype` refreshed from the new template's own negatives / nil).
  - stamp: a ring with `modelVersion` neither current nor legacy-compatible is dropped at `loadPersisted`.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** on `VoiceprintCoordinator`:
  ```swift
  #if Concord
  private var harvested = HarvestedNegatives()

  private static func isUsable(_ v: [Float], dim: Int) -> Bool {
      v.count == dim && !v.isEmpty && v.allSatisfy { $0.isFinite }
  }
  private static func phoneticallyConfusable(label: String, term: String,
                                             aliases: [String], existing: Set<String>) -> Bool {
      let l = label.lowercased()
      if aliases.contains(where: { $0.lowercased() == l }) { return true }
      if existing.contains(where: { $0.lowercased() == l }) { return true }
      let lp = DoubleMetaphone.encode(label).primary
      let tp = DoubleMetaphone.encode(term).primary
      return !lp.isEmpty && lp == tp
  }

  @discardableResult
  public func harvestNegative(termID: String, label: String, embedding: [Float],
                              aliases: [String] = [], harvestEnabled: Bool) -> HarvestOutcome {
      guard harvestEnabled else { return .rejected(.disabled) }
      guard let template = store.template(for: termID) else { return .rejected(.noTemplate) }
      guard !label.contains(" "), label.allSatisfy({ $0.isLetter }) else { return .rejected(.multiWordLabel) }
      guard Self.isUsable(embedding, dim: template.dim) else { return .rejected(.unusableEmbedding) }
      guard Self.phoneticallyConfusable(label: label, term: termID, aliases: aliases,
                                        existing: Set(template.negatives.keys)) else {
          return .rejected(.phoneticMismatch)
      }
      let key = label.lowercased()
      // ⚠️ RoboRev-7484 Low: enrollment may have stored the negative under a mixed-case label,
      // so look up the prototype case-insensitively (do NOT assume template.negatives keys are
      // already lowercased — that is a Concord-side invariant we don't control at pin 0.3.7).
      let enrollmentProto = template.negatives.first { $0.key.lowercased() == key }?.value
      var ring = harvested.rings[termID]?[key]
          ?? HarvestRing(enrollmentPrototype: enrollmentProto,  // snapshot BEFORE first harvest
                         modelVersion: BundledASREngine.voiceprintEncoderIdentity)
      ring.embeddings.append(embedding)
      if ring.embeddings.count > HarvestPolicy.maxPerLabel {
          ring.embeddings.removeFirst(ring.embeddings.count - HarvestPolicy.maxPerLabel)
      }
      harvested.rings[termID, default: [:]][key] = ring
      // withNegative pools the centroid internally — pass prototype + ring raw material.
      let material = (ring.enrollmentPrototype.map { [$0] } ?? []) + ring.embeddings
      // withNegative writes under the lowercase `key`; if enrollment had stored the same
      // confusable under a DIFFERENTLY-cased key (e.g. "Cloud"), that stale entry survives as a
      // shadow negative — the gate would then see the enrollment prototype twice and skew the
      // contrastive threshold. Strip any non-`key` casing of the same label BEFORE re-writing.
      // (RoboRev-7484 / 7488 Low.)
      let cleaned = template.negatives.filter { $0.key == key || $0.key.lowercased() != key }
      let base = cleaned.count == template.negatives.count ? template
          : VoiceprintTemplate(termID: template.termID, voiceprint: template.voiceprint,
                               negatives: cleaned, dim: template.dim,
                               lowQuality: template.lowQuality, modelVersion: template.modelVersion)
      let updated = base.withNegative(label: key, embeddings: material)
      commit(updated)                                    // upsert + persist + gate re-install
      try? harvestPersistence?.save(harvested)
      FileHandle.standardError.write(
          "[voiceprint] harvest: negative attached for '\(termID)' (ring \(ring.embeddings.count)/\(HarvestPolicy.maxPerLabel))\n"
              .data(using: .utf8) ?? Data())              // count-only; label NEVER logged
      return .attached(ringCount: ring.embeddings.count)
  }
  #endif
  ```
  `healHarvestedNegative`: drop `embeddings.removeLast()`; recompute via the same `material` expression; if `material.isEmpty` → rebuild the template with `negatives` minus the label via `VoiceprintTemplate.init(termID:voiceprint:negatives:dim:lowQuality:modelVersion:)`, else `withNegative`; `commit`; persist; count-only heal log. `clearAllHarvests`: for each ring, restore label to `enrollmentPrototype` or detach; `commit` each; `harvested = .init()`; `try? harvestPersistence?.deleteAll()`.
  Lifecycle hooks: `loadPersisted()` loads `harvested` (drop rings whose `modelVersion` is neither `BundledASREngine.voiceprintEncoderIdentity` nor in `legacyCompatibleStamps`); `removeVoiceprint`/`removeAll` clear + persist; `migrateIfNeeded` drops rings for migrated terms before re-derivation; `commit` gains the re-attach pass (guard against recursion: perform re-attach only when the committed template's negatives don't already reflect the rings — compute the merged template FIRST, then call the underlying upsert+notify once).
  Inject in `main.swift` (coordinator construction, ~:1416-1470 area): `coordinator.harvestPersistence = EncryptedHarvestStore()` **before** `loadPersisted()`.
- [ ] **Step 4: Run** — task tests + `--filter Voiceprint` green.
- [ ] **Step 5: Commit** — `feat(voiceprint): coordinator negative harvest/heal/clear with bounded rings`.

---

# Phase 2 — Pure locator + diff utilities

## Task 4: `HarvestSpanLocator` (ordinal math + consistency guard)

**Files:** Create `Sources/ParleqAppCore/HarvestSpanLocator.swift`; Test `Tests/ParleqAppCoreTests/HarvestSpanLocatorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  #if Concord
  enum HarvestSpanLocator {
      struct GroupSpan: Equatable {
          let text: String            // normalized (same normalizer as buildGate's SpanEmbedding)
          let startSeconds: Double
          let endSeconds: Double
      }
      /// Affix-stripped, lowercased word core (mirrors ConcordEngine.splitAffixes semantics app-side).
      static func core(_ word: String) -> String
      /// Trigger (a): raw ordinal of the undone span's heard word. Inputs come from the
      /// PRE-revert overlay state. Returns nil when the consistency guard fails.
      static func rawOrdinalForUndo(shownText: String, spanRange: Range<String.Index>,
                                    original: String,
                                    allSpans: [(number: Int, original: String)],
                                    spanNumber: Int,
                                    groupMatchCount: Int) -> Int?
      /// Trigger (b): raw-EMITTED ordinal of the term at word index `wordIndex` in beforeText.
      /// Substitution spans (replacement == term) are subtracted — they were not ASR-emitted.
      static func rawOrdinalForEdit(beforeText: String, wordIndex: Int, term: String,
                                    substitutionSpanStarts: [String.Index],
                                    substitutionSpanTotal: Int,
                                    groupMatchCount: Int) -> Int?
      /// The k-th group whose normalized text core-matches `word`; nil if out of range.
      static func locate(groups: [GroupSpan], word: String, rawOrdinal: Int) -> GroupSpan?
  }
  #endif
  ```
  Ordinal formulas (spec D3): undo → `literalCoreMatchesBefore(spanRange) + priorSameOriginalSpans`, guarded by `groupMatchCount == literalTotal + sameOriginalSpanTotal`; edit → `coreMatchesBefore(wordIndex) − substitutionSpanStartsBefore`, guarded by `groupMatchCount == coreMatchTotal − substitutionSpanTotal`.

- [ ] **Step 1: Failing tests** (pure, no Concord types needed beyond the trait gate):
  - `core("Cloud,")` == `"cloud"`; `core("(cloud)")` == `"cloud"`.
  - undo single occurrence: text `"the Claude provider"`, one span (original `"cloud"`) → ordinal 0, guard passes with `groupMatchCount == 1`.
  - undo mixed: text `"cloud one Claude two cloud"` (middle was substituted; 2 literal + 1 span) → span ordinal 1; guard requires `groupMatchCount == 3`; `groupMatchCount == 2` → nil (skip).
  - edit: before `"ask Claude about the cloud"` where the first `"Claude"` was ASR-emitted (no substitution spans) → wordIndex 1 → ordinal 0; with a substitution span before it → ordinal decremented; guard mismatch → nil.
  - `locate` returns the k-th matching group; k out of range → nil.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.** Word splitting = whitespace split (Concord's convention); core = trim non-letters from both ends + lowercase.
- [ ] **Step 4: Run** — green.
- [ ] **Step 5: Commit** — `feat(voiceprint): pure harvest span locator with ordinal consistency guard`.

## Task 5: `EditDiff` (conservative 1:1 word replacements)

**Files:** Create `Sources/ParleqAppCore/EditDiff.swift`; Test `Tests/ParleqAppCoreTests/EditDiffTests.swift`

**Interfaces:**
- Produces:
  ```swift
  #if Concord
  enum EditDiff {
      struct WordReplacement: Equatable {
          let before: String   // original word (verbatim, with affixes)
          let after: String
          let wordIndex: Int   // index into the whitespace-split before-text
      }
      /// nil unless the edit is expressible as ≤ HarvestPolicy.maxEditReplacements pure
      /// position-wise word replacements (equal word counts; no insert/delete/reorder).
      static func singleWordReplacements(before: String, after: String) -> [WordReplacement]?
  }
  #endif
  ```

- [ ] **Step 1: Failing tests:** `"use Claude here"` → `"use cloud here"` = one replacement (index 1); two replacements OK; 4 mismatches → nil; word-count change (insert/delete) → nil; identical strings → `[]`.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** (split, count-equality guard, position-wise mismatch collection, cap).
- [ ] **Step 4: Run** — green.
- [ ] **Step 5: Commit** — `feat(voiceprint): conservative E-edit word-replacement diff`.

---

# Phase 3 — AppState wiring

## Task 6: Review-acoustics retention + pooling helper

**Files:** Modify `Sources/ParleqAppCore/AppState.swift`, `Sources/ParleqAppCore/VoiceprintDemo.swift` (extract shared group-span helper)

**Interfaces:**
- Produces (AppState, `#if Concord`):
  ```swift
  /// The current review utterance's diagnostics (token timings + in-memory encoder features),
  /// retained ONLY while the overlay is reviewable, ONLY when a voiceprint is enrolled and
  /// harvest is enabled. ~0.8 MB; embeddings/features never leave process memory.
  private var reviewDiagnostics: ASRDiagnostics?
  private func retainReviewAcoustics(_ diagnostics: ASRDiagnostics?)
  private func clearReviewAcoustics()
  /// Locate + pool one word-span embedding from the retained features. nil ⇒ skip harvest.
  private func harvestEmbedding(word: String, rawOrdinal: Int) -> (embedding: [Float], matchCount: Int)?
  /// Count of retained groups whose core matches `word`, WITHOUT pooling (feeds the ordinal
  /// consistency guard). nil ⇒ no retained diagnostics. (RoboRev-7484 Low: avoids the wasted
  /// mean-pooling pass that a probe `harvestEmbedding(…, rawOrdinal: 0)` call would incur.)
  private func groupMatchCount(for word: String) -> Int?
  ```
- Produces (VoiceprintCoordinator or a static on `VoiceprintDemo`): `groupSpans(from diagnostics: ASRDiagnostics) -> [HarvestSpanLocator.GroupSpan]` — factored from the existing `buildGate` word-group construction (VoiceprintDemo.swift:779-826) so harvest, enrollment, and the gate share one span source (same `wordGroups(from:)` + the same text normalizer that fills `SpanEmbedding.normalizedText`).

- [ ] **Step 1: Extract** `groupSpans(from:)` from `buildGate`'s group-building block (pure refactor; `buildGate` calls it). Run the full `--filter Voiceprint` suite — behavior unchanged.
- [ ] **Step 2: Implement retention.** `retainReviewAcoustics` guards: `diagnostics?.encoderFeatures != nil`, `voiceprint?.enrolledTermIDs.isEmpty == false`, `Config.load().config.voiceprintHarvestEnabled`. Call it where correction highlights are applied after a non-refine cleanup (`AppState.swift:3372-3376` area, alongside `applyCorrectionHighlights`), passing the same diagnostics forwarded to `streamCleanupOrRefine` (:3319 area). Call `clearReviewAcoustics()` at: `accept()`, the discard/cancel path(s), dictation start (`runCleanupPipeline` entry), refine-turn start, and wherever `pendingContribution` is flushed (same terminal-state map — verify each anchor at edit time).
- [ ] **Step 3: Implement `harvestEmbedding` + `groupMatchCount`:**
  ```swift
  private func groupMatchCount(for word: String) -> Int? {
      guard let d = reviewDiagnostics, d.encoderFeatures != nil else { return nil }
      let target = HarvestSpanLocator.core(word)
      return VoiceprintDemo.groupSpans(from: d)
          .filter { HarvestSpanLocator.core($0.text) == target }.count
  }
  private func harvestEmbedding(word: String, rawOrdinal: Int) -> (embedding: [Float], matchCount: Int)? {
      guard let d = reviewDiagnostics, let features = d.encoderFeatures else { return nil }
      let groups = VoiceprintDemo.groupSpans(from: d)
      let target = HarvestSpanLocator.core(word)
      let matches = groups.filter { HarvestSpanLocator.core($0.text) == target }
      guard let g = HarvestSpanLocator.locate(groups: groups, word: word, rawOrdinal: rawOrdinal)
      else { return nil }
      guard let emb = features.pooledEmbedding(startSeconds: g.startSeconds, endSeconds: g.endSeconds)
      else { return nil }
      return (emb, matches.count)
  }
  ```
- [ ] **Step 4: Build both configs** — `swift build` and `swift build --traits Concord` green (no behavior change yet).
- [ ] **Step 5: Commit** — `feat(voiceprint): retain review-utterance acoustics for correction-time harvest`.

## Task 7: Trigger (a) undo harvest + (a′) healing

**Files:** Modify `Sources/ParleqAppCore/AppState.swift` (`undoCorrection(number:)`, :1872-1921)

- [ ] **Step 1: Capture pre-mutation state.** At the top of `undoCorrection` (before `CorrectionHighlight.revert` mutates `currentText`/spans), snapshot `let preText = currentText`, `let preSpans = spans` for the ordinal math.
- [ ] **Step 2: Extend the existing `switch span.stage`** (:1908-1916) — keep the `VoiceEnrollNudge` branch for unenrolled terms; add:
  ```swift
  case .dictionary, .acousticDictionary, .sayAsPhrase:
      let term = span.replacement
      #if Concord
      if let vp = voiceprint, vp.hasVoiceprint(span.original), span.stage == .dictionary {
          // (a′) the user undid a validate-REVERT (term on the ORIGINAL side): heal.
          vp.healHarvestedNegative(termID: span.original, label: span.replacement.lowercased())
      } else if let vp = voiceprint, vp.hasVoiceprint(term), span.stage == .dictionary {
          // (a) the user undid a dictionary over-fire on an enrolled term: harvest.
          harvestNegativeFromUndo(span: span, preText: preText, preSpans: preSpans)
      } else if voiceprint != nil, !(voiceprint?.hasVoiceprint(term) ?? false) {
          VoiceEnrollNudge.shared.suggest(term: term, confusedWith: span.original)
      }
      #endif
  ```
- [ ] **Step 3: Implement `harvestNegativeFromUndo`:**
  ```swift
  #if Concord
  private func harvestNegativeFromUndo(span: CorrectionSpan, preText: String,
                                       preSpans: [CorrectionSpan]) {
      let cfg = Config.load().config
      guard cfg.voiceprintHarvestEnabled else { return }
      guard let matchCount = groupMatchCount(for: span.original) else { return }
      let allSpans = preSpans.map { (number: $0.number, original: $0.original) }
      guard let ordinal = HarvestSpanLocator.rawOrdinalForUndo(
          shownText: preText, spanRange: span.range, original: span.original,
          allSpans: allSpans, spanNumber: span.number, groupMatchCount: matchCount)
      else { return }                                     // consistency guard: skip silently
      guard let hit = harvestEmbedding(word: span.original, rawOrdinal: ordinal) else { return }
      let aliases = dictionaryAliases(forTerm: span.replacement)   // from the loaded custom dictionary
      voiceprint?.harvestNegative(termID: span.replacement, label: span.original.lowercased(),
                                  embedding: hit.embedding, aliases: aliases,
                                  harvestEnabled: cfg.voiceprintHarvestEnabled)
  }
  #endif
  ```
  (`dictionaryAliases(forTerm:)` — small helper reading the same `DictionaryEntry` list AppState already loads per utterance for `setUtteranceDictionary`.)
- [ ] **Step 4: Manual smoke** (build + run debug app): enroll a term, force an alias over-fire, ⌥1, confirm the count-only harvest log + `harvested-negatives.enc` appears; confirm undoing a revert heals.
- [ ] **Step 5: Commit** — `feat(voiceprint): harvest negative on per-correction undo; heal on revert-undo`.

## Task 8: Trigger (b) E-edit harvest

**Files:** Modify `Sources/ParleqAppCore/AppState.swift` (`commitEdit(accept:)`, :1796-1822)

- [ ] **Step 1: Capture pre-remap spans, then hook inside the `edited != editPreEditText` branch.**
  ⚠️ **RoboRev-7484 Medium:** by the time `recordInPlaceEdit` runs, `overlay.model.correctionSpans`
  has already been re-mapped against `edited` (the AFTER text) at AppState.swift:1808-1813, so its
  `range.lowerBound` `String.Index` values index into `edited`, NOT `editPreEditText`. Passing them to
  `rawOrdinalForEdit(beforeText: editPreEditText, …)` compares cross-string indices (undefined in Swift)
  and yields wrong ordinal subtraction in multi-occurrence edits. **Snapshot the spans BEFORE the remap
  block** (right after `guard` at the top of the `if edited != editPreEditText {` body, before line 1808):
  ```swift
  #if Concord
  let preEditSpans = overlay.model.correctionSpans   // pre-remap: ranges index into editPreEditText
  #endif
  ```
  The existing remap at :1808-1813 proceeds unchanged. Then, after `recordInPlaceEdit`:
  ```swift
  #if Concord
  harvestNegativesFromEdit(before: editPreEditText, after: edited, spans: preEditSpans)
  #endif
  ```
- [ ] **Step 2: Implement:**
  ```swift
  #if Concord
  private func harvestNegativesFromEdit(before: String, after: String, spans: [CorrectionSpan]) {
      let cfg = Config.load().config
      guard cfg.voiceprintHarvestEnabled, let vp = voiceprint else { return }
      guard let replacements = EditDiff.singleWordReplacements(before: before, after: after)
      else { return }
      for r in replacements {
          let termCore = HarvestSpanLocator.core(r.before)
          guard let termID = vp.enrolledTermIDs.first(where: { $0.lowercased() == termCore })
          else { continue }
          // Skip if the edited occurrence IS a substitution span (that audio is the heard
          // confusable, not an emitted term — trigger (a) covers it via undo). Zero-junk v1.
          let subs = spans.filter { HarvestSpanLocator.core($0.replacement) == termCore }
          guard let matchCount = groupMatchCount(for: r.before) else { continue }
          guard let ordinal = HarvestSpanLocator.rawOrdinalForEdit(
              beforeText: before, wordIndex: r.wordIndex, term: r.before,
              substitutionSpanStarts: subs.map { $0.range.lowerBound },
              substitutionSpanTotal: subs.count, groupMatchCount: matchCount)
          else { continue }
          guard let hit = harvestEmbedding(word: r.before, rawOrdinal: ordinal) else { continue }
          vp.harvestNegative(termID: termID, label: HarvestSpanLocator.core(r.after),
                             embedding: hit.embedding,
                             aliases: dictionaryAliases(forTerm: termID),
                             harvestEnabled: cfg.voiceprintHarvestEnabled)
      }
  }
  #endif
  ```
  (`rawOrdinalForEdit` returns nil when `wordIndex` falls inside a substitution span — encode that in the locator so it's unit-tested, not hand-checked here.)
- [ ] **Step 3: Manual smoke:** dictate so the ASR emits the term verbatim for a spoken confusable; E-edit term→confusable, ⌘⏎; confirm harvest log; dictate again → validate-revert fires.
- [ ] **Step 4: Commit** — `feat(voiceprint): harvest negative from E-edit term→common-word replacement`.

---

# Phase 4 — Surface, docs, validation

## Task 9: Settings toggle + copy, SECURITY_REVIEW, final validation

**Files:** Modify `SettingsWindow.swift`, `docs/SECURITY_REVIEW.md`; maintainer-run gates

- [ ] **Step 1: Settings.** In the voice-enrollment section: managed-aware toggle **"Refine voiceprints from corrections"** bound to `voiceprintHarvestEnabled` (`.disabled` when managed, matching the clip-storage toggle). On toggle-off: confirm sheet offering "Also clear refinements learned so far" → `coordinator.clearAllHarvests()`. Amend the enrollment consent + section copy with the disclosure line (spec D6): "When you undo a correction on an enrolled term, Parleq refines that term's voiceprint using the corrected word's sound — stored as an encrypted embedding, never audio; deleted with the voiceprint."
- [ ] **Step 2: SECURITY_REVIEW.** §5 written-to-disk table: add the `~/.parleq/harvested-negatives.enc` row (biometric-derived embeddings, AES-256-GCM under the same device-only key, `0600`, embeddings-only, deleted with voiceprints / delete-all / the harvest toggle's clear offer). §5.4: add a "Correction-time negative harvest" paragraph (source = the single corrected word's ~0.5 s span from a dictation utterance; embeddings only; count-only logging; `voiceprintHarvestEnabled` user/MDM fail-closed kill-switch; consent-copy amendment; the review-window in-memory retention of `ASRDiagnostics.encoderFeatures` until overlay terminal state).
- [ ] **Step 3: Compliance sweep.** `grep -rn "harvest" Sources/ | grep -i "write\|log\|stderr"` — every log line count-only, no label/embedding content; confirm nothing harvest-related is `Codable`-reachable from the flywheel record.
- [ ] **Step 4: Full validation.**
  - `swift build` (no trait) + `swift test` — public build green, zero behavior change.
  - `swift test --traits Concord` — full suite green.
  - **Maintainer-run:** `CorrectorRegressionHarnessTests` vs `corrector-baseline.json` — no per-intent recovery/over-fire delta (feature inert with no harvested rings).
  - **Maintainer walkthrough** (spec "Eval / validation", steps 1–7): both harvest directions, healing, delete-all wipe, toggle-off.
- [ ] **Step 5: Commit** — `docs(voiceprint): disclose correction-time negative harvest (Settings copy + SECURITY_REVIEW §5.4)`.
- [ ] **Step 6: HOLD at the approval gate.** Version bump + CHANGELOG ride the release PR per the house workflow; do not push without explicit maintainer approval.
