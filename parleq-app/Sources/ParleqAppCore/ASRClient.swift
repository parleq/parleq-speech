// ASRClient — runs batch ASR on a WAV buffer.
//
// Two code paths share the same caller-facing API. Which one is
// active depends on whether ParleqApp.main constructed the client
// with an in-process `LocalASR` reference:
//
//   - **Bundled (in-process FluidAudio).** Default. `LocalASR`
//     decodes the WAV in-process, runs Parakeet TDT v3 on the Apple
//     Neural Engine, and (when the user's dictionary is non-empty)
//     runs an extra CTC rescoring pass. No network, no listening
//     socket. The retired FluidAudio HTTP sidecar lived here.
//   - **HTTP (custom asr.endpoint).** When the user has pointed
//     `asr.endpoint` at their own OpenAI-compatible `/inference`
//     server (e.g. Sherpa-ONNX, faster-whisper), `LocalASR` is nil
//     and we POST WAV bytes to the configured URL exactly the same
//     way the sidecar shipped. This is the only path that crosses a
//     network boundary, and only when the user has explicitly opted
//     out of the bundled ASR.
//
// `transcribe(wav:vocabulary:)` returns an `ASRTranscript` either way,
// so AppState doesn't need to know which path is active.

import Foundation

public enum ASRError: Error, CustomStringConvertible {
    case badStatus(Int, String)
    case malformedResponse
    /// The WAV buffer handed to `LocalASR.transcribe(wav:vocabulary:)`
    /// wasn't a valid RIFF/WAVE file (missing magic, truncated chunk,
    /// header sample count not satisfying the bytes-per-sample math).
    /// Distinct from `malformedResponse` (which describes a malformed
    /// HTTP response from an external `asr.endpoint`) so log lines
    /// point at the right side of the wire.
    case malformedAudio
    case ioError(Error)
    /// `LocalASR` was asked to transcribe before its TDT model had
    /// finished loading. Hotkey-driven dictation gates on
    /// `AppState.isSystemReady`, so this should never surface in
    /// real flow — it's here for completeness and to make a
    /// developer mistake (calling transcribe before start()
    /// completes) loud.
    case notReady

    public var description: String {
        switch self {
        case .badStatus(let code, let body):
            return "ASR HTTP \(code): \(body)"
        case .malformedResponse:
            return "ASR response not JSON-shaped {\"text\": \"...\"}"
        case .malformedAudio:
            return "ASR input not a valid 16 kHz mono 16-bit WAV buffer"
        case .ioError(let underlying):
            return "ASR IO: \(underlying)"
        case .notReady:
            return "ASR not ready (model still loading)"
        }
    }
}

public struct ASRTranscript {
    public let text: String
    public let latency: TimeInterval
}

/// One canonical vocabulary term plus its alias spellings, as sent
/// over the wire to the sidecar's CTC rescorer. The sidecar builds a
/// `CustomVocabularyTerm` from this — when the rescorer matches an
/// alias it emits the canonical `term` text, so callers always see
/// the user's preferred spelling regardless of which form the audio
/// matched. Aliases may be empty.
public struct VocabularyEntry: Sendable, Equatable, Codable {
    public let term: String
    public let aliases: [String]

    public init(term: String, aliases: [String] = []) {
        self.term = term
        self.aliases = aliases
    }
}

// ASRClient is Sendable: after init it holds only an immutable
// `URL`, a `URLSession` (Sendable), and an optional `LocalASR`
// reference. `LocalASR` is `@MainActor`-isolated, which makes it
// Sendable too — concurrent reads of the property are forced
// through MainActor and there's no shared mutable state to race
// on. The hotkey-up callback hands the client across to a fire-
// and-forget Task; structural Sendable conformance keeps the
// strict-concurrency analysis happy.
public final class ASRClient: Sendable {
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8767/inference")!

    private let endpoint: URL
    private let session: URLSession
    /// In-process FluidAudio engine. Non-nil iff the user's
    /// `asr.endpoint` matches `Config.bundledASREndpoint` (the
    /// default). When set, `transcribe(wav:vocabulary:)` calls into
    /// it directly and the HTTP path is dormant.
    private let local: LocalASR?

    public init(
        endpoint: URL = ASRClient.defaultEndpoint,
        local: LocalASR? = nil
    ) {
        self.endpoint = endpoint
        // Single-task tool — default URLSession is fine; explicit
        // configuration left for if we ever need keepalive / proxy
        // tuning.
        self.session = URLSession.shared
        self.local = local
    }

    /// Run batch ASR on a 16 kHz mono 16-bit WAV buffer.
    ///
    /// `vocabulary` carries the user's custom-dictionary entries —
    /// each one is a canonical spelling plus an optional list of
    /// alternate spellings the ASR commonly produces. When non-
    /// empty, an extra CTC keyword-spotting + rescoring pass runs
    /// over the TDT transcript; matches against the canonical OR
    /// any alias produce the canonical form in the output. Context
    /// blurbs and per-term biasing live in the LLM cleanup path and
    /// aren't passed here. Empty array skips the CTC pass.
    ///
    /// Routes through the bundled in-process `LocalASR` by default,
    /// or POSTs WAV bytes to a user-configured `asr.endpoint`. Both
    /// paths return the same `ASRTranscript` shape so callers don't
    /// need to know which is active.
    public func transcribe(
        wav data: Data,
        vocabulary: [VocabularyEntry] = []
    ) async throws -> ASRTranscript {
        if let local {
            let started = Date()
            let text = try await local.transcribe(
                wav: data,
                vocabulary: vocabulary
            )
            return ASRTranscript(text: text, latency: -started.timeIntervalSinceNow)
        }
        return try await transcribeHTTP(wav: data, vocabulary: vocabulary)
    }

    /// HTTP fallback for users with a custom `asr.endpoint`. Wire
    /// format matches what the retired FluidAudio sidecar accepted:
    /// raw WAV bytes with `Content-Type: audio/wav`, an optional
    /// `X-Parleq-Vocabulary` header carrying base64-encoded JSON.
    /// The endpoint owner (their Sherpa-ONNX or faster-whisper
    /// server) handles its own access control; we send no
    /// Authorization header — there's no shared secret to use.
    private func transcribeHTTP(
        wav data: Data,
        vocabulary: [VocabularyEntry]
    ) async throws -> ASRTranscript {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        if let header = ASRClient.encodeVocabularyHeader(vocabulary) {
            request.setValue(header, forHTTPHeaderField: "X-Parleq-Vocabulary")
        }
        // Generous timeout — a cold custom server may JIT-compile
        // CoreML graphs on first request, same as the retired
        // bundled sidecar did. Subsequent calls are well under a
        // second.
        request.timeoutInterval = 30

        let started = Date()
        let (respData, response) = try await session.data(for: request)
        let elapsed = -started.timeIntervalSinceNow

        guard let http = response as? HTTPURLResponse else {
            throw ASRError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: respData, encoding: .utf8) ?? "<\(respData.count) bytes>"
            throw ASRError.badStatus(http.statusCode, body)
        }
        struct Payload: Decodable { let text: String }
        let parsed: Payload
        do {
            parsed = try JSONDecoder().decode(Payload.self, from: respData)
        } catch {
            throw ASRError.malformedResponse
        }
        return ASRTranscript(text: parsed.text, latency: elapsed)
    }

    /// Encode the vocabulary list for the X-Parleq-Vocabulary header.
    /// Each entry serializes as `{"term": "...", "aliases": [...]}`,
    /// the array is JSON-encoded, then base64-encoded so the result
    /// is ASCII-safe in HTTP headers regardless of what characters
    /// the user has in their dictionary. Returns nil when the list is
    /// empty after trimming.
    public static func encodeVocabularyHeader(_ entries: [VocabularyEntry]) -> String? {
        let cleaned: [VocabularyEntry] = entries.compactMap { entry in
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            let aliases = entry.aliases
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return VocabularyEntry(term: term, aliases: aliases)
        }
        guard !cleaned.isEmpty else { return nil }
        guard let json = try? JSONEncoder().encode(cleaned) else { return nil }
        return json.base64EncodedString()
    }
}
