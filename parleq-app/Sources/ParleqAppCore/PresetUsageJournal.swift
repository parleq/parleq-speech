// PresetUsageJournal — durable, append-only JSONL of when a transform
// preset was applied, used by Bridge 2 of Presets v1.1 to suggest a
// per-app default once a preset dominates an app's MANUAL usage.
//
// Storage: ~/.parleq/preset-usage.jsonl, one JSON object per line.
// Sibling file ~/.parleq/preset-usage-declined.json holds the set of
// (app, preset) pairs the user has declined or un-set, so a suggestion
// is never re-shown for a pair they've rejected.
//
// METADATA ONLY — exactly the UsageLedger class of file. Each entry is
// {ts, presetID, presetName, appBundleID, source}. There is NO dictation
// text, transcript, refine instruction, or any user-spoken content here:
// preset names are user-authored config labels, bundle IDs are app
// identifiers. Safe to `cat`/`jq`/back up alongside dotfiles, same as
// usage.jsonl. This is a deliberate, compliant on-disk artifact — it is
// NOT the in-memory-only correction ring (CorrectionJournal), which never
// touches disk.
//
// Threading mirrors UsageLedger: record() is nonisolated and dispatches
// file I/O onto a private utility queue, so callers in @Sendable contexts
// can append without main-thread hops. Reads (aggregate/decline scans)
// are synchronous and meant for the off-hot-path suggestion computation.

import Foundation

/// One preset application. Schema is stable on disk — additive only.
struct PresetUsageEntry: Codable, Sendable, Equatable {
    let ts: Date
    let presetID: String
    /// Snapshot of the preset's name at use time (for display in the
    /// suggestion even if the preset is later renamed/deleted).
    let presetName: String
    /// Bundle ID of the app the dictation was pasted into. Optional
    /// because the paste target can occasionally lack a bundle ID.
    let appBundleID: String?
    /// How the preset was applied: "manual" (overlay chip tap) or
    /// "default" (per-app default folded into cleanup). Only MANUAL uses
    /// count toward the dominance rule — a default's own uses must not
    /// reinforce a suggestion to set that same default.
    let source: String
}

/// A single (app, preset) pair the user has declined or un-set, so the
/// dominance suggestion is never re-shown for it.
struct PresetDefaultDecline: Codable, Sendable, Equatable, Hashable {
    let appBundleID: String
    let presetID: String
}

/// A computed suggestion to set a per-app default (Bridge 2).
struct PresetDefaultSuggestion: Sendable, Equatable, Identifiable {
    let appBundleID: String
    let presetID: String
    let presetName: String
    let manualUses: Int
    var id: String { "\(appBundleID)|\(presetID)" }
}

final class PresetUsageJournal: @unchecked Sendable {
    static let shared = PresetUsageJournal()

    private let fileURL: URL
    private let declineURL: URL
    private let writeQueue = DispatchQueue(label: "com.parleq.app.preset-usage", qos: .utility)

    /// Synchronous in-memory override of the durable decline set, applied
    /// on top of what `readDeclines()` loads from disk. `recordDecline` /
    /// `clearDecline` both mutate this immediately (before the async disk
    /// write lands) so a `suggestions()` recompute on the same run loop —
    /// e.g. a LearnedView `.onAppear` right after a Restore — sees the new
    /// state instead of racing the file write. Mirrors how Bridge 1's
    /// `dismissedPresetHashes` is a synchronous in-memory layer. Lock-
    /// guarded because reads happen on the main actor while the override
    /// can also be touched from the write queue's read-modify-write.
    private let overrideLock = NSLock()
    /// Pairs force-DECLINED in memory (win over disk being absent).
    private var declineAdds: Set<PresetDefaultDecline> = []
    /// Pairs force-CLEARED in memory (win over disk still having them).
    private var declineRemovals: Set<PresetDefaultDecline> = []

    /// Compaction threshold: above this many lines we rewrite the file
    /// keeping only the newest `compactKeep` lines, so steady use can't
    /// grow the file without bound. The dominance rule only needs recent
    /// manual counts, so dropping the oldest is safe.
    private static let compactThreshold = 10_000
    private static let compactKeep = 5_000

    /// Default singleton path (~/.parleq). Tests inject a temp directory.
    private convenience init() {
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".parleq")
        self.init(directory: URL(fileURLWithPath: dir))
    }

    /// Designated init — `directory` is injectable so tests never touch
    /// the real ~/.parleq path (the running app owns it).
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("preset-usage.jsonl")
        self.declineURL = directory.appendingPathComponent("preset-usage-declined.json")
    }

    var path: String { fileURL.path }

    /// Block until all queued writes (appends, compaction, declines) have
    /// completed. Test-only seam — the serial write queue makes this a
    /// reliable barrier without exposing the queue itself.
    func flushForTesting() { writeQueue.sync {} }

    // MARK: - Append (hot-path-adjacent; O(1) enqueue)

    /// Append a usage entry. Fire-and-forget: returns immediately while
    /// the queue handles the write. The only hot-path cost is the encode
    /// + enqueue (compaction runs on the queue, off the caller's thread).
    func record(_ entry: PresetUsageEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        let url = fileURL
        writeQueue.async { [weak self] in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: url, options: .atomic)
                }
                self?.compactIfNeeded()
            } catch {
                let msg = "[parleq] preset-usage: append failed: \(error)\n"
                FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
            }
        }
    }

    /// Convenience for the call sites: build + record an entry now.
    func record(presetID: String, presetName: String, appBundleID: String?, source: String) {
        record(PresetUsageEntry(ts: Date(), presetID: presetID, presetName: presetName,
                                appBundleID: appBundleID, source: source))
    }

    /// Rewrite-compact the file when it grows past the threshold, keeping
    /// the newest `compactKeep` lines. Runs on the write queue.
    private func compactIfNeeded() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var lines = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard lines.count > Self.compactThreshold else { return }
        lines = Array(lines.suffix(Self.compactKeep))
        let rewritten = lines.joined(separator: "\n") + "\n"
        try? rewritten.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    // MARK: - Read

    func readEntries() -> [PresetUsageEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [PresetUsageEntry] = []
        for line in text.split(whereSeparator: { $0.isNewline }) {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let e = try? decoder.decode(PresetUsageEntry.self, from: lineData) { out.append(e) }
        }
        return out
    }

    // MARK: - Declines (durable sidecar)

    func readDeclines() -> Set<PresetDefaultDecline> {
        var set: Set<PresetDefaultDecline> = []
        if let data = try? Data(contentsOf: declineURL),
           let arr = try? JSONDecoder().decode([PresetDefaultDecline].self, from: data) {
            set = Set(arr)
        }
        // Apply the synchronous in-memory overrides so a recompute that
        // races the async disk write still sees the latest decline/clear.
        overrideLock.lock()
        let adds = declineAdds, removals = declineRemovals
        overrideLock.unlock()
        set.formUnion(adds)
        set.subtract(removals)
        return set
    }

    /// Record a declined (or un-set) (app, preset) pair durably so the
    /// dominance suggestion never re-appears for it. The read-modify-write
    /// runs on the write queue (serial, so it's consistent) to keep file
    /// I/O off the main thread, matching `record()`.
    func recordDecline(appBundleID: String, presetID: String) {
        guard !appBundleID.isEmpty, !presetID.isEmpty else { return }
        let decline = PresetDefaultDecline(appBundleID: appBundleID, presetID: presetID)
        // Reflect it synchronously so an immediate suggestions() recompute
        // honors the decline before the async disk write completes.
        overrideLock.lock()
        declineAdds.insert(decline)
        declineRemovals.remove(decline)
        overrideLock.unlock()
        writeQueue.async { [weak self] in
            guard let self else { return }
            var set = self.readDeclines()
            set.insert(decline)
            self.writeDeclines(set)
        }
    }

    /// Remove a durable decline for an (app, preset) pair so the dominance
    /// suggestion can recompute and re-show it. Called when the user
    /// explicitly Restores a dismissed per-app-default activity entry — an
    /// intentional act that should undo the earlier durable decline.
    func clearDecline(appBundleID: String, presetID: String) {
        guard !appBundleID.isEmpty, !presetID.isEmpty else { return }
        let decline = PresetDefaultDecline(appBundleID: appBundleID, presetID: presetID)
        // Reflect it synchronously so a suggestions() recompute right after a
        // Restore (e.g. LearnedView .onAppear) sees the cleared decline
        // instead of racing the async disk write and re-filtering it out.
        overrideLock.lock()
        declineRemovals.insert(decline)
        declineAdds.remove(decline)
        overrideLock.unlock()
        writeQueue.async { [weak self] in
            guard let self else { return }
            var set = self.readDeclines()
            set.remove(decline)
            self.writeDeclines(set)
        }
    }

    private func writeDeclines(_ set: Set<PresetDefaultDecline>) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(set)) else { return }
        try? data.write(to: declineURL, options: .atomic)
    }

    // MARK: - Dominance rule (pure; unit-tested)

    /// Minimum MANUAL uses of a preset in an app before it can be
    /// suggested as that app's default.
    nonisolated static let dominanceMinManualUses = 5
    /// The winner must have at least this multiple of the runner-up's
    /// manual uses in the same app (clear dominance, not a near-tie).
    nonisolated static let dominanceMargin = 2

    /// Compute per-app default suggestions from a flat usage list, the
    /// already-configured app defaults, and the declined pairs. Pure so
    /// tests don't touch disk. Rules:
    ///   - Only MANUAL uses count (a default's own uses don't reinforce).
    ///   - Skip apps that already have a configured default (any preset).
    ///   - Skip apps whose resolved mode is not `.polished` (a preset
    ///     would never take effect for Instant or Raw apps).
    ///   - For an app with no default: the top preset must have
    ///     >= dominanceMinManualUses AND >= dominanceMargin x the
    ///     runner-up's manual uses.
    ///   - Skip any (app, preset) pair the user declined / un-set.
    ///   - Skip pairs whose preset no longer exists in `existingPresetIDs`.
    nonisolated static func computeSuggestions(
        entries: [PresetUsageEntry],
        configuredDefaults: [String: String],
        declined: Set<PresetDefaultDecline>,
        existingPresetIDs: Set<String>,
        nonPolishedApps: Set<String> = []
    ) -> [PresetDefaultSuggestion] {
        // appBundleID -> presetID -> (count, latest name)
        var byApp: [String: [String: (count: Int, name: String)]] = [:]
        for e in entries where e.source == "manual" {
            guard let app = e.appBundleID, !app.isEmpty, !e.presetID.isEmpty else { continue }
            // An app that already has a configured default is settled.
            if configuredDefaults[app] != nil { continue }
            // Skip apps whose mode is not Polished — a preset would never take effect there.
            if nonPolishedApps.contains(app) { continue }
            var perPreset = byApp[app] ?? [:]
            let prior = perPreset[e.presetID]?.count ?? 0
            perPreset[e.presetID] = (prior + 1, e.presetName)
            byApp[app] = perPreset
        }

        var suggestions: [PresetDefaultSuggestion] = []
        for (app, perPreset) in byApp {
            let ranked = perPreset.sorted { $0.value.count > $1.value.count }
            guard let top = ranked.first else { continue }
            // Preset must still exist.
            guard existingPresetIDs.contains(top.key) else { continue }
            // Not declined / un-set for this pair.
            if declined.contains(PresetDefaultDecline(appBundleID: app, presetID: top.key)) { continue }
            // Threshold.
            guard top.value.count >= dominanceMinManualUses else { continue }
            // Margin over the runner-up (if any).
            let runnerUp = ranked.count > 1 ? ranked[1].value.count : 0
            guard top.value.count >= max(1, runnerUp) * dominanceMargin || runnerUp == 0 else { continue }
            suggestions.append(PresetDefaultSuggestion(
                appBundleID: app, presetID: top.key, presetName: top.value.name,
                manualUses: top.value.count))
        }
        // Stable order: most-used first, then app id for determinism.
        return suggestions.sorted {
            $0.manualUses != $1.manualUses ? $0.manualUses > $1.manualUses
                                           : $0.appBundleID < $1.appBundleID
        }
    }

    /// Live wrapper: read disk + config and compute suggestions. Off the
    /// hot path (called when the Learned view opens).
    func suggestions(config: Config) -> [PresetDefaultSuggestion] {
        let entries = readEntries()
        // Build the set of candidate bundle IDs from the journal, then filter
        // to those whose resolved mode is not Polished (preset would never fire).
        let candidateApps = Set(entries.compactMap { $0.appBundleID })
        let nonPolishedApps = candidateApps.filter { config.behaviorForApp($0).mode != .polished }
        return Self.computeSuggestions(
            entries: entries,
            configuredDefaults: config.presetAppDefaults,
            declined: readDeclines(),
            existingPresetIDs: Set(config.transformPresets.map { $0.id }),
            nonPolishedApps: nonPolishedApps
        )
    }
}
