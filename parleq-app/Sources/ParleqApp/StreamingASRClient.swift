// StreamingASRClient — pushes raw int16 LE PCM to the FluidAudio
// sidecar's /stream-nemo endpoint over a chunked HTTP POST and
// returns the final transcript when the body closes.
//
// Why streaming: the sidecar's Nemotron 0.6B encoder is cache-aware
// and processes audio chunks during the user's speech. By the time
// the user releases the hotkey, most of the audio has already been
// encoded; only the trailing chunk needs to be processed. This is
// the post-utterance-latency win measured in our benchmarks
// (48 ms p95 vs 110 ms for batch /inference).
//
// Wire format:
//   - POST http://127.0.0.1:8767/stream-nemo
//   - Content-Type: audio/pcm-mono16-16k (informational)
//   - Body: raw 16-bit signed LE PCM at 16 kHz mono, no WAV header
//   - Body uses HTTP chunked transfer encoding (forced by leaving
//     Content-Length unset and giving URLSession a streamed body)
//
// Implementation: URLSession.uploadTask(withStreamedRequest:)
// expects the URLRequest's `httpBodyStream` to provide bytes. We
// pair an InputStream (consumed by URLSession) with an OutputStream
// (written to by our pushPCM calls) via Stream.getBoundStreams. On
// finish() we close the OutputStream, which signals end-of-body to
// URLSession, which closes the request — and the sidecar finalizes
// and returns the JSON {"text": "..."} response.
//
// Phase B (current): the sidecar emits Server-Sent Events on
// /stream-nemo. We parse incoming SSE `data: {...}` lines and call
// onPartial(text) for each "partial" event and resolve finish()'s
// continuation when the "final" event arrives. Old phase-A
// behavior (final-only JSON) is no longer supported by the sidecar.

import Foundation

private func logStreamingASR(_ message: String) {
    if let data = "[parleq] streaming-asr: \(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

enum StreamingASRError: Error, CustomStringConvertible {
    case streamCreateFailed
    case sessionFailed(Error)
    case badStatus(Int, String)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .streamCreateFailed:
            return "Stream.getBoundStreams returned nil streams"
        case .sessionFailed(let underlying):
            return "URLSession upload failed: \(underlying)"
        case .badStatus(let code, let body):
            return "/stream-nemo HTTP \(code): \(body)"
        case .malformedResponse(let detail):
            return "/stream-nemo response malformed: \(detail)"
        }
    }
}

struct StreamingASRResult {
    let text: String
    /// Total wall-clock from session start() to response received.
    /// Includes the duration of the user's speech plus
    /// post-utterance latency. Use postUtteranceLatency for the
    /// "user released hotkey → got transcript" window.
    let totalLatency: TimeInterval
    /// Wall-clock from finish() (i.e. user releasing the hotkey)
    /// to the final transcript arriving — the post-utterance latency
    /// metric.
    let postUtteranceLatency: TimeInterval
}

/// One streaming session = one utterance. Construct, start(),
/// pushPCM each captured PCM chunk, await finish() for the
/// transcript. After finish the session is done; create a new one
/// for the next utterance.
///
/// Not actor-isolated: pushPCM is called from the AVAudioEngine
/// tap callback (audio thread), while start/finish/cancel are
/// called from MainActor. The actor split would force every
/// audio chunk through a MainActor hop, which we don't want at
/// 16 kHz sample rate. Internal access is safe: `output` is set
/// once during start() and read-only thereafter, NSLock guards
/// the lifecycle bookkeeping.
final class StreamingASRSession: @unchecked Sendable {
    private let url: URL
    private var output: OutputStream?
    private var task: URLSessionUploadTask?
    private var session: URLSession?
    private var delegate: StreamingASRDelegate?
    private var sessionStarted: Date?
    private var finishCalled: Date?
    /// Diagnostics for the "transcript stops mid-utterance" bug.
    /// All written from the audio thread (pushPCM); read from
    /// MainActor at finish(). Single-producer single-consumer, so
    /// they don't need a lock; we accept the small risk of slightly
    /// stale reads since they're for logging only.
    private var droppedChunks = 0
    private var uploadedBytes = 0
    private var chunkCount = 0
    /// Optional partial-transcript callback. Fires once per SSE
    /// "partial" event from the sidecar, with the cumulative
    /// transcript text up to that point. Called on URLSession's
    /// delegate queue, NOT MainActor — UI updates must hop.
    var onPartial: (@Sendable (String) -> Void)?

    init(url: URL = URL(string: "http://127.0.0.1:8767/stream-nemo")!) {
        self.url = url
    }

    /// Open the HTTP connection and start the chunked body stream.
    /// Must be called before pushPCM. Throws if the bound-stream
    /// pair can't be created or the URLSession refuses the request.
    func start() throws {
        var inputStream: InputStream?
        var outputStream: OutputStream?
        // 64 KiB internal buffer between our writes and URLSession's
        // reads. Audio chunks at 16 kHz × int16 are 32 KiB/s, so a
        // 64 KiB buffer holds about 2 seconds of audio before
        // backpressure — far more than the network round-trip.
        Stream.getBoundStreams(
            withBufferSize: 64 * 1024,
            inputStream: &inputStream,
            outputStream: &outputStream
        )
        guard let input = inputStream, let output = outputStream else {
            throw StreamingASRError.streamCreateFailed
        }
        // The OutputStream needs to be open before any writes. The
        // InputStream is opened by URLSession when it starts pulling.
        output.schedule(in: RunLoop.main, forMode: .default)
        output.open()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/pcm-mono16-16k", forHTTPHeaderField: "Content-Type")
        // Long-form dictation can run for minutes. The URLRequest
        // idle-timeout default is 60 s, which means a brief pause in
        // SSE events from the sidecar (slow ASR chunk, GC, anything)
        // can kill the connection mid-utterance — the symptom is
        // "the dictation stops growing after a while". 1 hour gives
        // plenty of headroom for any single utterance.
        request.timeoutInterval = 3600
        request.httpBodyStream = input

        let delegate = StreamingASRDelegate()
        delegate.onPartial = { [weak self] text in
            self?.onPartial?(text)
        }
        self.delegate = delegate

        // URLSessionConfiguration's own timeouts also apply to
        // requests issued through it. Match them to the request-level
        // values so neither side is the limiting factor.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 3600
        let session = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
        self.session = session

        let task = session.uploadTask(withStreamedRequest: request)
        task.resume()
        self.task = task
        self.output = output
        self.sessionStarted = Date()
    }

    /// Push a PCM chunk to the upload body. Blocking only briefly
    /// (until the bound-stream pair has buffer space, which at
    /// 32 KiB/s and a 64 KiB buffer means it never actually blocks
    /// under normal use). Safe to call repeatedly from the audio
    /// capture thread; the OutputStream is thread-safe for writes
    /// from a single producer.
    func pushPCM(_ data: Data) {
        guard let output = output else {
            droppedChunks += 1
            return
        }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var written = 0
            while written < data.count {
                let chunk = output.write(base.advanced(by: written), maxLength: data.count - written)
                if chunk <= 0 {
                    // 0 = buffer full (would block); negative = error.
                    // Either way we silently drop — but log the FIRST
                    // drop so the cutoff issue (transcript stops
                    // growing mid-utterance) leaves a breadcrumb. We
                    // don't log every drop because once it starts
                    // failing it tends to fail in bursts.
                    if droppedChunks == 0 {
                        let kind = chunk == 0 ? "buffer-full" : "stream-error"
                        logStreamingASR("pushPCM dropped first chunk (\(kind), code=\(chunk))")
                    }
                    droppedChunks += 1
                    return
                }
                written += chunk
            }
            uploadedBytes += data.count
            chunkCount += 1
        }
    }

    /// Close the body stream and await the final transcript.
    /// Cleans up the URLSession on completion.
    func finish() async throws -> StreamingASRResult {
        finishCalled = Date()
        output?.close()
        defer {
            session?.invalidateAndCancel()
            session = nil
            task = nil
            delegate = nil
            output = nil
        }
        guard let delegate = delegate else {
            throw StreamingASRError.malformedResponse("no delegate")
        }
        // Diagnostics: how much audio did we get to upload, and how
        // many partials came back? Cuts the search space when the
        // user reports the transcript stopping mid-utterance.
        let stats = delegate.diagnosticsString()
        logStreamingASR(
            "finish: chunks=\(chunkCount), uploaded=\(uploadedBytes / 1024)KB, dropped=\(droppedChunks), \(stats)"
        )
        let text = try await delegate.awaitFinalText()

        let now = Date()
        let started = sessionStarted ?? now
        let total = now.timeIntervalSince(started)
        let postUtterance = now.timeIntervalSince(finishCalled ?? now)
        return StreamingASRResult(
            text: text,
            totalLatency: total,
            postUtteranceLatency: postUtterance
        )
    }

    /// Abort the session without waiting for a result. Used when
    /// the user cancels mid-utterance.
    func cancel() {
        output?.close()
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        task = nil
        delegate = nil
        output = nil
    }
}

// MARK: - URLSession delegate

/// Bridges URLSessionDataDelegate callbacks (which fire on the
/// session's delegate queue, not MainActor) to a Swift continuation
/// the session can `await`. Parses incoming bytes as SSE — see
/// the file-level docstring for the wire format.
private final class StreamingASRDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Body bytes arrive incrementally; we accumulate into
    /// `responseBuffer` and parse complete `data: ...\n\n` events
    /// from the front. Anything trailing without a delimiter stays
    /// for the next chunk.
    private var responseBuffer = Data()
    private var statusCode = 0
    /// Latest "partial" text. Carries through to the final result
    /// on stream-end if no explicit "final" event lands first.
    private var lastPartial: String = ""
    private var finalText: String?
    private var continuation: CheckedContinuation<String, Error>?
    private var alreadyResumed = false
    private let lock = NSLock()
    /// Diagnostics — see StreamingASRSession.
    private var partialCount = 0
    private var lastPartialAt: Date?
    private var firstPartialAt: Date?

    var onPartial: (@Sendable (String) -> Void)?

    /// Snapshot of the diagnostic counters as a one-line string for
    /// the finish-time log.
    func diagnosticsString() -> String {
        let now = Date()
        let last = lastPartialAt.map { Int(now.timeIntervalSince($0) * 1000) }
        let first = firstPartialAt.map { Int(now.timeIntervalSince($0) * 1000) }
        return "partials=\(partialCount), firstPartialMsAgo=\(first.map(String.init) ?? "-"), lastPartialMsAgo=\(last.map(String.init) ?? "-")"
    }

    /// Async-await entry point. Call once after start() to receive
    /// the final transcript when the response completes.
    func awaitFinalText() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if alreadyResumed {
                lock.unlock()
                return
            }
            self.continuation = cont
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            statusCode = http.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        responseBuffer.append(data)
        // Parse out as many complete SSE events as we have. Each
        // event ends with `\n\n` — the SSE delimiter. Anything left
        // over after the last `\n\n` stays in the buffer.
        let delimiter = Data("\n\n".utf8)
        while let range = responseBuffer.range(of: delimiter) {
            let event = responseBuffer[..<range.lowerBound]
            responseBuffer.removeSubrange(..<range.upperBound)
            handleEventBytes(event)
        }
    }

    private func handleEventBytes(_ bytes: Data) {
        guard let raw = String(data: bytes, encoding: .utf8) else { return }
        // Each event might have multiple lines; we care about
        // `data:` lines. (SSE supports `event:`/`id:`/`retry:` too;
        // sidecar doesn't use them.)
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst("data: ".count)
            guard let payloadData = payload.data(using: .utf8) else { continue }
            struct Event: Decodable { let kind: String; let text: String }
            guard let event = try? JSONDecoder().decode(Event.self, from: payloadData) else { continue }
            switch event.kind {
            case "partial":
                lastPartial = event.text
                partialCount += 1
                let now = Date()
                if firstPartialAt == nil { firstPartialAt = now }
                lastPartialAt = now
                onPartial?(event.text)
            case "final":
                finalText = event.text
                logStreamingASR("final received (\(event.text.count) chars)")
            case "error":
                // Surface as a thrown error from awaitFinalText.
                resume(.failure(StreamingASRError.malformedResponse(event.text)))
            default:
                continue
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            resume(.failure(StreamingASRError.sessionFailed(error)))
            return
        }
        if !(200..<300).contains(statusCode) {
            let snippet = String(data: responseBuffer, encoding: .utf8) ?? "<\(responseBuffer.count) bytes>"
            resume(.failure(StreamingASRError.badStatus(statusCode, String(snippet.prefix(400)))))
            return
        }
        // Prefer the explicit final-event text; fall back to the
        // last partial if the sidecar closed without a final
        // (shouldn't happen, but defensive).
        let text = finalText ?? lastPartial
        resume(.success(text))
    }

    /// Resolve the awaiting continuation once-and-only-once. After
    /// the first resume, subsequent calls are no-ops — useful when
    /// a stream-error event arrives via SSE *and* the session
    /// completes with nil error a moment later.
    private func resume(_ result: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if alreadyResumed { return }
        alreadyResumed = true
        let cont = self.continuation
        self.continuation = nil
        cont?.resume(with: result)
    }
}
