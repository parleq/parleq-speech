// HFDownload — pure decision logic for the in-process streaming model
// downloader (#89). Kept separate from the URLSession machinery so the parts
// that decide *what* to fetch, *where* to resume, and *how full* the bar is
// are unit-testable without touching the network.
//
// Why a custom downloader at all: macOS runs URLSession *download* tasks
// out-of-process (nsurlsessiond), so HF's library only learns progress at
// whole-file completion — the multi-GB LFS shards freeze the bar mid-shard.
// Streaming the bytes ourselves (URLSessionDataDelegate, see
// HFStreamingDownloader) gives real within-file progress. Full diagnosis in #89.
import Foundation

public enum HFDownload {
    /// The Hugging Face "resolve" URL for one file in a repo at a revision —
    /// `{host}/{namespace}/{name}/resolve/{revision}/{path}`. Mirrors the path
    /// the HF library builds in `getFile` (HubClient+Files.swift); a GET here
    /// 302-redirects to the CDN, which URLSession follows automatically.
    public static func resolveURL(
        host: URL, namespace: String, name: String, revision: String, path: String
    ) -> URL {
        var url = host
            .appendingPathComponent(namespace)
            .appendingPathComponent(name)
            .appendingPathComponent("resolve")
            .appendingPathComponent(revision)
        // Append the repo-relative path preserving its sub-path separators
        // (appendingPathComponent percent-encodes a "/" inside the component,
        // so split and append each segment).
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(segment))
        }
        return url
    }

    /// Defense-in-depth path-traversal guard: reject absolute paths or any path
    /// containing a ".." component before writing it under the model directory.
    /// (appendingPathComponent does NOT resolve ".." on macOS — it concatenates
    /// — so a malicious entry path could otherwise escape the directory.)
    public static func isUnsafeRepoPath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        return path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// What to do for a single file given what's already on disk vs. the size
    /// `listFiles` reported. `.skip` when it's fully present, `.resume` from the
    /// on-disk offset when it's a usable partial, `.fresh` otherwise (nothing on
    /// disk, or a partial larger than expected — corrupt/stale, start over).
    public enum FileAction: Equatable, Sendable {
        case skip
        case resume(from: Int64)
        case fresh
    }

    public static func plan(onDiskBytes: Int64, expectedBytes: Int64?) -> FileAction {
        guard onDiskBytes > 0 else { return .fresh }
        if let expected = expectedBytes {
            if onDiskBytes == expected { return .skip }
            if onDiskBytes > expected { return .fresh }   // corrupt / stale
        }
        return .resume(from: onDiskBytes)
    }

    /// HTTP `Range` header value to resume from `offset`, or nil when starting
    /// from the beginning (no Range header on a fresh download).
    public static func rangeHeader(resumingFrom offset: Int64) -> String? {
        offset > 0 ? "bytes=\(offset)-" : nil
    }

    /// Byte-accurate progress fraction, clamped to 0…1 (and 0 when total is 0).
    public static func fraction(downloaded: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(Double(downloaded) / Double(total), 1.0)
    }
}
