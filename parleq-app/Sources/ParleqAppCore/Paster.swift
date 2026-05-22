// Paster — pastes a string into a previously-frontmost macOS app.
//
// Flow:
//   1. captureFrontmost() at hotkey-down records which app was active
//      before the user invoked us. We must capture this *before* our
//      own app potentially steals focus (permission prompts, etc).
//   2. paste(text:into:) puts `text` on the system pasteboard,
//      activates the captured app, waits briefly for the activation
//      to settle, and posts a synthetic Cmd-V via CGEvent.
//
// Caveats / known v0.1 limitations:
//   - The user's previous pasteboard contents are clobbered. Future
//     polish (M5+) will save and restore.
//   - We post Cmd-V with .cghidEventTap, which works in essentially
//     every text input field but may misbehave with apps that have
//     custom paste handlers. None of our v0.1 target apps do.
//   - `NSRunningApplication.activate(options:)` is deprecated in
//     macOS 14+ in favor of `activate()`; we use the new form.
//   - The post-activate sleep is empirical. 80 ms is enough on a
//     warm window manager; if we see flakiness we'll move to a
//     focus-confirmation observer instead of a fixed delay.

import AppKit
import CoreGraphics
import Foundation

struct PasteTarget: Sendable {
    let pid: pid_t
    let name: String
    /// The frontmost app's bundle identifier (e.g.
    /// "com.googlecode.iterm2"). nil for processes that don't have
    /// a bundle (rare on macOS for user-facing apps). Used for the
    /// trailing-space denylist in Config.noTrailingSpaceAppBundleIDs.
    let bundleID: String?
}

enum PasterError: Error, CustomStringConvertible {
    case noFrontmostApp
    case targetGone(pid_t)
    case eventSourceFailed
    case eventCreateFailed

    var description: String {
        switch self {
        case .noFrontmostApp:
            return "No frontmost app to capture (NSWorkspace returned nil)."
        case .targetGone(let pid):
            return "Target app pid=\(pid) is no longer running."
        case .eventSourceFailed:
            return "CGEventSource init failed."
        case .eventCreateFailed:
            return "CGEvent create for Cmd-V failed."
        }
    }
}

enum Paster {
    /// Capture the currently-frontmost application. Call this at
    /// hotkey-down before any UI work in our app could shift focus.
    /// Returns nil only if NSWorkspace can't see any frontmost app
    /// (rare; usually only during very early app launch).
    static func captureFrontmost() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return PasteTarget(
            pid: app.processIdentifier,
            name: app.localizedName ?? "app pid=\(app.processIdentifier)",
            bundleID: app.bundleIdentifier
        )
    }

    /// Set the system pasteboard to `text`, activate the previously-
    /// captured app, wait briefly, post a synthetic Cmd-V to trigger
    /// the paste, then restore whatever pasteboard contents the user
    /// had before. Throws if the target app is no longer running or
    /// CGEvent creation fails.
    ///
    /// Pasteboard save/restore: NSPasteboard can hold multiple
    /// "pasteboard items," each carrying multiple representations
    /// (string, RTF, image, file URLs, etc). We snapshot the full
    /// item list and re-write it after the paste. The 200 ms restore
    /// delay is the empirical "enough time for the target app to
    /// have read the pasteboard" budget: tools like Maestro and
    /// Espanso use similar values. Too short and the restore races
    /// the read; too long and a fast manual Cmd-V repeat would see
    /// our text instead of the user's original.
    @MainActor
    static func paste(text: String, into target: PasteTarget) async throws {
        let pb = NSPasteboard.general
        let snapshot = snapshotPasteboard(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        guard let runningApp = NSRunningApplication(processIdentifier: target.pid) else {
            // Restore the pasteboard before bailing — we already
            // overwrote it, even though the paste itself didn't
            // happen.
            restorePasteboard(pb, from: snapshot)
            throw PasterError.targetGone(target.pid)
        }
        runningApp.activate()

        // Empirical: 80 ms is enough for window-server focus to land
        // on the activated app on a warm system. Without this, Cmd-V
        // gets posted to whichever app currently owns the input
        // focus, which is often *us* (the parleq-app process) since
        // we just stole focus from the activate call.
        try await Task.sleep(nanoseconds: 80_000_000)

        do {
            try postCommandV()
        } catch {
            restorePasteboard(pb, from: snapshot)
            throw error
        }

        // Wait long enough for the target app to read the pasteboard
        // before we restore. 200 ms covers the slowest text-input
        // paste handlers we've seen.
        try? await Task.sleep(nanoseconds: 200_000_000)
        restorePasteboard(pb, from: snapshot)
    }

    // MARK: - Pasteboard save/restore

    /// PasteboardSnapshot captures the full set of items on the
    /// general pasteboard, each item carrying every type currently
    /// present on it. Items can hold images, files, URLs, RTF, plain
    /// strings — restoring all types is what keeps a user's "I
    /// copied a screenshot" workflow intact across a parleq paste.
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshotPasteboard(_ pb: NSPasteboard) -> PasteboardSnapshot {
        guard let items = pb.pasteboardItems else { return PasteboardSnapshot(items: []) }
        var captured: [[NSPasteboard.PasteboardType: Data]] = []
        for item in items {
            var byType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    byType[type] = data
                }
            }
            captured.append(byType)
        }
        return PasteboardSnapshot(items: captured)
    }

    private static func restorePasteboard(_ pb: NSPasteboard, from snapshot: PasteboardSnapshot) {
        pb.clearContents()
        if snapshot.items.isEmpty { return }
        let items: [NSPasteboardItem] = snapshot.items.map { typeMap in
            let item = NSPasteboardItem()
            for (type, data) in typeMap {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(items)
    }

    /// Post a synthetic Cmd-V key sequence as if the user typed it.
    /// Works against the currently-focused app; the caller is
    /// responsible for having activated the right target first.
    private static func postCommandV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw PasterError.eventSourceFailed
        }
        // Virtual key code 9 = V on US/QWERTY. macOS dispatches Cmd-V
        // by virtual key code regardless of the user's actual layout
        // (Cmd-V is a "logical" shortcut), so this works on Dvorak,
        // AZERTY, etc.
        let vK: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vK, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vK, keyDown: false)
        else {
            throw PasterError.eventCreateFailed
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
