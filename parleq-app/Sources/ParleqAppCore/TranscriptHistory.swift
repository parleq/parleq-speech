// TranscriptHistory — in-memory ring buffer of recent cleaned
// transcripts so the user can grab one back if a paste went
// somewhere unexpected (focus changed mid-flight, target app
// stopped accepting input, etc.).
//
// Compliance shape: the TEXT-BEARING `entries` are process memory
// only — never written to disk, vanish on app quit. This preserves
// the "audio in memory only" / "no input data on local computer"
// rules from `docs/SECURITY_REVIEW.md` § 5: the cleaned text was
// already in process memory while the overlay was open; keeping it
// for the rest of the session adds no new persistence surface.
//
// The parallel TEXT-FREE `metricsRecords` ring IS persisted to
// ~/.parleq/metrics.jsonl so the Stats section can span sessions
// (#57). MetricsRecord carries NO transcript text or reference
// content — only timestamp + durations/latencies + two booleans —
// so this is metadata, not input data. Persistence honors the same
// zero-retention short-circuit as the in-memory ring: when
// transcriptHistoryMaxEntries == 0 or transcriptHistoryRetentionHours
// == 0 (the MDM "disable history" lever), nothing is written and any
// existing file is removed.
//
// Surfaced via the menu bar's "Recent Dictations" submenu
// (MenuBar.swift). Clicking an entry copies the full text to the
// pasteboard so the user can ⌘V it wherever they wanted in the
// first place.

import Combine
import Foundation

struct TranscriptEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    /// The cleaned text — OR the raw ASR transcript when cleanup
    /// failed and we fell back. `wasCleanupSuccessful` says which.
    /// Either way it's the same text the user just pasted, stored
    /// without the trailing-space-rule applied so re-pastes match
    /// the user's intent rather than the original target's
    /// convention.
    let text: String
    /// Human-readable name of the app that was the original paste
    /// target (e.g. "iTerm2", "Mail"). nil if no target was
    /// captured (rare — usually only when the focused app changes
    /// mid-flight or has no bundle identity).
    let targetAppName: String?
    /// False when LLM cleanup failed for this dictation and the
    /// pasted text is the raw ASR transcript fallback. The Recent
    /// Dictations submenu surfaces these entries with a "raw"
    /// suffix so users can tell at a glance which dictations went
    /// through the cleanup pass and which didn't — useful when
    /// scanning Recent Dictations after a stretch of failed
    /// cleanups to identify ones worth re-dictating with cleanup
    /// working (#27).
    let wasCleanupSuccessful: Bool
    /// Number of references attached to this dictation. 0 = plain
    /// cleanup (today's behavior); ≥1 = reference-aware dictation.
    /// The reference content itself is intentionally NOT persisted
    /// — keeping the SECURITY_REVIEW §5.1 in-memory-only invariant
    /// for captured screen content. We track the count and labels
    /// only so the Recent Dictations menu can surface a "· N refs"
    /// suffix and the user can tell at a glance which dictations
    /// used references.
    let referenceCount: Int
    /// Window titles / filenames of the attached references,
    /// truncated for menu display. May be empty when
    /// `referenceCount > 0` only if labels were dropped for length.
    let referenceLabels: [String]

    // MARK: - Timing fields (0.14.0 PR 4 — for the Stats section in PR 5)

    /// Wall-clock duration of the audio recording in milliseconds.
    /// Measured from hotkey-down to hotkey-up (or quick-mode end).
    /// Used by the Stats section to compute "total speaking time"
    /// across today + this week. 0 for dictations where the start
    /// time wasn't captured (defensive — shouldn't happen in
    /// normal flow).
    let audioDurationMs: Int

    /// ASR latency in milliseconds — time from sending audio to
    /// receiving the transcript. nil when ASR was skipped (empty
    /// utterance) or when AppState didn't observe a latency for
    /// this dictation. Used by Stats to surface an average ASR
    /// latency line ("am I getting slower transcripts than usual?").
    let asrLatencyMs: Int?

    /// LLM cleanup latency in milliseconds — total stream duration
    /// from request to last token. nil when cleanup was skipped
    /// (no LLM configured, empty transcript, etc.) or when it
    /// failed before timing. Used by Stats for the latency average
    /// and for noticing provider degradation.
    let llmLatencyMs: Int?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        text: String,
        targetAppName: String?,
        wasCleanupSuccessful: Bool = true,
        referenceCount: Int = 0,
        referenceLabels: [String] = [],
        audioDurationMs: Int = 0,
        asrLatencyMs: Int? = nil,
        llmLatencyMs: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.targetAppName = targetAppName
        self.wasCleanupSuccessful = wasCleanupSuccessful
        self.referenceCount = referenceCount
        self.referenceLabels = referenceLabels
        self.audioDurationMs = audioDurationMs
        self.asrLatencyMs = asrLatencyMs
        self.llmLatencyMs = llmLatencyMs
    }

    /// Single-line preview suitable for a menu-item title. Caps
    /// the body at ~40 characters with an ellipsis when longer,
    /// and folds whitespace so multi-line cleanups don't break
    /// the menu's vertical rhythm.
    var preview: String {
        let folded = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let limit = 40
        if folded.count <= limit { return folded }
        let prefix = folded.prefix(limit)
        return "\(prefix)…"
    }
}

/// ObservableObject in 0.14.0+ so the new Parleq app's Recent
/// Dictations section (`RecentDictationsView`) can observe entry
/// list changes via SwiftUI's `@ObservedObject` and re-render on
/// every append / remove / clear without a manual refresh hook.
/// The pre-0.14.0 menu-bar Recent Dictations submenu was deleted
/// in PR 3 (#218); its old `delegate { rebuildSubmenu }` poll-
/// before-open pattern doesn't need the @Published wrapping.
@MainActor
final class TranscriptHistory: ObservableObject {
    /// Singleton — written by `AppState.accept`; read by the
    /// in-app Recent Dictations section.
    static let shared = TranscriptHistory()

    // 0.14.0 PR 6 (#221) introduced configurable retention with
    // "unlimited" as the default — matches the UI label
    // ("Unlimited") + the spec's framing ("unlimited until quit"
    // within the in-memory invariant). The 0.13.x behavior of an
    // implicit 20-entry cap (sized for the menu-bar submenu, now
    // gone) doesn't carry forward. Users who want a cap set one
    // in Settings → Privacy & Features → Dictation history
    // retention; IT admins set the matching managed keys.

    /// Newest-first. Reads are cheap; SwiftUI list diffing keys on
    /// TranscriptEntry.id which is stable across reorderings.
    @Published private(set) var entries: [TranscriptEntry] = []

    /// Text-free metric records for every accepted dictation in
    /// the session. The Stats section (PR 5, #220) reads from this
    /// so its today/this-week aggregates aren't silently
    /// undercounted by the `entries` cap. Each record is ~48
    /// bytes; 10k dictations = ~480KB, trivial vs the alternative
    /// of retaining every transcript's text. No transcript text
    /// or reference content lives in records. Subject to the same
    /// retention limits as `entries` (PR 6, #221) — count + age
    /// enforcement applies to both arrays.
    @Published private(set) var metricsRecords: [MetricsRecord] = []

    /// Effective max-entries cap. nil = unlimited (the default).
    /// Combined source of truth for both `entries` and
    /// `metricsRecords` count pruning. Refreshed by
    /// `applyRetentionLimits()` which is wired from
    /// SettingsModel.save() so live UI edits in Settings →
    /// Privacy & Features take effect immediately, plus from
    /// the init Config.load() so MDM pushes are applied before
    /// the first append.
    private var maxEntriesLimit: Int?

    /// Effective retention-hours cap. nil = unlimited. 0 means
    /// "disable history entirely" (per the spec). Periodic sweep
    /// runs every 60s on the main actor to enforce age-based
    /// retention without requiring user actions.
    private var retentionHoursLimit: Int?

    /// Backing timer for the retention sweep. Recreated when the
    /// cap changes; nil when retentionHoursLimit is nil (no need
    /// to burn a wakeup if there's no age limit to enforce).
    private var retentionSweepTimer: Timer?

    private init() {
        // Load the persisted text-free metrics ring from disk (#57)
        // BEFORE applying retention limits, so the loaded records get
        // pruned by the same count/age caps. If the effective config
        // is zero-retention, applyRetentionLimits → enforceLimits
        // wipes them right back out (and re-persists empty), so a
        // disabled-history fleet never surfaces stale on-disk metrics.
        metricsRecords = Self.loadPersistedMetrics()
        // Initial config read so first append() sees the right
        // limit. main.swift's setRetentionLimits(from:) is the
        // canonical wiring path but this init read covers any
        // pre-main.swift access (rare; defense-in-depth).
        applyRetentionLimits(from: Config.load().config)
    }

    /// Refresh the retention limits from the live Config. Wire
    /// this from a Config-change observer (main.swift) so MDM
    /// pushes + Settings edits take effect without waiting for
    /// the next dictation. Also re-arms the sweep timer if the
    /// hours-limit changed.
    func applyRetentionLimits(from config: Config) {
        // nil propagates as "no count cap"; matches the UI's
        // "Unlimited" label when the TextField is empty. 0 still
        // means "disable history entirely" via the cap==0 branch
        // in enforceLimits().
        maxEntriesLimit = config.transcriptHistoryMaxEntries
        retentionHoursLimit = config.transcriptHistoryRetentionHours

        // Re-arm the sweep timer based on the new hours limit.
        retentionSweepTimer?.invalidate()
        retentionSweepTimer = nil
        if let hours = retentionHoursLimit, hours > 0 {
            retentionSweepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sweepExpiredEntries() }
            }
        }
        // Apply both limits immediately to current entries.
        enforceLimits()
    }

    /// Add a new entry. Enforces count + age limits after
    /// insertion. 0 max-entries means "drop everything" — a
    /// zero-retention deployment policy intentionally discards
    /// the entry right after we recorded it, leaving Stats at 0
    /// session counts. The append still happens so any
    /// concurrent listeners see the transition, but enforceLimits
    /// immediately wipes both arrays.
    func append(_ entry: TranscriptEntry) {
        // Zero-retention short-circuit: when either cap is 0
        // (compliance lever, set via the
        // transcriptHistoryMaxEntries / transcriptHistoryRetentionHours
        // managed keys or Privacy & Features fields), skip the
        // mutation entirely. Inserting and then immediately
        // clearing via enforceLimits would still fire @Published
        // change notifications, giving subscribers a transient
        // view of the supposedly-disabled entry — weakens the
        // "0 = disabled" guarantee for downstream observers.
        if maxEntriesLimit == 0 || retentionHoursLimit == 0 {
            return
        }
        entries.insert(entry, at: 0)
        metricsRecords.append(MetricsRecord(
            id: entry.id,
            timestamp: entry.timestamp,
            audioDurationMs: entry.audioDurationMs,
            asrLatencyMs: entry.asrLatencyMs,
            llmLatencyMs: entry.llmLatencyMs,
            hadReference: entry.referenceCount > 0,
            cleanupFailed: !entry.wasCleanupSuccessful
        ))
        enforceLimits()
    }

    /// Periodic sweep — drops entries older than the
    /// retentionHoursLimit cutoff. No-op when the limit is nil
    /// or 0 (the timer doesn't run in either case, so this is
    /// only reached when there's actually work to do).
    private func sweepExpiredEntries() {
        guard let hours = retentionHoursLimit, hours > 0 else { return }
        guard let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) else { return }
        entries.removeAll { $0.timestamp < cutoff }
        metricsRecords.removeAll { $0.timestamp < cutoff }
        persistMetrics()
    }

    /// Apply count + age limits in lockstep. Called from append
    /// (after every insert) and from applyRetentionLimits (when
    /// the user / MDM changes a limit value). Both arrays prune
    /// to the same boundary so Stats and Recent Dictations stay
    /// in sync.
    private func enforceLimits() {
        // 0 on EITHER limit = disable entirely. Both limits are
        // spec'd as "0 means disable history" — this is the
        // zero-retention deployment lever for compliance fleets,
        // and either knob (count or age) should produce the
        // same outcome.
        if maxEntriesLimit == 0 || retentionHoursLimit == 0 {
            entries.removeAll()
            metricsRecords.removeAll()
            persistMetrics()
            return
        }
        // Count cap on the text-bearing array. metricsRecords is
        // intentionally uncapped by count (text-free, low per-
        // record cost; Stats needs uncapped history to be
        // accurate). The hours-based sweep prunes metricsRecords;
        // count-based pruning is for text only.
        if let cap = maxEntriesLimit, entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
        // Age cap fires both arrays' pruning. 0 hours is handled
        // by the cap==0 branch above; nil = unlimited so skip.
        if let hours = retentionHoursLimit, hours > 0,
           let cutoff = Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) {
            entries.removeAll { $0.timestamp < cutoff }
            metricsRecords.removeAll { $0.timestamp < cutoff }
        }
        // Persist the (now-pruned) metrics ring so the on-disk file
        // tracks the in-memory state. Covers the append path (append
        // calls enforceLimits) and the applyRetentionLimits path.
        persistMetrics()
    }

    /// Remove a specific entry by id. Wired to the per-card delete
    /// button (×) in RecentDictationsView. Removes from BOTH the
    /// text-bearing entries list AND the parallel metricsRecords
    /// — the user explicitly asked to drop this dictation, so its
    /// metrics shouldn't continue contributing to Stats either.
    /// No-op if the id has already been removed (e.g. concurrent
    /// delete + clear).
    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        metricsRecords.removeAll { $0.id == id }
        persistMetrics()
    }

    /// Wipe the buffer. Wired to the "Clear all dictation history"
    /// button at the bottom of the Recent Dictations section.
    /// Clears both the text-bearing entries and the metrics
    /// records so Stats also resets — "Clear all" is a user
    /// intent to nuke session state across the board.
    func clear() {
        entries.removeAll()
        metricsRecords.removeAll()
        persistMetrics()
    }

    // MARK: - Disk persistence (#57)

    /// Path to the persisted text-free metrics ring. Mirrors
    /// UsageLedger's ~/.parleq/usage.jsonl layout. One JSON object
    /// per line so a partially-written tail (crash mid-append)
    /// drops at most the last record on the next load.
    private static func metricsFileURL() -> URL? {
        guard let home = FileManager.default.homeDirectoryForCurrentUser as URL? else { return nil }
        let dir = home.appendingPathComponent(".parleq", isDirectory: true)
        return dir.appendingPathComponent("metrics.jsonl", isDirectory: false)
    }

    /// Load persisted metrics from disk. Tolerant: skips any line
    /// that fails to decode (forward-compat with added fields,
    /// resilient to a torn last line). Returns [] when the file is
    /// absent. Static so `init` can call it before `self` is fully
    /// available.
    private static func loadPersistedMetrics() -> [MetricsRecord] {
        guard let url = metricsFileURL(),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [MetricsRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let lineData = line.data(using: .utf8),
               let rec = try? decoder.decode(MetricsRecord.self, from: lineData) {
                out.append(rec)
            }
        }
        return out
    }

    /// Write the current metrics ring to disk atomically. Called
    /// after every mutation (append/remove/clear/sweep/enforce).
    /// When the ring is empty — including the zero-retention
    /// "disable history" state, where enforceLimits has wiped it —
    /// the on-disk file is removed so a disabled-history deployment
    /// leaves nothing behind. Best-effort: a write failure logs and
    /// is swallowed (persistence is a convenience, never a
    /// correctness requirement; the in-memory ring is authoritative
    /// for the running session).
    private func persistMetrics() {
        guard let url = Self.metricsFileURL() else { return }
        if metricsRecords.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var blob = Data()
        for rec in metricsRecords {
            guard let line = try? encoder.encode(rec) else { continue }
            blob.append(line)
            blob.append(0x0A) // newline
        }
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try blob.write(to: url, options: .atomic)
        } catch {
            let msg = "[parleq] TranscriptHistory: metrics persist failed: \(error)\n"
            FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
        }
    }
}

/// Text-free per-dictation metric record used by the Stats
/// section. Decoupled from `TranscriptEntry` so we can retain
/// metrics for the full session (the Stats today/this-week
/// aggregates need it) without retaining the privacy-sensitive
/// transcript text past the `maxEntries` cap.
struct MetricsRecord: Sendable, Codable {
    /// Matches the parent TranscriptEntry.id so explicit
    /// per-entry deletes (`remove(id:)`) can drop the metric in
    /// lockstep. Records created from cap-pruned entries keep
    /// their original id but never get explicitly removed (their
    /// text was dropped, but the metric stays as part of the
    /// session aggregate).
    let id: UUID
    let timestamp: Date
    let audioDurationMs: Int
    let asrLatencyMs: Int?
    let llmLatencyMs: Int?
    let hadReference: Bool
    let cleanupFailed: Bool
}
