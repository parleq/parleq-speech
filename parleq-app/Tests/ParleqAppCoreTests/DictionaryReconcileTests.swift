import XCTest
@testable import ParleqAppCore

/// Regression coverage for the dictionary-edit resurrection bug (shipped in
/// 0.18.0): editing an existing term in Settings fired SettingsModel.save()
/// per keystroke, and a frozen load-time snapshot caused each intermediate
/// string the term field passed through to be misclassified as an externally
/// added entry and re-appended to config.json as a separate dictionary term.
///
/// SettingsModel.save() writes to the real ~/.parleq/config.json and has no
/// injectable path seam, so we don't drive the @MainActor model against the
/// developer's home directory. Instead the reconcile+merge logic was extracted
/// into the pure static `SettingsModel.reconcileDictionary(...)`, and these
/// tests reproduce the per-keystroke loop save() performs (reconcile → write →
/// refresh snapshot) entirely in memory.
@MainActor
final class DictionaryReconcileTests: XCTestCase {

    /// A tiny in-memory stand-in for save()'s per-keystroke loop. Mirrors what
    /// SettingsModel.save() does once per keystroke: build the reconciled
    /// dictionary from the live rows + current snapshot + on-disk state, "write"
    /// it (the new on-disk state), then refresh the snapshot to the just-written
    /// state on success — exactly the fix.
    private struct Harness {
        var onDisk: [DictionaryEntry]
        var loadedTerms: Set<String>
        var loadedByTerm: [String: DictionaryEntry]

        init(onDisk: [DictionaryEntry]) {
            self.onDisk = onDisk
            self.loadedTerms = Set(onDisk.map { $0.term.lowercased() })
            self.loadedByTerm = Dictionary(
                onDisk.map { ($0.term.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first })
        }

        /// Reconcile + write + refresh snapshot, as save() does on success.
        mutating func save(rows: [DictionaryEntryRow]) {
            let written = SettingsModel.reconcileDictionary(
                editorRows: rows,
                loadedByTerm: loadedByTerm,
                loadedTerms: loadedTerms,
                existing: onDisk
            )
            onDisk = written
            loadedTerms = Set(written.map { $0.term.lowercased() })
            loadedByTerm = Dictionary(
                written.map { ($0.term.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first })
        }
    }

    /// Renaming an existing (learned) term keystroke-by-keystroke must leave a
    /// single entry with the final term — not a trail of intermediate states.
    func test_keystroke_rename_does_not_resurrect_intermediates() {
        // One learned entry on disk, as a learn-from-corrections auto-apply
        // would have written it.
        let start = DictionaryEntry(
            term: "SNYK", context: "security scanner", aliases: [],
            biasing: .asrAndLLM, source: .learned)
        var h = Harness(onDisk: [start])

        // The single editor row, mirroring init()'s row build.
        var row = DictionaryEntryRow(
            term: "SNYK", context: "security scanner", aliases: "",
            biasing: .asrAndLLM, source: .learned)

        // The field text mutates through these intermediate strings as the
        // user retypes "SNYK" → "Snyk" (the field report's exact trail).
        let keystrokes = ["Sny", "Sn", "S", "Sb", "Sbn", "Snyk"]
        for text in keystrokes {
            row.term = text
            // promoteIfLearnedThenSave(): a user edit promotes learned → user.
            if row.source == .learned { row.source = .user }
            h.save(rows: [row])
        }

        XCTAssertEqual(h.onDisk.count, 1, "Renaming a term must not scatter intermediate keystrokes as entries")
        XCTAssertEqual(h.onDisk.first?.term, "Snyk")
        XCTAssertEqual(h.onDisk.first?.context, "security scanner", "Context must survive the rename")
        XCTAssertEqual(h.onDisk.first?.source, .user, "An edited learned term is promoted to user-authored")
    }

    /// Direct proof of the root cause: with a FROZEN snapshot (the pre-fix
    /// behavior) the same loop scatters intermediates; refreshing the snapshot
    /// each iteration (the fix) collapses to a single entry.
    func test_frozen_snapshot_scatters_but_refreshed_snapshot_does_not() {
        let start = DictionaryEntry(term: "SNYK", context: "ctx", source: .user)
        let keystrokes = ["Sny", "Sn", "S", "Snyk"]

        // --- Frozen snapshot (reproduces the bug) ---
        let frozenTerms = Set([start.term.lowercased()])
        let frozenByTerm = [start.term.lowercased(): start]
        var frozenDisk = [start]
        for text in keystrokes {
            let row = DictionaryEntryRow(term: text, context: "ctx", source: .user)
            frozenDisk = SettingsModel.reconcileDictionary(
                editorRows: [row],
                loadedByTerm: frozenByTerm,   // never updated
                loadedTerms: frozenTerms,     // never updated
                existing: frozenDisk)
        }
        XCTAssertGreaterThan(
            frozenDisk.count, 1,
            "Sanity: the frozen-snapshot path is expected to resurrect intermediates")

        // --- Refreshed snapshot (the fix) ---
        var h = Harness(onDisk: [start])
        for text in keystrokes {
            let row = DictionaryEntryRow(term: text, context: "ctx", source: .user)
            h.save(rows: [row])
        }
        XCTAssertEqual(
            h.onDisk.count, 1,
            "Refreshing the snapshot after each save collapses to the final term")
        XCTAssertEqual(h.onDisk.first?.term, "Snyk")
    }

    /// The legitimate use case the merge exists for must still work: a learn
    /// feature write that lands on disk while the window is open (a NEW term,
    /// not in the snapshot, not in the rows) is preserved on the next save.
    func test_externally_added_learned_term_is_preserved() {
        let userEntry = DictionaryEntry(term: "Parleq", context: "app", source: .user)
        var h = Harness(onDisk: [userEntry])

        // The editor still shows just the one row it loaded with.
        let row = DictionaryEntryRow(term: "Parleq", context: "app", source: .user)

        // Meanwhile LearnedStore auto-applies a brand-new term to disk.
        h.onDisk.append(
            DictionaryEntry(term: "Kubernetes", context: "orchestrator", source: .learned))

        // The user tweaks the visible row, firing a save.
        var edited = row
        edited.context = "voice app"
        h.save(rows: [edited])

        let terms = Set(h.onDisk.map { $0.term })
        XCTAssertTrue(terms.contains("Kubernetes"), "Externally added learned term must survive a save")
        XCTAssertTrue(terms.contains("Parleq"))
        XCTAssertEqual(h.onDisk.count, 2)
    }

    /// A term the user deliberately deletes in the editor stays deleted —
    /// the merge must not resurrect it from disk.
    func test_user_deleted_term_stays_deleted() {
        let a = DictionaryEntry(term: "Alpha", context: "a", source: .user)
        let b = DictionaryEntry(term: "Beta", context: "b", source: .user)
        var h = Harness(onDisk: [a, b])

        // User removes the Beta row entirely; only Alpha remains.
        let row = DictionaryEntryRow(term: "Alpha", context: "a", source: .user)
        h.save(rows: [row])

        XCTAssertEqual(h.onDisk.count, 1)
        XCTAssertEqual(h.onDisk.first?.term, "Alpha")
    }

    /// An untouched row defers to a newer on-disk version (learned auto-apply
    /// that modified the same term's metadata while the window was open).
    func test_untouched_row_defers_to_newer_on_disk_version() {
        let loaded = DictionaryEntry(term: "Vertex", context: "old", aliases: [], source: .user)
        let snapshotTerms = Set([loaded.term.lowercased()])
        let snapshotByTerm = [loaded.term.lowercased(): loaded]

        // Disk now has a newer version (learn feature accepted a suggestion).
        let newer = DictionaryEntry(term: "Vertex", context: "new", aliases: ["vertices"], source: .learned)

        // The editor row is untouched (equals the loaded snapshot).
        let row = DictionaryEntryRow(term: "Vertex", context: "old", aliases: "", source: .user)

        let result = SettingsModel.reconcileDictionary(
            editorRows: [row],
            loadedByTerm: snapshotByTerm,
            loadedTerms: snapshotTerms,
            existing: [newer])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.context, "new", "Untouched row should defer to the newer on-disk version")
        XCTAssertEqual(result.first?.aliases, ["vertices"])
    }
}
