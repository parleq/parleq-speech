// LogFile — append-only debug log at ~/.parleq/app.log.
//
// At app launch we `dup2` the process's stderr file descriptor to
// this file. Every existing call to `FileHandle.standardError.write`
// (logStderr in ParleqApp/AudioRecorder, AppState.log, supervisor's
// log writes, etc.) automatically lands in the file without code
// changes elsewhere. The log survives reboots — it lives under
// `~/.parleq/`, not `/tmp/` — so users can still read it after a
// crash + restart cycle.
//
// Content profile (matches the rest of Parleq's redaction discipline,
// see docs/SECURITY_REVIEW.md):
//   - Phase transitions, ASR latency + length, LLM token counts,
//     supervisor lifecycle messages, error stack traces.
//   - NEVER transcript content, audio bytes, or auth values.
// The Gemini API key is sent via `x-goog-api-key` HTTP header (not
// the URL query parameter), so even if URLSession's diagnostics
// were ever to log the request URL, the key would not be in it.
//
// Rotation: capped at 10 MB. On launch, if the file exceeds the
// cap, we truncate to the last 5 MB so we keep recent context but
// don't grow unboundedly.
//
// Dev mode: when stderr is a TTY (running from `swift run` in a
// terminal) we leave it alone. The dev wants to see live output
// in their terminal, and the .app's launchd-spawned stderr
// redirection isn't relevant.

import Darwin
import Foundation

public enum LogFile {
    /// Hard cap on log size before we truncate.
    private static let maxSize: UInt64 = 10 * 1024 * 1024  // 10 MB
    /// How much to keep when truncating — most-recent suffix.
    private static let truncateTo: Int = 5 * 1024 * 1024  // 5 MB

    /// Path where stderr is redirected on launch.
    public static var path: String {
        "\(NSHomeDirectory())/.parleq/app.log"
    }

    /// Call once at app startup, before any other logging happens.
    /// No-op if stderr is already a TTY (developer mode).
    public static func install() {
        // Skip redirection when running from a terminal — the dev
        // wants live output, and they can `tail -f ~/.parleq/app.log`
        // from another terminal if they need both. Detection: fd 2
        // is a TTY iff running interactively.
        if isatty(fileno(stderr)) == 1 {
            return
        }
        let dir = "\(NSHomeDirectory())/.parleq"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        rotateIfTooLarge()
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else {
            // Best-effort — stderr is still wired to its launchd
            // default; we just won't have a persistent log.
            FileHandle.standardError.write(
                "[parleq] log: failed to open \(path) (errno \(errno))\n"
                    .data(using: .utf8) ?? Data()
            )
            return
        }
        // Make every subsequent write to fd 2 land in the file.
        if dup2(fd, fileno(stderr)) < 0 {
            FileHandle.standardError.write(
                "[parleq] log: dup2 failed (errno \(errno))\n"
                    .data(using: .utf8) ?? Data()
            )
        }
        close(fd)
        // Header line so log lifecycle is greppable when tailing.
        // Goes via our redirected stderr → lands in the file.
        let stamp = ISO8601DateFormatter().string(from: Date())
        let header = "\n=== Parleq launched (pid=\(getpid()), \(stamp)) ===\n"
        FileHandle.standardError.write(header.data(using: .utf8) ?? Data())
    }

    /// Truncate the log to `truncateTo` if it's already over
    /// `maxSize`. Run once at install() time. We don't try to
    /// rotate mid-session because logs are bounded by typical
    /// dictation cadence (a few KB per utterance) and we'd rather
    /// not introduce a watchdog thread.
    private static func rotateIfTooLarge() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              size > maxSize
        else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return
        }
        let kept = data.suffix(truncateTo)
        try? kept.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
