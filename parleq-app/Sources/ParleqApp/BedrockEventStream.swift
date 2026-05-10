// BedrockEventStream — minimal parser for the AWS event-stream
// binary format used by Bedrock's :converse-stream endpoint when
// authenticated via Bearer token (#22).
//
// The Soto-based SSO/static paths get this parsing for free
// because Soto unwraps the binary frames into typed Swift events.
// For the Bedrock-API-key path we bypass Soto entirely (Soto's
// signing model is SigV4-only and there's no extension point for
// bearer auth), which means we have to reassemble the wire format
// ourselves.
//
// What we implement:
//   - 12-byte prelude (total length, headers length, prelude CRC)
//   - Variable-length headers (we only need :event-type +
//     :message-type)
//   - JSON payload extraction
//   - Skip CRCs (validation is useful for production debugging
//     but failures here are extremely rare; a future iteration
//     can add it)
//
// What we don't implement:
//   - Header types other than string (the headers we care about
//     are all strings)
//   - Multi-message buffering optimizations beyond "read until
//     there's enough"
//   - Streaming-decode of payload (each message is small enough
//     to materialize before parsing)
//
// Reference:
//   https://docs.aws.amazon.com/transcribe/latest/dg/event-stream.html
//   (the Transcribe docs are the most thorough public description
//    of the format; Bedrock uses the same encoding.)

import Foundation

/// One decoded event from a Bedrock streaming response. Mirrors
/// the case shape of Soto's ConverseStreamOutput so the caller's
/// switch logic stays parallel between the SSO/static and Bearer
/// paths.
enum BedrockStreamEvent {
    /// `:event-type = contentBlockDelta` — a chunk of model text.
    case textDelta(String)
    /// `:event-type = metadata` — the final usage block. Tokens
    /// reported by the server.
    case metadata(inputTokens: Int, outputTokens: Int)
    /// Structural event we don't surface to the caller. The
    /// `name` is the `:event-type` header (messageStart, etc.) so
    /// debug logging can tell what was skipped.
    case other(name: String)
    /// `:message-type = exception` — server-side error event.
    /// Caller is expected to throw.
    case error(name: String, message: String)
}

/// Async byte-stream reader that yields one BedrockStreamEvent
/// per call until the underlying URLSession byte stream ends.
/// Owns a small re-grow buffer so it can read the variable-length
/// messages without trying to stream-decode each one.
final class BedrockEventStreamParser {
    private var buffer = Data()
    private var bytesIterator: URLSession.AsyncBytes.AsyncIterator
    private var done = false

    init(bytes: URLSession.AsyncBytes) {
        self.bytesIterator = bytes.makeAsyncIterator()
    }

    /// Pull the next decoded event, or nil if the stream ended.
    /// Throws on truncated frames or malformed payloads.
    func nextEvent() async throws -> BedrockStreamEvent? {
        // Make sure we have at least the 12-byte prelude.
        try await fill(toAtLeast: 12)
        if buffer.count < 12 {
            // Stream ended without enough bytes for another message.
            return nil
        }

        let totalLength = readUInt32(at: 0)
        let headersLength = readUInt32(at: 4)
        // 4 bytes prelude CRC at offset 8 — skipped.

        let totalLengthInt = Int(totalLength)
        let headersLengthInt = Int(headersLength)
        guard totalLengthInt >= 16, totalLengthInt < 64 * 1024 * 1024 else {
            throw NSError(domain: "BedrockEventStreamParser", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Implausible total_length=\(totalLength) (must be 16..64MB) — wire bytes are not AWS event-stream framing",
            ])
        }
        // Structural validation: prelude (12) + headers + trailing
        // message CRC (4) must equal totalLength. A malformed
        // headersLength here would let parseHeaders index past the
        // valid message bytes.
        guard headersLengthInt >= 0, headersLengthInt + 16 <= totalLengthInt else {
            throw NSError(domain: "BedrockEventStreamParser", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Implausible headers_length=\(headersLength) for total_length=\(totalLength) (must be ≤ total - 16)",
            ])
        }
        try await fill(toAtLeast: totalLengthInt)
        if buffer.count < totalLengthInt {
            // Stream truncated mid-message.
            throw NSError(domain: "BedrockEventStreamParser", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Stream ended mid-message (have \(buffer.count) bytes, expected \(totalLengthInt))",
            ])
        }

        let headersStart = 12
        let headersEnd = headersStart + headersLengthInt
        let headers = parseHeaders(start: headersStart, end: headersEnd)

        // Payload is between headers and the trailing 4-byte
        // message CRC. Use absolute startIndex offsets — `buffer`
        // is mutated below via removeFirst, and Data.subdata()
        // indexing semantics aren't always 0-based depending on
        // slice state, so we slice through subscript and copy.
        let payloadAbsStart = buffer.startIndex.advanced(by: headersEnd)
        let payloadAbsEnd = buffer.startIndex.advanced(by: totalLengthInt - 4)
        let payload = Data(buffer[payloadAbsStart..<payloadAbsEnd])

        // Drop the consumed bytes from the front of the buffer.
        buffer.removeFirst(totalLengthInt)

        return decodeEvent(headers: headers, payload: payload)
    }

    // MARK: - Internals

    /// Top-up the buffer until it has at least `n` bytes or the
    /// underlying stream ends. Reads in small chunks since
    /// URLSession.AsyncBytes yields one byte at a time.
    private func fill(toAtLeast n: Int) async throws {
        while !done && buffer.count < n {
            do {
                guard let byte = try await bytesIterator.next() else {
                    done = true
                    return
                }
                buffer.append(byte)
            } catch {
                throw error
            }
        }
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        let b0 = UInt32(byteAt(offset))
        let b1 = UInt32(byteAt(offset + 1))
        let b2 = UInt32(byteAt(offset + 2))
        let b3 = UInt32(byteAt(offset + 3))
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    /// Walk the headers blob and pull out the string-type headers.
    /// We don't need byte arrays / ints / timestamps for the
    /// events Bedrock emits, so type 7 (string) is the only one
    /// we decode in full. Unknown types skip the right number of
    /// bytes per the AWS event-stream type table.
    ///
    /// All buffer access here goes through the `byteAt` /
    /// `bytesAt` helpers which use absolute startIndex offsets —
    /// the buffer's `startIndex` shifts with `removeFirst()` calls
    /// in `nextEvent`, so raw integer indices into `buffer.subdata`
    /// would silently slide out of range and crash on the next
    /// message.
    private func parseHeaders(start: Int, end: Int) -> [String: String] {
        var headers: [String: String] = [:]
        var pos = start
        while pos < end {
            guard pos + 1 <= end else { break }
            let nameLen = Int(byteAt(pos))
            pos += 1
            guard pos + nameLen + 1 <= end else { break }
            let name = String(data: bytesAt(pos, count: nameLen), encoding: .utf8) ?? ""
            pos += nameLen
            let type = byteAt(pos)
            pos += 1
            switch type {
            case 0, 1:
                // Boolean: no value bytes.
                break
            case 2:
                pos += 1   // byte
            case 3:
                pos += 2   // short
            case 4:
                pos += 4   // int
            case 5:
                pos += 8   // long
            case 6:
                // Byte array: 2-byte length + bytes
                guard pos + 2 <= end else { return headers }
                let arrayLen = (Int(byteAt(pos)) << 8) | Int(byteAt(pos + 1))
                pos += 2 + arrayLen
            case 7:
                // String: 2-byte length + UTF-8
                guard pos + 2 <= end else { return headers }
                let strLen = (Int(byteAt(pos)) << 8) | Int(byteAt(pos + 1))
                pos += 2
                guard pos + strLen <= end else { return headers }
                let value = String(data: bytesAt(pos, count: strLen), encoding: .utf8) ?? ""
                headers[name] = value
                pos += strLen
            case 8:
                pos += 8   // timestamp
            case 9:
                pos += 16  // UUID
            default:
                // Unknown type — bail out of header parsing rather
                // than risk reading random bytes as another header.
                return headers
            }
        }
        return headers
    }

    /// Read the byte at logical offset `pos` (i.e., pos bytes after
    /// the buffer's current startIndex). `Data.startIndex` can shift
    /// after `removeFirst()` calls; this helper keeps the indexing
    /// consistent across that shift.
    private func byteAt(_ pos: Int) -> UInt8 {
        return buffer[buffer.startIndex.advanced(by: pos)]
    }

    /// Read `count` bytes starting at logical offset `pos` and
    /// return a fresh Data copy. Same startIndex-aware indexing as
    /// byteAt.
    private func bytesAt(_ pos: Int, count: Int) -> Data {
        let start = buffer.startIndex.advanced(by: pos)
        let end = buffer.startIndex.advanced(by: pos + count)
        return Data(buffer[start..<end])
    }

    /// Map a parsed (headers, payload) tuple to one of our
    /// BedrockStreamEvent cases. Bedrock's :converse-stream emits:
    ///   :message-type = "event"     + :event-type = contentBlockDelta / metadata / messageStart / etc.
    ///   :message-type = "exception" + :exception-type = ValidationException / etc.
    private func decodeEvent(headers: [String: String], payload: Data) -> BedrockStreamEvent {
        let messageType = headers[":message-type"] ?? "event"
        if messageType == "exception" {
            let name = headers[":exception-type"] ?? "Unknown"
            let message = (try? JSONSerialization.jsonObject(with: payload))
                .flatMap { $0 as? [String: Any] }
                .flatMap { $0["message"] as? String }
                ?? String(data: payload, encoding: .utf8)
                ?? ""
            return .error(name: name, message: message)
        }
        let eventType = headers[":event-type"] ?? ""
        switch eventType {
        case "contentBlockDelta":
            // Payload shape: {"contentBlockIndex": Int, "delta": {"text": String}}
            if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let delta = obj["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                return .textDelta(text)
            }
            return .other(name: eventType)
        case "metadata":
            // Payload shape: {"usage":{"inputTokens":..,"outputTokens":..,..},"metrics":...}
            if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let usage = obj["usage"] as? [String: Any] {
                let input = usage["inputTokens"] as? Int ?? 0
                let output = usage["outputTokens"] as? Int ?? 0
                return .metadata(inputTokens: input, outputTokens: output)
            }
            return .other(name: eventType)
        default:
            return .other(name: eventType)
        }
    }
}
