// ASRClient — posts a WAV file to the FluidAudio sidecar's batch
// /inference endpoint and returns the transcript.
//
// The sidecar's /inference handler scans the request body for the
// RIFF magic and extracts the WAV bytes from anywhere inside the
// body, so we don't need to wrap the WAV in multipart/form-data the
// way the Go benchmark runner does — we just POST the raw WAV bytes
// with `Content-Type: audio/wav`. Same effective contract; less
// boilerplate on this side.
//
// M1 uses /inference (batch Parakeet TDT v3). M4 will swap this
// client for a streaming one that posts chunked PCM to /stream-nemo.

import Foundation

enum ASRError: Error, CustomStringConvertible {
    case badStatus(Int, String)
    case malformedResponse
    case ioError(Error)

    var description: String {
        switch self {
        case .badStatus(let code, let body):
            return "ASR HTTP \(code): \(body)"
        case .malformedResponse:
            return "ASR response not JSON-shaped {\"text\": \"...\"}"
        case .ioError(let underlying):
            return "ASR IO: \(underlying)"
        }
    }
}

struct ASRResult {
    let text: String
    let latency: TimeInterval
}

/// One canonical vocabulary term plus its alias spellings, as sent
/// over the wire to the sidecar's CTC rescorer. The sidecar builds a
/// `CustomVocabularyTerm` from this — when the rescorer matches an
/// alias it emits the canonical `term` text, so callers always see
/// the user's preferred spelling regardless of which form the audio
/// matched. Aliases may be empty.
struct VocabularyEntry: Sendable, Equatable, Codable {
    let term: String
    let aliases: [String]

    init(term: String, aliases: [String] = []) {
        self.term = term
        self.aliases = aliases
    }
}

// ASRClient is Sendable: after init it holds only a stateless URL
// and URLSession, both of which are Sendable themselves. Mark it so
// the keyup callback can safely hand it across to a fire-and-forget
// Task without Swift 6's strict-concurrency analysis flagging it.
final class ASRClient: Sendable {
    static let defaultEndpoint = URL(string: "http://127.0.0.1:8767/inference")!

    private let endpoint: URL
    private let session: URLSession
    /// Bearer token shared with the supervised bundled sidecar.
    /// When non-nil, every request carries `Authorization: Bearer
    /// <token>`. Set to nil for external sidecars (custom
    /// `asr.endpoint` configurations) — we have no shared secret
    /// with a user-managed external server, so we send no auth and
    /// let the user manage their own server's access controls.
    private let bearerToken: String?

    init(endpoint: URL = ASRClient.defaultEndpoint, bearerToken: String? = nil) {
        self.endpoint = endpoint
        // Single-task tool — default URLSession is fine; explicit
        // configuration left for if we ever need keepalive / proxy
        // tuning.
        self.session = URLSession.shared
        self.bearerToken = bearerToken
    }

    /// POST the in-memory WAV bytes to the sidecar and return the
    /// transcript along with the round-trip latency. Throws on HTTP
    /// errors or malformed responses.
    ///
    /// `vocabulary` carries the user's custom-dictionary entries —
    /// each one is a canonical spelling plus an optional list of
    /// alternate spellings the ASR commonly produces. When non-
    /// empty, the sidecar runs an extra CTC keyword-spotting +
    /// rescoring pass over the TDT transcript; matches against the
    /// canonical OR any alias produce the canonical form in the
    /// output. Context blurbs and per-term biasing live in the LLM
    /// cleanup path and aren't passed here. Empty array skips the
    /// CTC pass entirely.
    func transcribe(
        wav data: Data,
        vocabulary: [VocabularyEntry] = []
    ) async throws -> ASRResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        if let header = ASRClient.encodeVocabularyHeader(vocabulary) {
            request.setValue(header, forHTTPHeaderField: "X-Parleq-Vocabulary")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        // Generous timeout — first call after sidecar warmup can be
        // slow if the model isn't yet hot. Subsequent calls are well
        // under a second.
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
        return ASRResult(text: parsed.text, latency: elapsed)
    }

    /// Encode the vocabulary list for the X-Parleq-Vocabulary header.
    /// Each entry serializes as `{"term": "...", "aliases": [...]}`,
    /// the array is JSON-encoded, then base64-encoded so the result
    /// is ASCII-safe in HTTP headers regardless of what characters
    /// the user has in their dictionary. Returns nil when the list is
    /// empty after trimming.
    static func encodeVocabularyHeader(_ entries: [VocabularyEntry]) -> String? {
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
