import XCTest
@testable import ParleqAppCore

/// Unified "Recent activity" history for the Learned screen: accept/dismiss
/// across all three suggestion kinds becomes a kept, outcome-marked entry;
/// dismissed entries are Restore-able (recovers a misclick) and accepted
/// entries are Revert-able, with both staying visible afterward (anti-vanish).
///
/// Disk discipline: these tests NEVER touch `~/.parleq`. The dismiss/restore
/// flow is exercised on the real (in-memory) store via test seams; the
/// accept/revert config mutations are asserted through pure helpers
/// (`configByRemovingPreset`, `configByRemovingDefault`), and the tally / ring
/// bound through pure statics — none of which write to disk.
final class LearnedActivityLogTests: XCTestCase {

    // MARK: helpers

    private func termSuggestion(_ term: String) -> LearnedStore.PendingSuggestion {
        LearnedStore.PendingSuggestion(
            id: UUID(), term: term, rationale: "r",
            proposal: LearningProposal(kind: .term, op: .add, confidence: 0.4, rationale: "r", term: term),
            priorAliases: nil)
    }

    private func presetSuggestion(name: String, prompt: String) -> LearnedStore.PendingSuggestion {
        LearnedStore.PendingSuggestion(
            id: UUID(), term: nil, rationale: "r",
            proposal: LearningProposal(kind: .preset, op: .add, confidence: 0.9, rationale: "r",
                                       presetName: name, presetPrompt: prompt),
            priorAliases: nil)
    }

    private func acceptedEntry(kind: ActivityEntry.Kind, summary: String) -> ActivityEntry {
        ActivityEntry(id: UUID(), timestamp: Date(), kind: kind, outcome: .accepted,
                      summary: summary, pendingSuggestion: nil, presetDefaultSuggestion: nil,
                      createdPresetID: nil, appDefaultBundleID: nil, termAppliedChangeID: nil)
    }

    private func dismissedEntry(kind: ActivityEntry.Kind, summary: String) -> ActivityEntry {
        ActivityEntry(id: UUID(), timestamp: Date(), kind: kind, outcome: .dismissed,
                      summary: summary, pendingSuggestion: nil, presetDefaultSuggestion: nil,
                      createdPresetID: nil, appDefaultBundleID: nil, termAppliedChangeID: nil)
    }

    // MARK: - Tally (pure)

    func test_tally_counts_accepts_by_kind_and_dismissals() {
        let log = [
            acceptedEntry(kind: .preset, summary: "Created preset 'A'"),
            acceptedEntry(kind: .preset, summary: "Created preset 'B'"),
            acceptedEntry(kind: .preset, summary: "Created preset 'C'"),
            acceptedEntry(kind: .term, summary: "Added term 'X'"),
            acceptedEntry(kind: .term, summary: "Added term 'Y'"),
            dismissedEntry(kind: .term, summary: "Dismissed: term 'Z'"),
        ]
        XCTAssertEqual(LearnedStore.tally(log),
                       "3 presets created · 2 terms learned · 1 dismissed")
    }

    func test_tally_singular_forms() {
        let log = [
            acceptedEntry(kind: .preset, summary: "Created preset 'A'"),
            acceptedEntry(kind: .term, summary: "Added term 'X'"),
            acceptedEntry(kind: .appDefault, summary: "Set 'A' as default for Mail"),
            dismissedEntry(kind: .preset, summary: "Dismissed: preset 'B'"),
        ]
        XCTAssertEqual(LearnedStore.tally(log),
                       "1 preset created · 1 term learned · 1 app default set · 1 dismissed")
    }

    func test_tally_excludes_reverted_and_restored() {
        var reverted = acceptedEntry(kind: .preset, summary: "Created preset 'A'")
        reverted.outcome = .reverted
        var restored = dismissedEntry(kind: .term, summary: "Dismissed: term 'Z'")
        restored.outcome = .restored
        // Reverted accept no longer counts as created; restored dismiss no
        // longer counts as dismissed.
        XCTAssertEqual(LearnedStore.tally([reverted, restored]), "",
                       "Terminal reverted/restored outcomes contribute nothing to the tally")
    }

    func test_tally_empty_log_is_empty_string() {
        XCTAssertEqual(LearnedStore.tally([]), "")
    }

    // MARK: - Ring bound (pure)

    func test_ring_evicts_oldest_past_cap() {
        var log: [ActivityEntry] = []
        for i in 0..<(LearnedStore.maxActivityEntries + 5) {
            log = LearnedStore.ringByPrepending(
                acceptedEntry(kind: .term, summary: "Added term '\(i)'"), to: log)
        }
        XCTAssertEqual(log.count, LearnedStore.maxActivityEntries, "Ring is bounded at the cap")
        // Newest is at the front; the 5 oldest were evicted.
        XCTAssertEqual(log.first?.summary, "Added term '\(LearnedStore.maxActivityEntries + 4)'")
        XCTAssertEqual(log.last?.summary, "Added term '5'",
                       "The first 5 inserts (0…4) were evicted")
    }

    // MARK: - appDisplayName (pure)

    func test_appDisplayName_friendly() {
        XCTAssertEqual(LearnedStore.appDisplayName("com.apple.mail"), "Mail")
        XCTAssertEqual(LearnedStore.appDisplayName("notes"), "Notes")
        XCTAssertEqual(LearnedStore.appDisplayName(""), "")
    }

    // MARK: - Revert config mutations (pure)

    func test_revert_accepted_preset_removes_it_and_dependent_defaults() {
        var c = Config.default
        let p = TransformPreset(name: "Concise", prompt: "Rewrite concisely.")
        c.transformPresets = [p]
        c.presetAppDefaults = ["com.apple.mail": p.id, "com.other.app": "keep-me"]
        let out = LearnedStore.configByRemovingPreset(from: c, presetID: p.id)
        XCTAssertTrue(out.transformPresets.isEmpty, "The created preset is deleted")
        XCTAssertNil(out.presetAppDefaults["com.apple.mail"],
                     "A default pointing at the deleted preset is removed too")
        XCTAssertEqual(out.presetAppDefaults["com.other.app"], "keep-me",
                       "Unrelated defaults are untouched")
    }

    func test_revert_accepted_default_only_when_still_pointing_there() {
        var c = Config.default
        c.presetAppDefaults = ["com.apple.mail": "preset-1"]
        // Still points where we set it → removable.
        let removed = LearnedStore.configByRemovingDefault(
            from: c, appBundleID: "com.apple.mail", presetID: "preset-1")
        XCTAssertNotNil(removed)
        XCTAssertNil(removed?.presetAppDefaults["com.apple.mail"])
        // The user changed it to a different preset since → leave it alone.
        c.presetAppDefaults = ["com.apple.mail": "preset-2"]
        XCTAssertNil(LearnedStore.configByRemovingDefault(
            from: c, appBundleID: "com.apple.mail", presetID: "preset-1"),
            "Don't clobber a later, different default the user chose")
    }

    // MARK: - Dismiss → history + Restore (in-memory, no disk)

    @MainActor
    func test_dismiss_term_adds_history_entry_and_restore_returns_to_pending() {
        let store = LearnedStore.shared
        store._resetForTesting()
        let s = termSuggestion("Mira")
        store._seedPendingForTesting(s)
        XCTAssertEqual(store.pendingSuggestions.count, 1)

        store.dismiss(id: s.id)
        XCTAssertTrue(store.pendingSuggestions.isEmpty, "Dismiss removes it from pending")
        XCTAssertEqual(store.activityLog.count, 1, "Dismiss leaves a kept history entry")
        let entry = store.activityLog[0]
        XCTAssertEqual(entry.outcome, .dismissed)
        XCTAssertTrue(entry.summary.contains("Mira"))

        store.restore(id: entry.id)
        XCTAssertEqual(store.pendingSuggestions.count, 1, "Restore re-injects the pending suggestion")
        XCTAssertEqual(store.pendingSuggestions[0].term, "Mira")
        XCTAssertEqual(store.activityLog[0].outcome, .restored,
                       "The entry stays in history, re-marked restored (anti-vanish)")
        store._resetForTesting()
    }

    @MainActor
    func test_restore_bypasses_dismissed_hash_suppression() {
        let store = LearnedStore.shared
        store._resetForTesting()
        let s = presetSuggestion(name: "Concise", prompt: "Rewrite concisely.")
        let hash = LearnedStore.presetContentHash(s.proposal)
        store._seedPendingForTesting(s)

        store.dismiss(id: s.id)
        XCTAssertTrue(store._isDismissedHashForTesting(hash),
                      "Dismissing a preset records its content hash to suppress re-proposal")
        XCTAssertTrue(store.pendingSuggestions.isEmpty)

        let entry = store.activityLog[0]
        store.restore(id: entry.id)
        XCTAssertFalse(store._isDismissedHashForTesting(hash),
                       "Restore clears the suppression — an explicit user act, not a re-proposal")
        XCTAssertEqual(store.pendingSuggestions.count, 1,
                       "The preset suggestion is back in the pending list")
        XCTAssertEqual(store.activityLog[0].outcome, .restored)
        store._resetForTesting()
    }

    @MainActor
    func test_dismiss_appdefault_history_then_restore_reinjects() {
        let store = LearnedStore.shared
        store._resetForTesting()
        // Seed a dismissed app-default activity entry directly (the accept/
        // dismiss paths that produce it touch the durable decline journal /
        // config; the in-memory restore reinjection is what we assert here).
        // Use empty bundle/preset ids so restore()'s clearDecline() hits its
        // `!appBundleID.isEmpty` guard and performs NO disk write — keeping
        // this test off ~/.parleq while still exercising the reinjection.
        let sugg = PresetDefaultSuggestion(
            appBundleID: "", presetID: "",
            presetName: "Concise", manualUses: 7)
        let entry = ActivityEntry(
            id: UUID(), timestamp: Date(), kind: .appDefault, outcome: .dismissed,
            summary: "Dismissed: default 'Concise' for Mail",
            pendingSuggestion: nil, presetDefaultSuggestion: sugg,
            createdPresetID: nil, appDefaultBundleID: nil, termAppliedChangeID: nil)
        store._seedActivityForTesting(entry)

        store.restore(id: entry.id)
        XCTAssertEqual(store.presetDefaultSuggestions.count, 1,
                       "Restore re-injects the per-app-default suggestion")
        XCTAssertEqual(store.presetDefaultSuggestions[0].id, sugg.id)
        XCTAssertEqual(store.activityLog[0].outcome, .restored)
        store._resetForTesting()
    }

    // MARK: - Empty only when BOTH pending and history are empty

    @MainActor
    func test_history_present_means_not_empty_even_with_no_pending() {
        let store = LearnedStore.shared
        store._resetForTesting()
        XCTAssertTrue(store.pendingSuggestions.isEmpty && store.activityLog.isEmpty,
                      "Fresh store: both empty → the view shows the empty state")
        store._seedActivityForTesting(acceptedEntry(kind: .preset, summary: "Created preset 'A'"))
        XCTAssertTrue(store.pendingSuggestions.isEmpty, "No pending items")
        XCTAssertFalse(store.activityLog.isEmpty,
                       "History present → the view shows history + tally, NOT the empty state")
        XCTAssertEqual(LearnedStore.tally(store.activityLog), "1 preset created")
        store._resetForTesting()
    }
}
