// LearnedStore — the apply/suggest/revert surface for "learn from
// corrections". Receives validated LearningProposals from
// LearningAnalyzer and routes each: high-confidence, non-colliding term
// adds/modifies auto-apply into the custom dictionary (tagged
// source=.learned, revertibly); everything else (low confidence, retire,
// or anything touching a user-authored entry) becomes a pending
// suggestion. Style proposals are deferred — slice 1 has no consumer.
//
// Pending suggestions and the applied-changes/revert log are in-memory
// only — cleared on quit. The durable output (learned dictionary terms)
// persists in config.json, the same as hand-added terms. Dictionary
// mutations go through Config.save so they're picked up per-utterance
// like any hand-edited dictionary change.

import Combine
import Foundation

/// What to do with a single proposal.
enum LearnedRoute: String, Sendable, Equatable {
    case autoApply
    case suggest
    case deferStyle
}

/// One row in the unified "Recent activity" history (the bounded,
/// in-memory ring shown below the actionable pending suggestions). Every
/// Accept/Dismiss across all three suggestion kinds (term, preset,
/// per-app default) lands here as a kept entry, newest first, marked by
/// outcome — so accepting the last pending item shows a tally + history
/// instead of snapping straight back to "Nothing learned yet", and a
/// misclicked Dismiss can be Restored.
///
/// The entry carries enough to (a) reconstruct the original pending
/// suggestion for Restore (so Restore still works after the suggestion
/// itself would have aged out), and (b) revert an accept (delete the
/// created preset, remove the app-default mapping, or — for terms —
/// delegate to the existing AppliedChange term-revert path via
/// `termAppliedChangeID`). In-memory only, wiped on quit, same as the
/// pending list and correction ring; the durable artifacts an accept
/// produces (presets / app-defaults / learned terms in config.json)
/// persist regardless.
struct ActivityEntry: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, Equatable { case term, preset, appDefault }
    enum Outcome: String, Sendable, Equatable {
        case accepted, dismissed, reverted, restored
    }

    let id: UUID
    var timestamp: Date
    let kind: Kind
    var outcome: Outcome
    /// Human-readable summary shown in the row (e.g. "Created preset
    /// 'Concise'", "Set 'Concise' as default for Mail", "Added term
    /// 'Mira'", "Dismissed: preset 'Concise'").
    var summary: String

    // --- Restore payload (a dismissed entry carries one of these) ---
    /// The original pending suggestion (term/preset kinds), so Restore
    /// re-injects it verbatim — including the editable preset name/prompt.
    let pendingSuggestion: LearnedStore.PendingSuggestion?
    /// The original per-app default suggestion, for the appDefault kind.
    let presetDefaultSuggestion: PresetDefaultSuggestion?

    // --- Revert payload (an accepted entry carries the right one) ---
    /// For accepted preset: the id of the created TransformPreset to delete.
    let createdPresetID: String?
    /// For accepted app-default: the bundle id whose mapping to remove
    /// (paired with `createdPresetID` so a later, different default isn't
    /// clobbered).
    let appDefaultBundleID: String?
    /// For accepted term: the AppliedChange row id to drive the existing
    /// term-revert path (reused, not reinvented).
    let termAppliedChangeID: UUID?
    /// For preset entries: the ORIGINAL proposal's content hash (the one
    /// the analyzer suppression keys on), captured before any user edit to
    /// the name/prompt. Revert clears exactly this hash so re-proposal of
    /// the original recurring pattern is un-suppressed — the user's edited
    /// prompt may hash differently, so the restorable suggestion's hash
    /// can't stand in. nil for non-preset kinds.
    let originalPresetHash: String?

    init(id: UUID, timestamp: Date, kind: Kind, outcome: Outcome, summary: String,
         pendingSuggestion: LearnedStore.PendingSuggestion?,
         presetDefaultSuggestion: PresetDefaultSuggestion?,
         createdPresetID: String?, appDefaultBundleID: String?,
         termAppliedChangeID: UUID?, originalPresetHash: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.outcome = outcome
        self.summary = summary
        self.pendingSuggestion = pendingSuggestion
        self.presetDefaultSuggestion = presetDefaultSuggestion
        self.createdPresetID = createdPresetID
        self.appDefaultBundleID = appDefaultBundleID
        self.termAppliedChangeID = termAppliedChangeID
        self.originalPresetHash = originalPresetHash
    }
}

/// A record of an applied change, enough to revert it.
struct AppliedChange: Sendable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let term: String
    let rationale: String
    /// The dictionary entry that existed before we applied (for a modify);
    /// nil when this was a fresh add (revert = remove).
    let priorEntry: DictionaryEntry?
    /// The entry we wrote (for an add/modify); nil for a retire (we removed
    /// it). Revert compares the *live* entry against this snapshot: if they
    /// differ, the user has edited the term since we applied, so the row is
    /// stale — revert drops the row and leaves the user's version alone.
    let appliedEntry: DictionaryEntry?
}

@MainActor
final class LearnedStore: ObservableObject {
    static let shared = LearnedStore()

    @Published private(set) var pendingSuggestions: [PendingSuggestion] = []
    @Published private(set) var appliedChanges: [AppliedChange] = []

    /// Unified "Recent activity" history: every accept/dismiss/revert/
    /// restore across all three suggestion kinds, newest first. Bounded
    /// in-memory ring (see `maxActivityEntries`), wiped on quit. Term
    /// accepts/reverts also keep their `appliedChanges` row (the existing
    /// term-revert mechanism) — this log links to it by id rather than
    /// duplicating the revert logic.
    @Published private(set) var activityLog: [ActivityEntry] = []

    /// Soft cap on the in-memory activity ring. Oldest entries evict past
    /// this. Kept small — it's a recovery/recap surface, not an audit log.
    nonisolated static let maxActivityEntries = 20

    /// Bridge 2: per-app default suggestions computed from the durable
    /// preset-usage journal. Refreshed off the hot path (on Learned-view
    /// open) — NOT recomputed per dictation. Independent of the
    /// learn-from-corrections feature: gated on transformPresetsEnabled
    /// only, since the journal is plain metadata, not the correction ring.
    @Published private(set) var presetDefaultSuggestions: [PresetDefaultSuggestion] = []

    /// Injectable journal so tests don't touch the real ~/.parleq path.
    private let usageJournal: PresetUsageJournal

    /// Cap on concurrently-pending PRESET suggestions (Bridge 1). Term
    /// suggestions are uncapped (one-per-term dedupe bounds them); preset
    /// suggestions are capped low so a chatty analyzer can't bury the UI.
    nonisolated static let maxPendingPresetSuggestions = 3

    /// Content-hashes of preset suggestions the user DISMISSED, so the
    /// same distilled prompt isn't re-proposed. In-memory only this pass
    /// (wiped on quit) — a deliberate scope choice: a durable decline
    /// store would be the only on-disk artifact this bridge adds, and the
    /// analyzer's rate cap + recurrence threshold already make immediate
    /// re-proposal unlikely. A dismissed preset can resurface after a
    /// restart if the pattern keeps recurring; documented in the report.
    private var dismissedPresetHashes: Set<String> = []

    /// Stable content hash of a preset proposal's distilled prompt (the
    /// name is editable / cosmetic, so it's excluded). Case/space-folded
    /// so trivially-different phrasings of the same instruction collapse.
    nonisolated static func presetContentHash(_ proposal: LearningProposal) -> String {
        // Fold case, drop punctuation, collapse whitespace so trivially-
        // different phrasings of the same instruction ("Make it concise."
        // vs "make it concise") share a hash — this keys both the
        // dismissal-suppression and restore-bypass logic (review finding,
        // flagged twice).
        let folded = (proposal.presetPrompt ?? "")
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(folded)
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// A suggestion awaiting Accept/Dismiss. Holds the underlying
    /// proposal directly so Accept can apply it through the same path.
    struct PendingSuggestion: Sendable, Identifiable, Equatable {
        let id: UUID
        let term: String?
        let rationale: String
        let proposal: LearningProposal
        /// The aliases the matching dictionary entry already had when this
        /// suggestion was queued, so the UI can show what accepting keeps
        /// (accept unions, never replaces). nil when there was no prior.
        let priorAliases: [String]?
    }

    private convenience init() { self.init(usageJournal: .shared) }

    /// Designated init — `usageJournal` is injectable to keep Bridge 2
    /// testable against a temp-dir journal, but kept `private` so the
    /// singleton stays the only instance (no divergent @Published state).
    private init(usageJournal: PresetUsageJournal) {
        self.usageJournal = usageJournal
    }

    /// Delete any legacy on-disk file from an earlier disk-backed build
    /// of this feature. The store is in-memory only now; this removes
    /// stragglers so no learned-suggestion data lingers on disk. Called
    /// unconditionally at launch (from `AppState.init`) — NOT from this
    /// lazy `init`, which wouldn't run when the feature is off — and
    /// again from the purge path (`clearAll()`). Best-effort; nonisolated
    /// so the launch path can call it without touching the singleton.
    nonisolated static func purgeLegacyOnDiskFile() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parleq/learned.json", isDirectory: false)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Pure routing (unit-tested)

    nonisolated static func route(_ proposal: LearningProposal, against dictionary: [DictionaryEntry]) -> LearnedRoute {
        // Bridge 1: a preset proposal is NEVER auto-applied — it always
        // becomes a pending suggestion the user reviews, edits, and
        // confirms (or dismisses). The presets feature is a creative
        // surface; silent creation is out of scope by design.
        if proposal.kind == .preset { return .suggest }
        if proposal.kind == .style { return .deferStyle }
        // Retire is higher-impact — always confirm.
        if proposal.op == .retire { return .suggest }
        // Below threshold — suggest.
        if proposal.confidence < LearningAnalyzer.autoApplyConfidenceThreshold { return .suggest }
        // Collision with a USER-authored entry — never silently overwrite,
        // and never auto-apply when the proposal's term OR any of its
        // aliases overlaps a user entry's term OR aliases. The ASR
        // vocabulary rescorer biases on aliases too, so an aliased
        // collision could make Parleq emit the learned canonical term
        // when the user says their own protected word. Any overlap →
        // confirm via suggestion instead.
        var proposalStrings: [String] = []
        if let term = proposal.term { proposalStrings.append(term) }
        if let aliases = proposal.aliases { proposalStrings.append(contentsOf: aliases) }
        proposalStrings = proposalStrings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var userStrings: [String] = []
        for entry in dictionary where entry.source == .user {
            userStrings.append(entry.term)
            userStrings.append(contentsOf: entry.aliases)
        }
        let collidesWithUserEntry = proposalStrings.contains { p in
            userStrings.contains { $0.caseInsensitiveCompare(p) == .orderedSame }
        }
        if collidesWithUserEntry { return .suggest }
        // Quality bar: reject low-quality / collision-prone TERM proposals
        // from AUTO-APPLY (they fall through to a pending suggestion the
        // user can still accept by hand). Catches bare common words
        // ("scholarly"/"item"), all-common multi-word phrases ("line item",
        // "dictation released"), and phonetic collisions with a common word
        // or an existing dictionary term ("iTerm"~"item", "parallel"~
        // "Parleq"). Conservative: when uncertain, suggest, don't auto-add.
        // Only term proposals reach here (preset/style/retire returned
        // above); guard the term anyway.
        if proposal.kind == .term, let term = proposal.term,
           LearnedTermQualityBar.rejectionReason(term: term, existing: dictionary) != nil {
            return .suggest
        }
        return .autoApply
    }

    // MARK: - Pure apply (unit-tested)

    /// Aliases for a modify/merge: keep the existing entry's aliases and
    /// append any newly-proposed ones not already present (case-insensitive,
    /// existing order preserved). A modify/merge therefore never silently
    /// drops aliases the entry already had — it only ever adds.
    nonisolated static func unionAliases(prior: [String], proposed: [String]) -> [String] {
        var seen = Set(prior.map { $0.lowercased() })
        var result = prior
        for alias in proposed where seen.insert(alias.lowercased()).inserted {
            result.append(alias)
        }
        return result
    }

    /// Apply a term proposal to a dictionary in place. Add = append a
    /// learned entry; modify/merge on an existing entry = update it,
    /// preserving identity and unioning aliases (never dropping existing
    /// ones). Always tags source=.learned.
    ///
    /// Auto-applied entries are written WITHOUT the proposal's freeform
    /// `context` — the user never reviewed it, so we persist only the
    /// canonical term and its (already word-level bounded) aliases. Context
    /// is kept only for entries the user explicitly accepts (see `accept`).
    ///
    /// Biasing defaults to `.asrAndLLM` for auto-learned entries — they get
    /// FULL value, including FluidAudio CTC biasing, so a genuinely mangled
    /// jargon term is fixed at the ASR source (the whole point of learning).
    /// Safe to do here because the gate for ASR biasing is DISTINCTIVENESS,
    /// not learned-vs-curated: an entry only reaches this auto-apply path
    /// after passing `LearnedTermQualityBar` (route → .autoApply), which
    /// REJECTS the collision-prone short terms that over-fire ("iTerm"~"item",
    /// "parallel"~"Parleq") and routes them to suggestions instead. So every
    /// term that lands here is already distinctive enough to bias safely.
    /// (Residual risk: the collision check's common-word set is bounded, so a
    /// collision with a rare word could slip through — low blast radius and
    /// revertible.) A modify preserves the existing entry's biasing.
    nonisolated static func applyTermProposal(_ proposal: LearningProposal, to dictionary: inout [DictionaryEntry]) {
        guard proposal.kind == .term, let term = proposal.term else { return }
        let prior = dictionary.first { $0.term.caseInsensitiveCompare(term) == .orderedSame }
        let mergedAliases = unionAliases(prior: prior?.aliases ?? [], proposed: proposal.aliases ?? [])
        // ASR biasing requires the WHOLE entry to be distinctive. The term reached this auto-apply
        // path by passing the quality bar, but its ALIASES are unchecked — a collision-prone alias
        // ("item") under asrAndLLM would over-fire just like a collision-prone term (the canonical
        // is emitted whenever the common-word alias matches). So only default to asrAndLLM when every
        // alias is also collision-safe; otherwise fall back to llmOnly (still helps cleanup).
        // Check aliases against the dictionary MINUS this entry — an alias is by nature a phonetic
        // variant of its OWN canonical ("parlay"~"Parleq"), so collision against self is expected
        // and must not downgrade. The real risks are an alias that's a common word ("item") or
        // collides with a DIFFERENT term — both still caught.
        let others = dictionary.filter { $0.term.caseInsensitiveCompare(term) != .orderedSame }
        let aliasesSafe = mergedAliases.allSatisfy {
            LearnedTermQualityBar.rejectionReason(term: $0, existing: others) == nil
        }
        let entry = DictionaryEntry(
            term: term,
            context: nil,
            aliases: mergedAliases,
            spokenForms: prior?.spokenForms ?? [],   // preserve say-as phrases across a learned merge
            // Alias safety OVERRIDES prior biasing: even a MODIFY of an existing .asrAndLLM entry
            // must drop to .llmOnly when it gains a collision-prone alias, else the unsafe alias
            // keeps driving ASR over-firing. asrAndLLM only when EVERY alias is safe.
            biasing: aliasesSafe ? (prior?.biasing ?? .asrAndLLM) : .llmOnly,
            source: .learned
        )
        if let idx = dictionary.firstIndex(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
            dictionary[idx] = entry
        } else {
            dictionary.append(entry)
        }
    }

    /// Record (or update) the single applied-change row for `term`. Keeps
    /// at most ONE row per term: if a row already exists, its ORIGINAL
    /// prior (the pre-learning state) is preserved and the row is refreshed
    /// + moved to front. This means reverting always undoes to the state
    /// before learning first touched the term, and reverting can never
    /// delete a newer learned change for the same term (there's only one).
    private func recordApplied(term: String, rationale: String, prior: DictionaryEntry?, applied: DictionaryEntry?) {
        var priorEntry = prior
        if let i = appliedChanges.firstIndex(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
            // Preserve the ORIGINAL pre-learning state; refresh the applied
            // snapshot to the newest change.
            let old = appliedChanges.remove(at: i)
            priorEntry = old.priorEntry
        }
        appliedChanges.insert(AppliedChange(
            id: UUID(), timestamp: Date(), term: term, rationale: rationale,
            priorEntry: priorEntry, appliedEntry: applied
        ), at: 0)
    }

    // MARK: - Activity log (unified history)

    /// Push a new entry to the front of the activity ring and evict the
    /// oldest past the cap. Newest-first ordering matches the UI.
    private func pushActivity(_ entry: ActivityEntry) {
        activityLog = Self.ringByPrepending(entry, to: activityLog)
    }

    /// Pure ring insert-and-evict (unit-tested): prepend newest, then drop
    /// the oldest beyond `maxActivityEntries`.
    nonisolated static func ringByPrepending(
        _ entry: ActivityEntry, to log: [ActivityEntry]
    ) -> [ActivityEntry] {
        var out = log
        out.insert(entry, at: 0)
        if out.count > maxActivityEntries {
            out.removeLast(out.count - maxActivityEntries)
        }
        return out
    }

    /// A short tally over the activity log for the recap line shown when
    /// there are no pending suggestions but history exists (e.g.
    /// "3 presets created · 2 terms learned · 1 dismissed"). Reverted/
    /// restored outcomes don't add to the "created/learned" counts; an
    /// active dismissal counts as dismissed. Pure over the log so it's
    /// unit-testable.
    nonisolated static func tally(_ log: [ActivityEntry]) -> String {
        var presets = 0, terms = 0, defaults = 0, dismissed = 0
        for e in log {
            switch e.outcome {
            case .accepted:
                switch e.kind {
                case .preset: presets += 1
                case .term: terms += 1
                case .appDefault: defaults += 1
                }
            case .dismissed:
                dismissed += 1
            case .reverted, .restored:
                break // no longer counts toward an active accept/dismiss
            }
        }
        var parts: [String] = []
        func plural(_ n: Int, _ singular: String, _ plural: String) -> String {
            "\(n) \(n == 1 ? singular : plural)"
        }
        if presets > 0 { parts.append(plural(presets, "preset created", "presets created")) }
        if terms > 0 { parts.append(plural(terms, "term learned", "terms learned")) }
        if defaults > 0 { parts.append(plural(defaults, "app default set", "app defaults set")) }
        if dismissed > 0 { parts.append(plural(dismissed, "dismissed", "dismissed")) }
        return parts.joined(separator: " · ")
    }

    /// Insert a pending suggestion at the front, skipping it if one for the
    /// same term is already queued (case-insensitive). Across analysis runs
    /// the LLM can re-propose the same below-threshold term; this keeps one
    /// card per term, mirroring `recordApplied`'s one-row-per-term rule.
    private func insertSuggestionIfNew(_ s: PendingSuggestion) {
        // A term-less suggestion (no slice-1 producer; .style routes to
        // .deferStyle) can't be deduped by term — insert it as-is rather than
        // collapsing all nil-term suggestions, or matching an empty-string term.
        guard let term = s.proposal.term else {
            pendingSuggestions.insert(s, at: 0)
            return
        }
        guard !pendingSuggestions.contains(where: {
            $0.proposal.term?.caseInsensitiveCompare(term) == .orderedSame
        }) else { return }
        pendingSuggestions.insert(s, at: 0)
    }

    /// Count of currently-pending preset suggestions (Bridge 1).
    var pendingPresetCount: Int {
        pendingSuggestions.reduce(0) { $0 + ($1.proposal.kind == .preset ? 1 : 0) }
    }

    /// Pure eligibility gate (unit-tested): is this preset proposal
    /// admissible given the feature gates, dismissed hashes, the hashes
    /// already pending, and the remaining headroom under the cap? A blank
    /// hash, a dismissed hash, a duplicate of a pending one, or no
    /// remaining slots → not eligible.
    nonisolated static func presetSuggestionEligible(
        _ proposal: LearningProposal,
        learnEnabled: Bool,
        presetsEnabled: Bool,
        dismissedHashes: Set<String>,
        pendingPresetHashes: Set<String>,
        pendingPresetCount: Int
    ) -> Bool {
        guard proposal.kind == .preset, learnEnabled, presetsEnabled else { return false }
        let hash = presetContentHash(proposal)
        guard !hash.isEmpty else { return false }
        guard !dismissedHashes.contains(hash) else { return false }
        guard !pendingPresetHashes.contains(hash) else { return false }
        guard pendingPresetCount < maxPendingPresetSuggestions else { return false }
        return true
    }

    /// Queue a preset suggestion if it clears the gates (see
    /// `presetSuggestionEligible`). Inserted at the front like other
    /// suggestions. Re-reads the feature flags here (not just at the
    /// analyzer) so a direct ingest still fails closed.
    private func insertPresetSuggestionIfEligible(_ proposal: LearningProposal) {
        let config = Config.load().config
        let pendingHashes = Set(pendingSuggestions
            .filter { $0.proposal.kind == .preset }
            .map { Self.presetContentHash($0.proposal) })
        guard Self.presetSuggestionEligible(
            proposal,
            learnEnabled: config.learnFromCorrectionsEnabled,
            presetsEnabled: config.transformPresetsEnabled,
            dismissedHashes: dismissedPresetHashes,
            pendingPresetHashes: pendingHashes,
            pendingPresetCount: pendingPresetCount
        ) else { return }
        pendingSuggestions.insert(PendingSuggestion(
            id: UUID(), term: nil, rationale: proposal.rationale,
            proposal: proposal, priorAliases: nil
        ), at: 0)
    }

    // MARK: - Ingest (called by LearningAnalyzer, Task 7 wiring)

    /// Route a batch of proposals: auto-apply term changes through Config,
    /// queue the rest as suggestions, drop deferred style. Returns the
    /// number auto-applied (for the count-only log).
    @discardableResult
    func ingest(_ proposals: [LearningProposal]) -> Int {
        var (config, _) = Config.load()
        var dictionary = config.customDictionary
        var pendingApplied: [(proposal: LearningProposal, prior: DictionaryEntry?, applied: DictionaryEntry?)] = []
        var newSuggestions: [PendingSuggestion] = []
        // Count-only tally of TERM proposals the quality bar kept out of
        // auto-apply (no term text — honors the count-only learning-log
        // invariant). They still surface as suggestions; this just records
        // how many auto-adds the bar prevented this run.
        var qualityRejectedCount = 0
        for proposal in proposals {
            if proposal.kind == .term, let term = proposal.term,
               proposal.op != .retire,
               proposal.confidence >= LearningAnalyzer.autoApplyConfidenceThreshold,
               LearnedTermQualityBar.rejectionReason(term: term, existing: dictionary) != nil {
                qualityRejectedCount += 1
            }
            switch Self.route(proposal, against: dictionary) {
            case .autoApply:
                let term = proposal.term ?? ""
                let prior = dictionary.first { $0.term.caseInsensitiveCompare(term) == .orderedSame }
                Self.applyTermProposal(proposal, to: &dictionary)
                let appliedEntry = dictionary.first { $0.term.caseInsensitiveCompare(term) == .orderedSame }
                pendingApplied.append((proposal, prior, appliedEntry))
            case .suggest:
                if proposal.kind == .preset {
                    // Bridge 1: preset suggestions take a separate path
                    // (dismissed-hash filter, content dedupe, low cap).
                    // They're inserted directly here, not via the term
                    // collector below, since they have no `term`.
                    insertPresetSuggestionIfEligible(proposal)
                    continue
                }
                let prior = dictionary.first { $0.term.caseInsensitiveCompare(proposal.term ?? "") == .orderedSame }
                newSuggestions.append(PendingSuggestion(
                    id: UUID(), term: proposal.term, rationale: proposal.rationale,
                    proposal: proposal, priorAliases: prior?.aliases
                ))
            case .deferStyle:
                continue // slice 2 consumer
            }
        }
        if !pendingApplied.isEmpty {
            config.customDictionary = dictionary
            // Only record the applied-changes log (and count the applies) if
            // the write actually lands. Otherwise the log would show ghost
            // entries for changes that never reached disk, and Revert would
            // silently no-op against them (the staleness guard would fire).
            guard (try? Config.save(config)) != nil else {
                // Save failed (disk full / permissions). Don't record ghost
                // applied rows — but don't silently waste the analysis
                // either: surface the would-be auto-applies as pending
                // suggestions (in-memory, no disk) so the user can retry them
                // with Accept once the write path recovers.
                for p in pendingApplied {
                    insertSuggestionIfNew(PendingSuggestion(
                        id: UUID(), term: p.proposal.term, rationale: p.proposal.rationale,
                        proposal: p.proposal, priorAliases: p.prior?.aliases
                    ))
                }
                for s in newSuggestions { insertSuggestionIfNew(s) }
                return 0
            }
            for p in pendingApplied {
                recordApplied(term: p.proposal.term ?? "", rationale: p.proposal.rationale,
                              prior: p.prior, applied: p.applied)
            }
        }
        // Suggestions are in-memory only (no disk write), so they're added
        // regardless of whether any auto-apply save succeeded.
        for s in newSuggestions { insertSuggestionIfNew(s) }
        if qualityRejectedCount > 0 {
            // Count-only (no term text) — preserves the learning-log
            // invariant that no transcript-derived content reaches stderr.
            FileHandle.standardError.write(
                "[parleq] LearnedStore: \(qualityRejectedCount) term proposal(s) rejected from auto-apply by quality bar\n"
                    .data(using: .utf8) ?? Data())
        }
        return pendingApplied.count
    }

    /// Apply a suggestion the user explicitly confirmed. This FORCE-
    /// applies — it must NOT re-route through `ingest`, because the
    /// proposal is in the pending list precisely because `route`
    /// returned `.suggest` (low confidence, collides with a user entry,
    /// or a retire op); re-routing would just re-queue it forever and
    /// never apply. The accepted change is recorded in the applied log
    /// so it shows up there and stays revertible.
    func accept(id: UUID) {
        guard let suggestion = pendingSuggestions.first(where: { $0.id == id }) else { return }
        let proposal = suggestion.proposal
        // A preset suggestion accepted without an edited name/prompt: apply
        // the distilled values as-is (the UI's Accept passes edits via
        // acceptPreset; this covers the no-edit path / programmatic accept).
        if proposal.kind == .preset {
            acceptPreset(id: id, name: proposal.presetName ?? "", prompt: proposal.presetPrompt ?? "")
            return
        }
        // A non-term (style) suggestion has no slice-1 consumer — just clear
        // it so it doesn't sit in the list forever. No activity row: nothing
        // was actually applied or shown to the user as a learned outcome.
        guard proposal.kind == .term, let term = proposal.term else {
            pendingSuggestions.removeAll { $0.id == id }
            return
        }
        var (config, _) = Config.load()
        let prior = config.customDictionary.first { $0.term.caseInsensitiveCompare(term) == .orderedSame }
        var appliedEntry: DictionaryEntry?
        if proposal.op == .retire {
            config.customDictionary.removeAll { $0.term.caseInsensitiveCompare(term) == .orderedSame }
        } else {
            // The user explicitly accepted this, so they take ownership:
            // the resulting entry is source=.user. That never downgrades an
            // existing user entry's provenance and protects the accepted
            // term from being silently overwritten by a future auto-apply.
            // Aliases are UNIONED with the prior entry's so accepting never
            // drops aliases the user already had; context falls back to the
            // prior entry's when the proposal supplies none; biasing is
            // preserved. So a modify/merge only ever adds, never silently
            // strips, the entry's existing fields.
            let entry = DictionaryEntry(
                term: term,
                context: proposal.context ?? prior?.context,
                aliases: Self.unionAliases(prior: prior?.aliases ?? [], proposed: proposal.aliases ?? []),
                spokenForms: prior?.spokenForms ?? [],   // never drop existing say-as phrases on accept/merge
                biasing: prior?.biasing ?? .asrAndLLM,
                source: .user
            )
            if let i = config.customDictionary.firstIndex(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
                config.customDictionary[i] = entry
            } else {
                config.customDictionary.append(entry)
            }
            appliedEntry = entry
        }
        // Only mutate in-memory state once the write lands: a failed save
        // leaves the suggestion in place to retry rather than recording a
        // ghost applied-change row.
        guard (try? Config.save(config)) != nil else { return }
        pendingSuggestions.removeAll { $0.id == id }
        recordApplied(term: term, rationale: proposal.rationale, prior: prior, applied: appliedEntry)
        // Mirror into the unified activity log, linked to this term's applied
        // row so Revert can reuse the term path. Look the row up BY TERM (not
        // `first`) so the link is unambiguous — recordApplied keeps exactly
        // one row per term, so this is that row.
        let summary = proposal.op == .retire
            ? "Removed term '\(term)'" : "Added term '\(term)'"
        let acID = appliedChanges.first {
            $0.term.caseInsensitiveCompare(term) == .orderedSame
        }?.id
        pushActivity(ActivityEntry(
            id: UUID(), timestamp: Date(), kind: .term, outcome: .accepted,
            summary: summary,
            pendingSuggestion: suggestion, presetDefaultSuggestion: nil,
            createdPresetID: nil, appDefaultBundleID: nil,
            termAppliedChangeID: acID
        ))
    }

    /// Pure helper (unit-tested): append a new TransformPreset to a
    /// config, using the user-edited name/prompt. Returns the new config
    /// and the created preset. Returns nil if the feature is off or the
    /// name/prompt is blank after trimming — the caller drops the accept.
    nonisolated static func configByAddingPreset(
        to config: Config, name: String, prompt: String
    ) -> (config: Config, preset: TransformPreset)? {
        guard config.transformPresetsEnabled else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return nil }
        var out = config
        let preset = TransformPreset(name: trimmedName, prompt: trimmedPrompt)
        out.transformPresets.append(preset)
        return (out, preset)
    }

    /// Accept a preset suggestion with the (possibly user-edited) name +
    /// prompt. Writes a new TransformPreset to config through the same
    /// path PresetsSettingsView uses. Never auto-applies anything else.
    /// On a blank/feature-off result the suggestion is left in place.
    func acceptPreset(id: UUID, name: String, prompt: String) {
        guard let suggestion = pendingSuggestions.first(where: { $0.id == id }) else { return }
        let (config, _) = Config.load()
        guard let result = Self.configByAddingPreset(to: config, name: name, prompt: prompt) else { return }
        guard (try? Config.save(result.config)) != nil else { return }
        // Record the dismissed-hash on accept too, so an equivalent
        // distilled prompt isn't re-proposed once the user already created
        // a preset from it.
        let hash = Self.presetContentHash(suggestion.proposal)
        if !hash.isEmpty { dismissedPresetHashes.insert(hash) }
        pendingSuggestions.removeAll { $0.id == id }
        // The restorable suggestion preserves the user's edited name/prompt
        // so a Restore (after a later Revert) re-seeds exactly those.
        let edited = LearningProposal(
            kind: .preset, op: suggestion.proposal.op,
            confidence: suggestion.proposal.confidence,
            rationale: suggestion.proposal.rationale,
            presetName: result.preset.name, presetPrompt: result.preset.prompt)
        let restorable = PendingSuggestion(
            id: UUID(), term: nil, rationale: suggestion.rationale,
            proposal: edited, priorAliases: nil)
        pushActivity(ActivityEntry(
            id: UUID(), timestamp: Date(), kind: .preset, outcome: .accepted,
            summary: "Created preset '\(result.preset.name)'",
            pendingSuggestion: restorable, presetDefaultSuggestion: nil,
            createdPresetID: result.preset.id, appDefaultBundleID: nil,
            termAppliedChangeID: nil,
            // Capture the ORIGINAL proposal's hash (the suppression key set
            // just above) so Revert clears the same one even if the user
            // edited the prompt before accepting.
            originalPresetHash: hash))
    }

    func dismiss(id: UUID) {
        guard let s = pendingSuggestions.first(where: { $0.id == id }) else { return }
        // Bridge 1: record a dismissed preset's content hash so the same
        // distilled prompt isn't re-proposed (in-memory; see field doc).
        if s.proposal.kind == .preset {
            let hash = Self.presetContentHash(s.proposal)
            if !hash.isEmpty { dismissedPresetHashes.insert(hash) }
        }
        pendingSuggestions.removeAll { $0.id == id }
        // Only term and preset suggestions become activity rows. A .style
        // proposal has no slice-1 consumer (mirrors accept()'s early exit);
        // logging one as kind .term would be a semantically wrong, confusing
        // "Dismissed: suggestion" row. Drop it silently.
        guard s.proposal.kind == .term || s.proposal.kind == .preset else { return }
        // Keep a Restore-able activity row so a misclicked Dismiss is
        // recoverable. Carries the original suggestion verbatim.
        let kind: ActivityEntry.Kind = s.proposal.kind == .preset ? .preset : .term
        let desc: String
        if s.proposal.kind == .preset {
            desc = "preset '\(s.proposal.presetName ?? "")'"
        } else if let term = s.term {
            desc = "term '\(term)'"
        } else {
            desc = "suggestion"
        }
        pushActivity(ActivityEntry(
            id: UUID(), timestamp: Date(), kind: kind, outcome: .dismissed,
            summary: "Dismissed: \(desc)",
            pendingSuggestion: s, presetDefaultSuggestion: nil,
            createdPresetID: nil, appDefaultBundleID: nil,
            termAppliedChangeID: nil))
    }

    // MARK: - Bridge 2: per-app default suggestions

    /// Recompute the per-app default suggestions from the durable usage
    /// journal. Off the hot path — called when the Learned view opens.
    /// Gated on transformPresetsEnabled only (the journal is independent
    /// of the correction ring), so it surfaces even when
    /// learn-from-corrections is off.
    func refreshPresetDefaultSuggestions() {
        let config = Config.load().config
        guard config.transformPresetsEnabled else {
            presetDefaultSuggestions = []
            return
        }
        presetDefaultSuggestions = usageJournal.suggestions(config: config)
    }

    /// Pure helper (unit-tested): set a per-app default in a config.
    /// Returns nil if the feature is off or the preset no longer exists.
    nonisolated static func configBySettingDefault(
        to config: Config, appBundleID: String, presetID: String
    ) -> Config? {
        guard config.transformPresetsEnabled,
              config.transformPresets.contains(where: { $0.id == presetID }),
              !appBundleID.isEmpty else { return nil }
        var out = config
        out.presetAppDefaults[appBundleID] = presetID
        return out
    }

    /// Pure helper (unit-tested): remove a created preset and any app
    /// defaults that pointed at it (so config never references a missing
    /// preset). Used by Revert of an accepted-preset activity entry.
    nonisolated static func configByRemovingPreset(
        from config: Config, presetID: String
    ) -> Config {
        var out = config
        out.transformPresets.removeAll { $0.id == presetID }
        out.presetAppDefaults = out.presetAppDefaults.filter { $0.value != presetID }
        return out
    }

    /// Pure helper (unit-tested): remove a per-app default mapping, but only
    /// if it still points at `presetID` (don't clobber a later, different
    /// default the user chose meanwhile). Returns nil when the live mapping
    /// has moved on — the caller leaves config alone.
    nonisolated static func configByRemovingDefault(
        from config: Config, appBundleID: String, presetID: String
    ) -> Config? {
        guard config.presetAppDefaults[appBundleID] == presetID else { return nil }
        var out = config
        out.presetAppDefaults[appBundleID] = nil
        return out
    }

    /// Accept a per-app default suggestion: write the mapping through the
    /// same path the Settings UI uses. Drops the suggestion on success.
    func acceptPresetDefault(_ suggestion: PresetDefaultSuggestion) {
        let (config, _) = Config.load()
        guard let updated = Self.configBySettingDefault(
            to: config, appBundleID: suggestion.appBundleID, presetID: suggestion.presetID
        ) else { return }
        guard (try? Config.save(updated)) != nil else { return }
        presetDefaultSuggestions.removeAll { $0.id == suggestion.id }
        pushActivity(ActivityEntry(
            id: UUID(), timestamp: Date(), kind: .appDefault, outcome: .accepted,
            summary: "Set '\(suggestion.presetName)' as default for \(Self.appDisplayName(suggestion.appBundleID))",
            pendingSuggestion: nil, presetDefaultSuggestion: suggestion,
            createdPresetID: suggestion.presetID,
            appDefaultBundleID: suggestion.appBundleID,
            termAppliedChangeID: nil))
    }

    /// Dismiss a per-app default suggestion: record the (app, preset)
    /// decline DURABLY so it never re-appears, and drop it from the list.
    func dismissPresetDefault(_ suggestion: PresetDefaultSuggestion) {
        usageJournal.recordDecline(appBundleID: suggestion.appBundleID, presetID: suggestion.presetID)
        presetDefaultSuggestions.removeAll { $0.id == suggestion.id }
        pushActivity(ActivityEntry(
            id: UUID(), timestamp: Date(), kind: .appDefault, outcome: .dismissed,
            summary: "Dismissed: default '\(suggestion.presetName)' for \(Self.appDisplayName(suggestion.appBundleID))",
            pendingSuggestion: nil, presetDefaultSuggestion: suggestion,
            createdPresetID: nil, appDefaultBundleID: nil,
            termAppliedChangeID: nil))
    }

    /// Best-effort friendly app name for a bundle id (e.g.
    /// "com.apple.mail" → "Mail"). Falls back to the bundle id. Pure /
    /// nonisolated so it's usable from anywhere and unit-testable.
    nonisolated static func appDisplayName(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        guard !last.isEmpty else { return bundleID }
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    func revert(id: UUID) {
        guard let change = appliedChanges.first(where: { $0.id == id }) else { return }
        var (config, _) = Config.load()
        // Staleness guard: only undo if the live entry is still EXACTLY what
        // we applied. If the user has edited it since (or re-added a term we
        // retired), the live state is theirs — drop the stale row and leave
        // their version untouched. `appliedEntry` is nil for a retire, which
        // matches an absent live entry (nil == nil). The stale path makes no
        // disk write, so the row can be dropped immediately.
        let current = config.customDictionary.first { $0.term.caseInsensitiveCompare(change.term) == .orderedSame }
        if current != change.appliedEntry {
            appliedChanges.removeAll { $0.id == id }
            return
        }
        config.customDictionary.removeAll { $0.term.caseInsensitiveCompare(change.term) == .orderedSame }
        // If this was a modify (or a retire), restore the prior entry.
        if let priorEntry = change.priorEntry {
            config.customDictionary.append(priorEntry)
        }
        // Keep the row if the write fails so the user can retry the revert.
        guard (try? Config.save(config)) != nil else { return }
        appliedChanges.removeAll { $0.id == id }
    }

    // MARK: - Activity-log actions (Restore / Revert)

    /// Restore a DISMISSED activity entry: re-inject the original pending
    /// suggestion (or per-app default suggestion) so the user can act on it
    /// again. An explicit user act, so it bypasses the dismissed-hash
    /// suppression (Bridge 1) — otherwise the restored preset suggestion
    /// would be silently filtered back out. The entry stays in history,
    /// re-marked `.restored` (anti-vanish), so the user can see it worked.
    func restore(id: UUID) {
        guard let i = activityLog.firstIndex(where: { $0.id == id }),
              activityLog[i].outcome == .dismissed else { return }
        let entry = activityLog[i]
        if let s = entry.pendingSuggestion {
            // Clear the dismissed-hash so the restored preset isn't
            // re-suppressed; reinsert at the front (skip if a fresh
            // duplicate is already pending).
            if s.proposal.kind == .preset {
                let hash = Self.presetContentHash(s.proposal)
                dismissedPresetHashes.remove(hash)
                guard !pendingSuggestions.contains(where: {
                    $0.proposal.kind == .preset
                        && Self.presetContentHash($0.proposal) == hash
                }) else { /* already back */ markRestored(i); return }
                pendingSuggestions.insert(s, at: 0)
            } else {
                insertSuggestionIfNew(s)
            }
        } else if let d = entry.presetDefaultSuggestion {
            // Bridge 2 dismiss writes a DURABLE decline; an explicit Restore
            // must undo that so the suggestion can recompute and re-show.
            usageJournal.clearDecline(appBundleID: d.appBundleID, presetID: d.presetID)
            if !presetDefaultSuggestions.contains(where: { $0.id == d.id }) {
                presetDefaultSuggestions.insert(d, at: 0)
            }
        } else {
            return
        }
        markRestored(i)
    }

    private func markRestored(_ index: Int) {
        var e = activityLog[index]
        e.outcome = .restored
        e.timestamp = Date()
        e.summary = "Restored: " + e.summary.replacingOccurrences(of: "Dismissed: ", with: "")
        activityLog[index] = e
    }

    /// Revert an ACCEPTED activity entry: undo the durable artifact and
    /// re-mark the row `.reverted` (it stays in history — same anti-vanish
    /// principle as term Revert). Term accepts delegate to the existing
    /// `revert(id:)` applied-change path; preset/app-default undo their
    /// config writes here.
    func revertActivity(id: UUID) {
        guard let i = activityLog.firstIndex(where: { $0.id == id }),
              activityLog[i].outcome == .accepted else { return }
        let entry = activityLog[i]
        switch entry.kind {
        case .term:
            // Reuse the term-revert path (staleness guard + prior restore).
            // The linked AppliedChange row can be GONE for two reasons: the
            // user already reverted it, OR a later re-accept of the same term
            // superseded it (recordApplied keeps one row per term, with a new
            // id). In the superseded case the term is still in config and is
            // revertible via the NEWER entry — so a missing link here is a
            // no-op, NOT a revert. Bail without marking reverted; only the
            // newer entry's Revert (or this entry, if it still owns the row)
            // should flip the row.
            guard let acID = entry.termAppliedChangeID,
                  appliedChanges.contains(where: { $0.id == acID }) else { return }
            revert(id: acID)
            // `revert(id:)` fails closed on a save failure: it leaves the row
            // in place so the user can retry. Use the row's removal as the
            // success proxy — if it's still there, the write failed, so don't
            // falsely mark the row "Reverted" while the term is still in
            // config.
            guard !appliedChanges.contains(where: { $0.id == acID }) else { return }
        case .preset:
            guard let presetID = entry.createdPresetID else { return }
            let (config, _) = Config.load()
            let updated = Self.configByRemovingPreset(from: config, presetID: presetID)
            guard (try? Config.save(updated)) != nil else { return }
            // acceptPreset suppressed re-proposal of the ORIGINAL proposal's
            // hash; reverting the accept undoes that artifact too, so clear
            // the same hash (symmetric with restore() on the dismiss path).
            // Use the captured `originalPresetHash` — NOT the restorable
            // suggestion's, which carries the user's edited prompt and would
            // hash differently, leaving the original pattern suppressed.
            if let hash = entry.originalPresetHash, !hash.isEmpty {
                dismissedPresetHashes.remove(hash)
            }
        case .appDefault:
            guard let bundle = entry.appDefaultBundleID,
                  let presetID = entry.createdPresetID else { return }
            let (config, _) = Config.load()
            // configByRemovingDefault returns nil when the live default no
            // longer points at our preset (the user changed it meanwhile) —
            // in that case leave config alone but still mark the row reverted
            // (the artifact we created is already gone).
            guard let updated = Self.configByRemovingDefault(
                from: config, appBundleID: bundle, presetID: presetID) else {
                markReverted(i); return
            }
            guard (try? Config.save(updated)) != nil else { return }
        }
        markReverted(i)
    }

    private func markReverted(_ index: Int) {
        var e = activityLog[index]
        e.outcome = .reverted
        e.timestamp = Date()
        // Prefix the original summary so the row reads "Reverted: …" and the
        // user can still see what it was. Kind-agnostic, so it stays correct
        // for every summary phrasing.
        e.summary = "Reverted: " + e.summary
        activityLog[index] = e
    }

    func clearAll() {
        pendingSuggestions.removeAll()
        appliedChanges.removeAll()
        activityLog.removeAll()
        Self.purgeLegacyOnDiskFile()
    }

    #if DEBUG
    /// Test seam: reset all in-memory state without touching disk (the
    /// production `clearAll` is also disk-safe, but this is explicit about
    /// intent and also clears the dismissed-hash suppression so tests start
    /// from a clean slate). NEVER writes to `~/.parleq`.
    func _resetForTesting() {
        pendingSuggestions.removeAll()
        appliedChanges.removeAll()
        activityLog.removeAll()
        presetDefaultSuggestions.removeAll()
        dismissedPresetHashes.removeAll()
    }

    /// Test seam: directly seed a pending suggestion (in-memory only) so a
    /// dismiss/restore flow can be exercised without the disk-writing accept
    /// path. NEVER writes to `~/.parleq`.
    func _seedPendingForTesting(_ s: PendingSuggestion) {
        pendingSuggestions.insert(s, at: 0)
    }

    /// Test seam: directly seed an activity entry (in-memory only). NEVER
    /// writes to `~/.parleq`.
    func _seedActivityForTesting(_ e: ActivityEntry) {
        pushActivity(e)
    }

    /// Test seam: read whether a preset content hash is currently
    /// suppressed (dismissed). NEVER touches disk.
    func _isDismissedHashForTesting(_ hash: String) -> Bool {
        dismissedPresetHashes.contains(hash)
    }
    #endif
}
