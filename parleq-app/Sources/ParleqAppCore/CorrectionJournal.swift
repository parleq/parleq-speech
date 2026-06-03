// CorrectionJournal — opt-in, bounded, in-memory record of the two
// observable correction signals (voice-refine events + spelled-out-word
// candidates) that feed the "learn from corrections" analyzer.
//
// Compliance shape: written ONLY when config.learnFromCorrectionsEnabled
// is true. In-memory only — wiped on quit (mirrors TranscriptHistory's
// text ring). Retention caps bound the in-session ring: count cap + age
// cap, where 0 on EITHER cap disables entirely. Does NOT store full
// transcripts — refine records carry the instruction + before/after of
// an edit the user explicitly made; spellout records carry only the
// assembled candidate term + the cleaned line it landed in. Clearable;
// disabling the feature offers to purge (Settings).

import Combine
import Foundation

/// One captured correction signal. `kind` selects which optional fields
/// are populated: `.refine` -> instruction/before/after; `.spellout` ->
/// term/after. Sendable + Equatable; no Codable needed (in-memory only).
struct CorrectionRecord: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case refine
        case spellout
    }
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let instruction: String?
    let before: String?
    let after: String?
    let term: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        instruction: String? = nil,
        before: String? = nil,
        after: String? = nil,
        term: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.instruction = instruction
        self.before = before
        self.after = after
        self.term = term
    }
}

@MainActor
final class CorrectionJournal: ObservableObject {
    static let shared = CorrectionJournal()

    /// Newest-last (chronological). In-memory ring; wiped on quit.
    @Published private(set) var records: [CorrectionRecord] = []

    /// IDs of records already handed to an analysis run. Each correction
    /// is analyzed exactly once — the analyzer pulls only unanalyzed
    /// records, so consecutive runs don't re-analyze overlapping records
    /// (which would duplicate suggestions, resurrect dismissed ones, and
    /// re-bill the LLM). Pruned alongside `records` so it can't grow
    /// unbounded; emptied on clear.
    private var analyzedIDs: Set<UUID> = []

    /// Number of records not yet analyzed — drives the threshold trigger.
    /// Derived from `records` + `analyzedIDs` (no separate counter to keep
    /// in sync).
    var unanalyzedCount: Int { records.reduce(0) { $0 + (analyzedIDs.contains($1.id) ? 0 : 1) } }

    /// Bumped whenever the ring is cleared (Clear all / disable-purge).
    /// The analyzer captures this before its async LLM call and discards
    /// the results if it changed — so data the user cleared mid-analysis
    /// can't reappear as suggestions or applied dictionary changes.
    private(set) var generation: Int = 0

    private var maxEntries: Int?
    private var retentionHours: Int?

    private init() {
        applyRetentionLimits(from: Config.load().config)
    }

    /// Delete any legacy on-disk journal from an earlier disk-backed
    /// build of this feature. The journal is in-memory only now; this
    /// removes stragglers so no dictation-derived data lingers on disk.
    /// Called unconditionally at launch (from `AppState.init`) — NOT from
    /// this lazy `init`, which wouldn't run when the feature is off — and
    /// again from the purge path (`clear()`). Best-effort; nonisolated so
    /// the launch path can call it without touching the singleton.
    nonisolated static func purgeLegacyOnDiskFile() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parleq/corrections.jsonl", isDirectory: false)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Config-driven retention

    func applyRetentionLimits(from config: Config) {
        maxEntries = config.learnedCorrectionsMaxEntries
        retentionHours = config.learnedCorrectionsRetentionHours
        let before = records.count
        refreshRetention()
        // A retention/config change that drops records (e.g. a cap set to
        // 0, or tightened) effectively clears part of the ring — bump the
        // generation so an in-flight analysis discards its results too.
        if records.count < before { generation &+= 1 }
    }

    private func refreshRetention() {
        records = Self.applyRetention(records, maxEntries: maxEntries, retentionHours: retentionHours, now: Date())
        // Bound analyzedIDs to the surviving records so it can't grow
        // without limit as records age/cap out.
        if !analyzedIDs.isEmpty {
            let live = Set(records.map(\.id))
            analyzedIDs.formIntersection(live)
        }
    }

    /// Prune age/count-expired records using the current time. Retention
    /// is otherwise only applied on `record`/config changes; the analyzer
    /// calls this immediately before reading the ring so an idle session
    /// never analyzes records that have aged out. (unanalyzedCount is
    /// derived, so no counter to clamp.)
    func pruneExpired() {
        refreshRetention()
    }

    /// The oldest records not yet analyzed, up to `limit`. Oldest-first so
    /// every correction is eventually analyzed (FIFO progress) even when
    /// the backlog exceeds `limit`.
    func unanalyzedRecords(limit: Int) -> [CorrectionRecord] {
        Array(records.filter { !analyzedIDs.contains($0.id) }.prefix(limit))
    }

    // MARK: - Capture (called from AppState)

    /// Append a record. No-op when the feature is off or a cap is 0.
    /// `enabled` is passed by the caller (which already read Config for
    /// the utterance) so the journal doesn't re-read Config per capture.
    func record(_ rec: CorrectionRecord, enabled: Bool) {
        guard enabled, maxEntries != 0, retentionHours != 0 else { return }
        records.append(rec)
        refreshRetention()
    }

    /// Mark exactly these records as analyzed (by id), so they're never
    /// re-analyzed. Records that arrived during the in-flight call (not in
    /// this set) stay unanalyzed and trigger a later run.
    func markAnalyzed(_ analyzed: [CorrectionRecord]) {
        for rec in analyzed { analyzedIDs.insert(rec.id) }
    }

    /// Bump the generation when the feature is turned off, so an in-flight
    /// analysis discards its results even if the user re-enables before the
    /// LLM call completes (the post-await enabled-flag check alone would
    /// pass after a re-enable).
    func noteFeatureDisabled() {
        generation &+= 1
    }

    func clear() {
        records.removeAll()
        analyzedIDs.removeAll()
        generation &+= 1
        Self.purgeLegacyOnDiskFile()
    }

    // MARK: - Pure retention (unit-tested)

    /// Apply count + age caps. 0 on either cap = disable (returns []).
    /// nil = unlimited. Count cap keeps the newest N in chronological
    /// order. Pure + static so tests don't touch disk.
    nonisolated static func applyRetention(
        _ records: [CorrectionRecord],
        maxEntries: Int?,
        retentionHours: Int?,
        now: Date
    ) -> [CorrectionRecord] {
        if maxEntries == 0 || retentionHours == 0 { return [] }
        var out = records.sorted { $0.timestamp < $1.timestamp }
        if let hours = retentionHours, hours > 0,
           let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: now) {
            out.removeAll { $0.timestamp < cutoff }
        }
        if let cap = maxEntries, cap > 0, out.count > cap {
            out.removeFirst(out.count - cap)
        }
        return out
    }
}
