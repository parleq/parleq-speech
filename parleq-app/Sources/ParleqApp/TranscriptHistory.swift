// TranscriptHistory — in-memory ring buffer of recent cleaned
// transcripts so the user can grab one back if a paste went
// somewhere unexpected (focus changed mid-flight, target app
// stopped accepting input, etc.).
//
// Compliance shape: process memory only. Never written to disk.
// Entries vanish on app quit. This sits comfortably inside the
// "audio in memory only" / "no input data on local computer"
// rules from `docs/SECURITY_REVIEW.md` § 5 — the cleaned text was
// already sitting in process memory while the overlay was open;
// keeping it for the rest of the session adds no new persistence
// surface.
//
// Surfaced via the menu bar's "Recent Dictations" submenu
// (MenuBar.swift). Clicking an entry copies the full text to the
// pasteboard so the user can ⌘V it wherever they wanted in the
// first place.

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

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        text: String,
        targetAppName: String?,
        wasCleanupSuccessful: Bool = true
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.targetAppName = targetAppName
        self.wasCleanupSuccessful = wasCleanupSuccessful
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

@MainActor
final class TranscriptHistory {
    /// Singleton — accessed by AppState (the writer, on accept)
    /// and MenuBar (the reader, when the menu opens).
    static let shared = TranscriptHistory()

    /// Cap on how many recent dictations we hold. Picked low
    /// because the menu UI gets unwieldy past ~20 items, and
    /// because the typical "I missed where this pasted" recovery
    /// only needs the last 1–3 anyway. Bump if real usage
    /// suggests it's too tight.
    private static let maxEntries = 20

    /// Newest-first. Reads are cheap (the menu rebuilds on every
    /// open), so we keep the storage shape simple.
    private(set) var entries: [TranscriptEntry] = []

    private init() {}

    /// Add a new entry. Drops the oldest when over the cap.
    func append(_ entry: TranscriptEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    /// Wipe the buffer. Wired to the menu's "Clear Recent" item.
    func clear() {
        entries.removeAll()
    }
}
