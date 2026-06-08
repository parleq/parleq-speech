import XCTest
@testable import ParleqAppCore

/// Bridge 2 — per-app default suggestions from a durable preset-usage
/// journal. All disk-touching tests use a temp directory (never the real
/// ~/.parleq, which the running app owns). Covers append/parse, compaction,
/// durable declines, the pure dominance rule, and the pure config writer.
final class PresetUsageJournalTests: XCTestCase {

    private var tempDir: URL!
    private var journal: PresetUsageJournal!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parleq-preset-usage-\(UUID().uuidString)", isDirectory: true)
        journal = PresetUsageJournal(directory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // Block until the async write queue drains (record() is fire-and-forget).
    private func drain() { journal.flushForTesting() }

    // MARK: - Append + parse

    func test_record_and_read_round_trip() {
        journal.record(presetID: "p1", presetName: "Concise", appBundleID: "com.apple.mail", source: "manual")
        journal.record(presetID: "p1", presetName: "Concise", appBundleID: "com.apple.mail", source: "default")
        drain()
        let entries = journal.readEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].presetID, "p1")
        XCTAssertEqual(entries[0].presetName, "Concise")
        XCTAssertEqual(entries[0].appBundleID, "com.apple.mail")
        XCTAssertEqual(Set(entries.map { $0.source }), ["manual", "default"])
    }

    func test_metadata_only_no_text_fields() {
        // Defense: the on-disk schema must carry NO dictation/refine text.
        // Encode an entry and assert the keys are exactly the metadata set.
        journal.record(presetID: "p1", presetName: "Concise", appBundleID: "com.apple.mail", source: "manual")
        drain()
        let raw = try! String(contentsOf: URL(fileURLWithPath: journal.path), encoding: .utf8)
        let line = raw.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let obj = try! JSONSerialization.jsonObject(with: line.data(using: .utf8)!) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), ["ts", "presetID", "presetName", "appBundleID", "source"],
                       "Journal entry must hold metadata only — no transcript/before/after/instruction keys")
    }

    // MARK: - Declines (durable)

    func test_decline_round_trip() {
        journal.recordDecline(appBundleID: "com.apple.mail", presetID: "p1")
        journal.recordDecline(appBundleID: "com.apple.mail", presetID: "p1") // idempotent
        journal.recordDecline(appBundleID: "com.apple.notes", presetID: "p2")
        drain()
        let declines = journal.readDeclines()
        XCTAssertEqual(declines.count, 2)
        XCTAssertTrue(declines.contains(PresetDefaultDecline(appBundleID: "com.apple.mail", presetID: "p1")))
        XCTAssertTrue(declines.contains(PresetDefaultDecline(appBundleID: "com.apple.notes", presetID: "p2")))
    }

    func test_clearDecline_round_trip() {
        journal.recordDecline(appBundleID: "com.apple.mail", presetID: "p1")
        drain()
        XCTAssertTrue(journal.readDeclines().contains(
            PresetDefaultDecline(appBundleID: "com.apple.mail", presetID: "p1")))
        journal.clearDecline(appBundleID: "com.apple.mail", presetID: "p1")
        drain()
        XCTAssertFalse(journal.readDeclines().contains(
            PresetDefaultDecline(appBundleID: "com.apple.mail", presetID: "p1")),
            "clearDecline removes the durable decline")
    }

    func test_decline_overrides_are_synchronous_before_disk_write() {
        // recordDecline / clearDecline must be visible to an IMMEDIATE
        // readDeclines() (no drain) — otherwise a suggestions() recompute on
        // the same run loop (e.g. LearnedView .onAppear right after a Restore)
        // races the async disk write and sees stale state.
        let pair = PresetDefaultDecline(appBundleID: "com.apple.mail", presetID: "p1")
        journal.recordDecline(appBundleID: "com.apple.mail", presetID: "p1")
        XCTAssertTrue(journal.readDeclines().contains(pair),
                      "A just-recorded decline is visible synchronously, before the disk write")
        journal.clearDecline(appBundleID: "com.apple.mail", presetID: "p1")
        XCTAssertFalse(journal.readDeclines().contains(pair),
                       "A just-cleared decline is gone synchronously, before the disk write")
        // And the override survives the disk write landing.
        drain()
        XCTAssertFalse(journal.readDeclines().contains(pair))
    }

    // MARK: - Compaction

    func test_compaction_keeps_newest_when_over_threshold() {
        // Pre-seed a file with > threshold lines, then trigger one record so
        // compactIfNeeded runs. Build the file directly (fast) rather than
        // 10k async records.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var blob = ""
        for i in 0..<10_050 {
            let e = PresetUsageEntry(ts: Date(timeIntervalSince1970: TimeInterval(i)),
                                     presetID: "p\(i)", presetName: "n", appBundleID: "app", source: "manual")
            blob += String(data: try! encoder.encode(e), encoding: .utf8)! + "\n"
        }
        try! blob.data(using: .utf8)!.write(to: URL(fileURLWithPath: journal.path))
        journal.record(presetID: "newest", presetName: "n", appBundleID: "app", source: "manual")
        drain()
        let entries = journal.readEntries()
        XCTAssertLessThanOrEqual(entries.count, 5_001,
                                 "Compaction must cap the file near compactKeep")
        XCTAssertTrue(entries.contains { $0.presetID == "newest" },
                      "Compaction keeps the NEWEST lines")
        XCTAssertFalse(entries.contains { $0.presetID == "p0" },
                       "Oldest lines are dropped")
    }

    // MARK: - Dominance rule (pure)

    private func usage(_ presetID: String, _ app: String, count: Int, source: String = "manual") -> [PresetUsageEntry] {
        (0..<count).map { _ in
            PresetUsageEntry(ts: Date(), presetID: presetID, presetName: presetID.uppercased(),
                             appBundleID: app, source: source)
        }
    }

    func test_dominance_requires_min_uses() {
        let entries = usage("p1", "com.apple.mail", count: 4) // below 5
        let s = PresetUsageJournal.computeSuggestions(
            entries: entries, configuredDefaults: [:], declined: [], existingPresetIDs: ["p1"])
        XCTAssertTrue(s.isEmpty, "Below the min-uses threshold → no suggestion")
    }

    func test_dominance_at_threshold_with_no_runner_up_suggests() {
        let entries = usage("p1", "com.apple.mail", count: 5)
        let s = PresetUsageJournal.computeSuggestions(
            entries: entries, configuredDefaults: [:], declined: [], existingPresetIDs: ["p1"])
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.presetID, "p1")
        XCTAssertEqual(s.first?.manualUses, 5)
    }

    func test_dominance_requires_2x_margin_over_runner_up() {
        // p1=6, p2=4: 6 >= 4*2 (=8)? no → no suggestion.
        let close = usage("p1", "com.apple.mail", count: 6) + usage("p2", "com.apple.mail", count: 4)
        XCTAssertTrue(PresetUsageJournal.computeSuggestions(
            entries: close, configuredDefaults: [:], declined: [], existingPresetIDs: ["p1", "p2"]).isEmpty,
            "A near-tie (no 2x margin) must not suggest")
        // p1=8, p2=4: 8 >= 8 → suggest.
        let clear = usage("p1", "com.apple.mail", count: 8) + usage("p2", "com.apple.mail", count: 4)
        XCTAssertEqual(PresetUsageJournal.computeSuggestions(
            entries: clear, configuredDefaults: [:], declined: [], existingPresetIDs: ["p1", "p2"]).first?.presetID,
            "p1", "Clear 2x dominance → suggest the winner")
    }

    func test_default_source_uses_do_not_count() {
        // 5 "default" uses + 1 "manual": only the manual counts → below threshold.
        let entries = usage("p1", "com.apple.mail", count: 5, source: "default")
            + usage("p1", "com.apple.mail", count: 1, source: "manual")
        XCTAssertTrue(PresetUsageJournal.computeSuggestions(
            entries: entries, configuredDefaults: [:], declined: [], existingPresetIDs: ["p1"]).isEmpty,
            "Default-styled uses must not reinforce a suggestion to set that default")
    }

    func test_existing_default_suppresses_suggestion() {
        let entries = usage("p1", "com.apple.mail", count: 10)
        let s = PresetUsageJournal.computeSuggestions(
            entries: entries, configuredDefaults: ["com.apple.mail": "p2"], declined: [], existingPresetIDs: ["p1", "p2"])
        XCTAssertTrue(s.isEmpty, "An app that already has a configured default is settled")
    }

    func test_declined_pair_suppresses_suggestion() {
        let entries = usage("p1", "com.apple.mail", count: 10)
        let s = PresetUsageJournal.computeSuggestions(
            entries: entries, configuredDefaults: [:],
            declined: [PresetDefaultDecline(appBundleID: "com.apple.mail", presetID: "p1")],
            existingPresetIDs: ["p1"])
        XCTAssertTrue(s.isEmpty, "A declined / un-set (app, preset) pair must never re-suggest")
    }

    func test_deleted_preset_not_suggested() {
        let entries = usage("p1", "com.apple.mail", count: 10)
        let s = PresetUsageJournal.computeSuggestions(
            entries: entries, configuredDefaults: [:], declined: [], existingPresetIDs: [])
        XCTAssertTrue(s.isEmpty, "A suggestion for a deleted preset must be dropped")
    }

    // MARK: - Accept writes config (pure)

    func test_configBySettingDefault_writes_mapping() {
        var c = Config.default
        c.transformPresets = [TransformPreset(id: "p1", name: "Concise", prompt: "x")]
        let updated = LearnedStore.configBySettingDefault(to: c, appBundleID: "com.apple.mail", presetID: "p1")
        XCTAssertEqual(updated?.presetAppDefaults["com.apple.mail"], "p1")
    }

    func test_configBySettingDefault_rejects_missing_preset_or_feature_off() {
        var c = Config.default
        c.transformPresets = [TransformPreset(id: "p1", name: "Concise", prompt: "x")]
        XCTAssertNil(LearnedStore.configBySettingDefault(to: c, appBundleID: "com.apple.mail", presetID: "ghost"),
                     "A mapping to a non-existent preset must not be written")
        c.transformPresetsEnabled = false
        XCTAssertNil(LearnedStore.configBySettingDefault(to: c, appBundleID: "com.apple.mail", presetID: "p1"),
                     "Feature off (MDM) → no mapping written")
    }
}
