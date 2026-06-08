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

    /// The frontmost on-screen, normal-layer window owned by `pid`.
    /// `CGWindowListCopyWindowInfo` returns windows front-to-back, so
    /// the first layer-0 match is the frontmost window of that app —
    /// used by the "hold-hotkey + C" gesture to attach the window the
    /// user is currently looking at as a reference, without a picker.
    /// `title` may be empty without Screen Recording permission; only
    /// `windowID` is needed to capture.
    static func frontmostWindow(forPID pid: pid_t) -> (windowID: CGWindowID, title: String)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infoList {
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner == pid else { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            guard let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            let title = (info[kCGWindowName as String] as? String) ?? ""
            return (windowNumber, title)
        }
        return nil
    }

    /// Activate an app by bundle ID via an AppleScript `tell
    /// application id "..." to activate` AppleEvent. This is the
    /// activation path that crosses full-screen-Space boundaries
    /// (issue #212). NSRunningApplication.activate() is blocked by
    /// macOS from yanking the user out of a full-screen Space — Apple
    /// reserves that capability for the Dock, notifications, and the
    /// App Switcher path. The AppleScript `activate` AppleEvent goes
    /// through Apple Events / OSA, which IS one of the mechanisms
    /// macOS treats as legitimate cross-Space activation. Tested
    /// 2026-05-27 (spike #223 Step 4): with Safari full-screen on its
    /// own Space and iTerm2 frontmost, this call animated the Space
    /// transition and brought Safari forward. The previously tried
    /// paths (CGEvent Cmd+Tab synthesis, AppleScript key code 48 +
    /// Cmd) all filter full-screen-Space apps out of the switch
    /// cycle; only direct `activate` works.
    ///
    /// Falls back to `NSRunningApplication.activate()` (PID-based) on
    /// any AppleScript error or when bundleID is nil — that keeps the
    /// regular-Space case working when the target lacks a scripting
    /// dictionary (rare; vanishingly few user-facing macOS apps).
    @MainActor
    static func activate(bundleID: String?, pid: pid_t) {
        if let bundleID = bundleID, !bundleID.isEmpty {
            // Quote-strip defense: NSRunningApplication.bundleIdentifier
            // returns reverse-DNS-form strings under macOS conventions
            // (com.apple.Safari etc.), but a defensive quote scrub costs
            // nothing and forecloses any AppleScript-injection vector if
            // a future caller passes a less-trusted source.
            let safe = bundleID.replacingOccurrences(of: "\"", with: "")
            let source = "tell application id \"\(safe)\" to activate"
            if let script = NSAppleScript(source: source) {
                var error: NSDictionary?
                _ = script.executeAndReturnError(&error)
                if error == nil {
                    return
                }
                // AppleScript failure typically means the app has no
                // scripting dictionary or has crashed. Fall through to
                // the PID path below; if the app is just gone, that
                // call is a no-op too.
            }
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
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
        // PID-based activation — keeps the paste-back path on the
        // fast direct route for the dominant case (paste target is a
        // regular-Space app, NSRunningApplication.activate is sub-
        // 10ms and side-effect-free). The AppleScript bundle-id path
        // (which crosses full-screen-Space boundaries for issue #212)
        // is reserved for the reference-capture focus-restore paths
        // via Paster.activate, where the latency + MainActor block
        // is acceptable. Routing every dictation's paste through
        // AppleScript briefly destabilized the CGEventTap state and
        // surfaced as the press-Space-after-plain-dictation lockout
        // observed in 0.14.0 Phase 6.5 testing.
        runningApp.activate()

        // Empirical: 80 ms is enough for window-server focus to land
        // on the activated app on a warm system. Without this, Cmd-V
        // gets posted to whichever app currently owns the input
        // focus, which is often *us* (the parleq-app process) since
        // we just stole focus from the activate call.
        try await Task.sleep(nanoseconds: 80_000_000)

        // Tap-accept race fix: when the user TAPS the dictation hotkey
        // (a modifier — default right Option) to accept, the accept()
        // path can reach here while that modifier is still PHYSICALLY
        // down. A synthetic Cmd-V posted to .cghidEventTap is merged
        // by the window server with the live hardware modifier state,
        // so the target app would receive Cmd-Option-V (or Cmd-Ctrl-V,
        // etc.) — which apps ignore, producing the long-standing
        // "overlay closed, nothing pasted" intermittent drop. The
        // Enter-accept path holds no modifier, so this wait returns
        // immediately and is a no-op for it. Best-effort + bounded:
        // we proceed after the cap regardless so a stuck/held modifier
        // never wedges the paste.
        let waitedMs = await waitForModifiersToClear()

        do {
            // Sample the ambient modifier mask BEFORE posting (review
            // finding): on the cap-expired path the held modifier can
            // release in the gap between post and trace, masking the very
            // race we'd want to diagnose. Cheap + gated on the trace flag.
            let ambientAtPost = Paster.pasteTrace
                ? Paster.currentSessionModifierFlags().intersection(pasteCorruptingModifiers)
                : CGEventFlags()
            try postCommandV()
            if Paster.pasteTrace {
                emitPasteTrace(waitedMs: waitedMs, ambient: ambientAtPost)
            }
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
        // Override (never inherit) the event flags so no stray modifier
        // — Option/Control/Shift/Fn left over from a hotkey tap — can
        // ride along on the nominal CGEvent flags. Computed by a pure
        // function (testable) that strips everything and asserts exactly
        // Command. NB: this guards the event's OWN flags; the physical
        // hardware modifier merge at .cghidEventTap is handled by the
        // bounded wait in paste() above.
        let outgoing = pasteEventFlags()
        down.flags = outgoing
        up.flags = outgoing
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Synthetic-paste flag composition & modifier wait
    //
    // Two pure, unit-testable helpers + the production wait that drives
    // them. The CGEvent post itself can't run headless, but the
    // flag-composition and "are the modifiers clear?" decisions can be
    // exercised in tests so the tap-accept race fix can't silently
    // regress.

    /// Modifiers that, if PHYSICALLY held at the moment we post Cmd-V,
    /// get merged into the synthetic event by the window server and
    /// corrupt the paste (Cmd-Option-V, Cmd-Ctrl-V, …). The dictation
    /// hotkey is one of these (default right Option), so a tap-accept
    /// can leave one set. Command is included for completeness: a held
    /// Command is implausible during accept and would only add bounded
    /// latency, never a wrong result.
    static let pasteCorruptingModifiers: CGEventFlags =
        [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]

    /// PURE. The flags the synthetic paste event must carry: EXACTLY
    /// `.maskCommand`, regardless of whatever ambient state exists.
    /// Defends against any future caller passing inherited flags.
    static func pasteEventFlags() -> CGEventFlags { .maskCommand }

    /// PURE. True when none of `mask`'s bits are set in `state` — i.e.
    /// the corruption-prone modifiers are physically clear and it's
    /// safe to post Cmd-V now. Drives both the immediate-proceed case
    /// (Enter accept: nothing held) and the wait loop (tap accept:
    /// poll until the hotkey modifier lifts).
    static func modifierMaskClear(state: CGEventFlags, mask: CGEventFlags) -> Bool {
        state.intersection(mask).isEmpty
    }

    /// Bounded poll for the corruption-prone modifiers to lift before
    /// we post Cmd-V. Returns the elapsed wait in milliseconds (0 when
    /// already clear — the Enter-accept path). Caps at ~150 ms then
    /// proceeds best-effort so a genuinely stuck modifier can never
    /// wedge a paste.
    private static let modifierWaitCapMs = 150
    private static let modifierPollMs = 5

    private static func waitForModifiersToClear() async -> Int {
        var elapsedMs = 0
        while elapsedMs <= modifierWaitCapMs {
            let state = currentSessionModifierFlags()
            if modifierMaskClear(state: state, mask: pasteCorruptingModifiers) {
                return elapsedMs
            }
            try? await Task.sleep(nanoseconds: UInt64(modifierPollMs) * 1_000_000)
            elapsedMs += modifierPollMs
        }
        return elapsedMs
    }

    /// The live session-wide modifier flag state (combined left+right
    /// for each family). Reads the same source the paste post uses.
    private static func currentSessionModifierFlags() -> CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
    }

    // MARK: - Opt-in paste trace (PARLEQ_PASTE_TRACE=1)
    //
    // Count/code-only: logs the ambient corruption-prone modifier bits
    // seen at post time and how long we waited. NEVER any transcript or
    // pasteboard CONTENT — flags + waited-ms only — so it's safe to
    // leave wired for live diagnosis of the race fix.
    private static let pasteTrace: Bool =
        ProcessInfo.processInfo.environment["PARLEQ_PASTE_TRACE"] == "1"

    private static func emitPasteTrace(waitedMs: Int, ambient: CGEventFlags) {
        let mask = String(ambient.rawValue, radix: 16)
        FileHandle.standardError.write(
            "[parleq] paste post (ambientMods=0x\(mask), waited=\(waitedMs)ms)\n"
                .data(using: .utf8) ?? Data()
        )
    }
}
