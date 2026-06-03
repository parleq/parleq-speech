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

    private init() {}

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
    nonisolated static func applyTermProposal(_ proposal: LearningProposal, to dictionary: inout [DictionaryEntry]) {
        guard proposal.kind == .term, let term = proposal.term else { return }
        let prior = dictionary.first { $0.term.caseInsensitiveCompare(term) == .orderedSame }
        let entry = DictionaryEntry(
            term: term,
            context: nil,
            aliases: unionAliases(prior: prior?.aliases ?? [], proposed: proposal.aliases ?? []),
            biasing: prior?.biasing ?? .asrAndLLM,
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
        for proposal in proposals {
            switch Self.route(proposal, against: dictionary) {
            case .autoApply:
                let term = proposal.term ?? ""
                let prior = dictionary.first { $0.term.caseInsensitiveCompare(term) == .orderedSame }
                Self.applyTermProposal(proposal, to: &dictionary)
                let appliedEntry = dictionary.first { $0.term.caseInsensitiveCompare(term) == .orderedSame }
                pendingApplied.append((proposal, prior, appliedEntry))
            case .suggest:
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
        // A non-term (style) suggestion has no slice-1 consumer — just clear
        // it so it doesn't sit in the list forever.
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
    }

    func dismiss(id: UUID) {
        pendingSuggestions.removeAll { $0.id == id }
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

    func clearAll() {
        pendingSuggestions.removeAll()
        appliedChanges.removeAll()
        Self.purgeLegacyOnDiskFile()
    }
}
