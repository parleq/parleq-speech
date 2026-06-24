// ConcordProvenanceStore — in-memory-only retention of Concord's
// per-stage edit provenance, for the maintainer's A/B analysis of the
// cleanup stages (Phase 1 deterministic/dictionary now; Phase 2 acoustic
// gate + proposer later).
//
// Compliance shape (mirrors CorrectionJournal / TranscriptHistory):
// process memory ONLY — NEVER written to ~/.parleq/ or anywhere on disk,
// wiped on quit. Concord's `EditRecord`s carry the actual edited words
// (`original` / `replacement`), so this store — like the transcript ring —
// is the in-memory home for that content. The ONLY thing that ever leaves
// the process for these records is the COUNT-only stderr line emitted by
// ConcordCleanupProvider; the words never touch stderr or a log file.
//
// This is intentionally a thin retention buffer: it bounds the ring and
// exposes per-stage applied counts. It is the hook the maintainer will
// grow (e.g. a Settings panel surfacing stage contribution); growing it
// must preserve the never-to-disk invariant.

#if Concord
import Combine
import Concord
import Foundation

/// One utterance's worth of Concord edit provenance.
struct ConcordProvenanceEntry: Sendable {
    let id: UUID
    let timestamp: Date
    /// Every edit Concord *considered* this utterance, applied or not,
    /// stage-tagged. In-memory only.
    let edits: [EditRecord]

    /// Per-stage counts of APPLIED edits (the analysis primitive).
    var appliedByStage: [EditStage: Int] {
        var out: [EditStage: Int] = [:]
        for e in edits where e.applied { out[e.stage, default: 0] += 1 }
        return out
    }
}

/// Process-memory ring of recent Concord provenance. Never persisted.
@MainActor
final class ConcordProvenanceStore: ObservableObject {
    static let shared = ConcordProvenanceStore()

    /// Newest-last. In-memory ring; wiped on quit. Bounded by `maxEntries`.
    @Published private(set) var entries: [ConcordProvenanceEntry] = []

    /// Count cap on the ring — keeps recent history for analysis without
    /// unbounded growth across a long session.
    private let maxEntries = 200

    private init() {}

    /// Record one utterance's edit provenance. Called (off-MainActor) from
    /// ConcordCleanupProvider.generateStreaming — hops to MainActor to
    /// mutate the published ring. No-op when there were no edits. Static +
    /// nonisolated so the off-actor caller never touches the MainActor
    /// `shared` reference outside the hop.
    nonisolated static func record(_ edits: [EditRecord]) {
        guard !edits.isEmpty else { return }
        let entry = ConcordProvenanceEntry(id: UUID(), timestamp: Date(), edits: edits)
        Task { @MainActor in
            shared.append(entry)
        }
    }

    private func append(_ entry: ConcordProvenanceEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// Aggregate applied-edit counts per stage across the whole ring —
    /// the primitive the maintainer's A/B analysis reads.
    var aggregateAppliedByStage: [EditStage: Int] {
        var out: [EditStage: Int] = [:]
        for entry in entries {
            for (stage, n) in entry.appliedByStage {
                out[stage, default: 0] += n
            }
        }
        return out
    }

    /// Clear the ring (e.g. on demand). The ring is also wiped on quit.
    func clear() {
        entries.removeAll()
    }
}
#endif
