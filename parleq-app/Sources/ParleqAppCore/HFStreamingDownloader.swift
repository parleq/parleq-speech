// HFStreamingDownloader — the network half of the in-process model downloader
// (#89). Streams each file's bytes to disk via a URLSessionDataDelegate so
// progress is byte-accurate WITHIN a file, unlike URLSession download tasks
// (which run out-of-process in nsurlsessiond and only report at whole-file
// completion — the bug #89 fixes). The pure decisions (resolve URL, resume
// plan, Range header, progress math) live in HFDownload and are unit-tested;
// this file owns the byte loop, which is exercised by a real ~6 GB download.
import Foundation

public enum HFDownloadError: Error, LocalizedError {
    case httpStatus(Int)
    case notHTTPResponse

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "Download failed with HTTP status \(code)."
        case .notHTTPResponse: return "Download failed: unexpected (non-HTTP) response."
        }
    }
}

/// One file resolved to its remote URL, on-disk destination, expected size, and
/// the action decided by `HFDownload.plan`.
public struct HFPlannedFile: Sendable {
    public let url: URL
    public let destination: URL
    public let expectedBytes: Int64?
    public let action: HFDownload.FileAction

    public init(url: URL, destination: URL, expectedBytes: Int64?, action: HFDownload.FileAction) {
        self.url = url
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.action = action
    }
}

/// Downloads a set of planned files in order, streaming bytes to disk and
/// reporting an overall byte-accurate fraction. Cancellation (via the
/// surrounding Task) stops the in-flight transfer and leaves partial files on
/// disk for a later resume; it surfaces as `CancellationError`.
public final class HFStreamingDownloader: @unchecked Sendable {
    public init() {}

    /// `totalBytes` is the sum of every file's expected size (skipped files
    /// included) so the fraction reflects the whole download. `onProgress` is
    /// called on an arbitrary queue with a clamped 0…1 fraction; it is throttled
    /// to 0.1% steps so it never floods the main actor.
    public func download(
        _ files: [HFPlannedFile],
        totalBytes: Int64,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let throttle = ProgressThrottle(onProgress: onProgress)
        // Bytes from files that are already fully accounted for (skipped, or
        // completed earlier in this loop). The in-flight file adds its own
        // running count on top.
        var doneBytes: Int64 = 0

        for file in files {
            try Task.checkCancellation()

            switch file.action {
            case .skip:
                doneBytes += file.expectedBytes ?? 0
                throttle.emit(HFDownload.fraction(downloaded: doneBytes, total: totalBytes))
                continue

            case .fresh, .resume:
                let resumeFrom: Int64
                if case .resume(let from) = file.action { resumeFrom = from } else { resumeFrom = 0 }

                try FileManager.default.createDirectory(
                    at: file.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)

                let handle = try openHandle(at: file.destination, resumeFrom: resumeFrom)
                defer { try? handle.close() }

                var request = URLRequest(url: file.url)
                if let range = HFDownload.rangeHeader(resumingFrom: resumeFrom) {
                    request.setValue(range, forHTTPHeaderField: "Range")
                }

                let base = doneBytes
                let streamer = FileStreamer(handle: handle, resumeFrom: resumeFrom) { fileBytes in
                    throttle.emit(HFDownload.fraction(downloaded: base + fileBytes, total: totalBytes))
                }
                let written = try await streamer.run(request: request)
                doneBytes += written
                throttle.emit(HFDownload.fraction(downloaded: doneBytes, total: totalBytes))
            }
        }
        // Land exactly on 1.0 at the end regardless of size-estimate drift.
        onProgress(1.0)
    }

    /// Opens the destination for writing: truncated for a fresh download,
    /// positioned at end for a resume. Creates the file if absent.
    private func openHandle(at url: URL, resumeFrom: Int64) throws -> FileHandle {
        if resumeFrom == 0 || !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            return handle
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}

/// Coalesces progress callbacks to 0.1% steps so a 16–64 KB chunk stream over a
/// multi-GB file doesn't post tens of thousands of main-actor updates.
private final class ProgressThrottle: @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var lastStep = -1

    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func emit(_ fraction: Double) {
        let step = Int(fraction * 1000)
        lock.lock()
        let changed = step != lastStep
        if changed { lastStep = step }
        lock.unlock()
        if changed { onProgress(fraction) }
    }
}

/// Streams ONE file to an open FileHandle via the data-task delegate, reporting
/// cumulative bytes-for-this-file as chunks arrive. Returns the final byte count
/// on success; throws on HTTP/write errors, and `CancellationError` on cancel.
private final class FileStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let resumeFrom: Int64
    private let onFileBytes: @Sendable (Int64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64, Error>?
    private var task: URLSessionDataTask?   // lock-protected (written in run, read in onCancel)

    // Touched only on the (serial) delegate queue after the task starts.
    private var bytesThisFile: Int64
    private var streamError: Error?

    init(handle: FileHandle, resumeFrom: Int64, onFileBytes: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle
        self.resumeFrom = resumeFrom
        self.bytesThisFile = resumeFrom
        self.onFileBytes = onFileBytes
    }

    func run(request: URLRequest) async throws -> Int64 {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, Error>) in
                let dataTask = session.dataTask(with: request)
                lock.lock()
                continuation = cont
                task = dataTask
                lock.unlock()
                dataTask.resume()
                // Cancel that arrived before the task existed (tiny window):
                // resume()+cancel() still drives didCompleteWithError(.cancelled).
                if Task.isCancelled { dataTask.cancel() }
            }
        } onCancel: {
            lock.lock(); let inFlight = task; lock.unlock()
            inFlight?.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            recordFailure(HFDownloadError.notHTTPResponse)
            completionHandler(.cancel)
            return
        }
        if resumeFrom > 0 {
            switch http.statusCode {
            case 206:
                break   // partial content — append onto the existing bytes
            case 200:
                // Server ignored Range (or a redirect dropped it): it's sending
                // the whole file. Truncate and restart this file from zero so we
                // don't append fresh bytes onto stale ones.
                do {
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                } catch {
                    recordFailure(error); completionHandler(.cancel); return
                }
                bytesThisFile = 0
                onFileBytes(0)
            default:
                recordFailure(HFDownloadError.httpStatus(http.statusCode))
                completionHandler(.cancel)
                return
            }
        } else if http.statusCode != 200 {
            recordFailure(HFDownloadError.httpStatus(http.statusCode))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            recordFailure(error)
            dataTask.cancel()
            return
        }
        bytesThisFile += Int64(data.count)
        onFileBytes(bytesThisFile)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let finalError: Error?
        if let streamError {
            finalError = streamError
        } else if let urlError = error as? URLError, urlError.code == .cancelled {
            // Map URLSession's cancellation to CancellationError so callers
            // treat a user cancel as "leave partials", not a hard failure.
            finalError = CancellationError()
        } else {
            finalError = error
        }
        finish(with: finalError)
    }

    // MARK: continuation plumbing

    private func recordFailure(_ error: Error) {
        if streamError == nil { streamError = error }
    }

    private func finish(with error: Error?) {
        lock.lock(); let cont = continuation; continuation = nil; lock.unlock()
        guard let cont else { return }
        if let error { cont.resume(throwing: error) } else { cont.resume(returning: bytesThisFile) }
    }
}
