# Exploration: on-device LLM cleanup (Ollama prototype)

**Status: retired exploration.** Built 2026-05-29 on a side branch
(`ondevice-llm-cleanup`, never merged), evaluated, and parked when the
enterprise OIDC federation work (shipped in 0.20.0) took priority. The
branch has been deleted; this document preserves everything it produced
so the next attempt starts from the findings rather than from scratch.

## What was built

A prototype `OllamaProvider` implementing Parleq's `LLMProvider`
protocol against a locally running Ollama daemon
(`http://localhost:11434`, overridable via `OLLAMA_HOST`), wired into
the provider factory as `llm.provider = "ollama"` / `"local"` with the
Ollama tag (e.g. `qwen3:1.7b`) as the model. Cleanup ran fully
on-device: no credential, no per-token cost, no network boundary
crossed.

Three commits: the provider, the factory wiring, and a round of fixes
from dogfooding (output bound + decoding parameters, below).

## Findings worth keeping

- **`think: false` is essential on thinking-capable small models.**
  Suppressing Qwen3's thinking tokens measured ~6x fewer output tokens
  and ~5x lower latency on cleanup workloads. Any future runtime must
  have an equivalent switch.
- **Greedy decoding is unusable on Qwen3.** Temperature 0 produced
  endless repetitions, exactly as Qwen3's model card warns. The
  working configuration was `temperature 0.3, top_p 0.9,
  repeat_penalty 1.1`.
- **Always bound output length.** A degenerate generation can stream
  unbounded toward the context limit — the "endless, ever-slower"
  failure seen in dogfooding. `num_predict 1024` (mirroring the cloud
  providers' max-token caps) fixed it; the NDJSON read loop must also
  break on `done`.
- **Context window: `num_ctx 8192`** was sufficient for cleanup
  prompts and keeps memory predictable; cap it deliberately rather
  than inheriting model defaults.
- **Ollama's native `/api/chat` streams NDJSON** (one JSON object per
  line), not OpenAI-style SSE — a different parser than every other
  Parleq provider.
- **Model size:** the prototype targeted Qwen3-1.7B for speed of
  iteration; quality evaluation pointed at **Qwen3-4B (~3.6 GB)** as
  the smallest model with acceptable cleanup quality.

## Why parked, and the actual ship direction

The Ollama path requires users to install and run a separate daemon
with a pulled model — a heavy external dependency that conflicts with
Parleq's bundled, in-process posture (the same reason the ASR sidecar
was retired in 0.9.0). The prototype's purpose was model/parameter
evaluation, and it served it. The intended production direction is an
**in-process MLX runtime** (mlx-swift) hosting a small model, with the
findings above (thinking suppression, sampling parameters, output
bounds, capped context) carried over.

## Appendix A — factory wiring (for reference)

```swift
// Config.swift llmProvider doc addition:
///   - "ollama" / "local" — on-device cleanup via a locally running
///     Ollama daemon (no credential, no cost). `llmModel` is the
///     Ollama tag, e.g. "qwen3:1.7b". Prototype path.

// main.swift makeProvider addition:
case "ollama", "local":
    let ollama = OllamaProvider(model: id.model)
    logStderr("[parleq] LLM \(label) (ollama model=\(id.model) — local on-device via Ollama daemon)")
    return ollama
```

## Appendix B — full prototype source (`OllamaProvider.swift`, as retired)

```swift
// OllamaProvider — local on-device LLM cleanup via a running Ollama
// daemon (http://localhost:11434 by default; override with OLLAMA_HOST).
//
// This is a PROTOTYPE path for evaluating on-device cleanup with small
// models (e.g. Qwen3-1.7B) before committing to an in-process MLX
// runtime. It requires the user to have Ollama running with the model
// pulled. No credential, no cost: cleaned text is processed entirely on
// the local machine, so nothing crosses a network boundary.
//
// Streams Ollama's native /api/chat endpoint, which emits
// newline-delimited JSON (one object per line) rather than OpenAI-style
// SSE. `think:false` suppresses thinking tokens (~6x fewer output
// tokens, ~5x lower latency in our evaluation) on models that support it.

import Foundation

public final class OllamaProvider: LLMProvider, Sendable {
    public let model: String
    public let baseURL: String
    public let session: URLSession

    public var providerName: String { "ollama" }
    // Prototype targets text-only small models (Qwen3-1.7B). Ollama can
    // accept images for vision models via a separate `images` field, but
    // that's out of scope here.
    public var supportsVision: Bool { false }

    public init(model: String, baseURL: String? = nil) {
        self.model = model
        self.baseURL = baseURL
            ?? ProcessInfo.processInfo.environment["OLLAMA_HOST"]
            ?? "http://localhost:11434"
        self.session = URLSession.shared
    }

    public func generateStreaming(
        systemPrompt: String,
        messages: [LLMMessage],
        onEvent: @Sendable (LLMStreamEvent) -> Void
    ) async throws {
        let body = buildRequestBody(systemPrompt: systemPrompt, messages: messages)
        let urlString = baseURL.hasSuffix("/") ? baseURL + "api/chat" : baseURL + "/api/chat"
        guard let url = URL(string: urlString) else {
            throw LLMError.requestFailed(
                NSError(domain: "OllamaProvider", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not build URL: \(urlString)"]))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw LLMError.requestFailed(error)
        }

        let started = Date()
        var ttft: TimeInterval = 0
        var inputTokens = 0
        var outputTokens = 0

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedResponse("response is not HTTP")
        }
        if !(200..<300).contains(http.statusCode) {
            let cap = 4096
            var buf = Data()
            for try await line in bytes.lines {
                guard buf.count < cap else { break }
                if let lineData = (line + "\n").data(using: .utf8) {
                    buf.append(lineData.prefix(cap - buf.count))
                }
            }
            let snippet = String(data: buf, encoding: .utf8) ?? "<\(buf.count) bytes>"
            throw LLMError.badStatus(http.statusCode, String(snippet.prefix(400)))
        }

        // Ollama /api/chat streams newline-delimited JSON: one object per
        // line with `message.content` deltas, then a final object with
        // `done:true` carrying prompt_eval_count / eval_count token totals.
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            guard let parsed = try? JSONDecoder().decode(OllamaStreamPayload.self, from: data) else { continue }

            if let chunk = parsed.message?.content, !chunk.isEmpty {
                if ttft == 0 { ttft = -started.timeIntervalSinceNow }
                onEvent(.chunk(chunk))
            }
            if parsed.done == true {
                inputTokens = parsed.prompt_eval_count ?? inputTokens
                outputTokens = parsed.eval_count ?? outputTokens
                break
            }
        }

        onEvent(.done(LLMStreamSummary(
            totalLatency: -started.timeIntervalSinceNow,
            ttft: ttft,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )))
    }

    private func buildRequestBody(systemPrompt: String, messages: [LLMMessage]) -> [String: Any] {
        var convo: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
        ]
        for msg in messages {
            convo.append(buildOllamaMessage(msg))
        }
        return [
            "model": model,
            "messages": convo,
            "stream": true,
            "think": false,
            // Output-generation safety + quality knobs:
            //  - num_predict caps the visible output so a degenerate
            //    generation cannot stream unbounded toward num_ctx
            //    (the "endless, ever-slower" failure). Mirrors
            //    OpenAIProvider's max_tokens: 1024.
            //  - Qwen3 explicitly warns AGAINST greedy decoding
            //    (temperature 0): it "can lead to endless repetitions."
            //    Use a low non-zero temperature + a repeat penalty so
            //    cleanup stays faithful without the greedy repetition trap.
            "options": [
                "temperature": 0.3,
                "top_p": 0.9,
                "repeat_penalty": 1.1,
                "num_predict": 1024,
                "num_ctx": 8192,
            ],
        ]
    }

    /// Serialize a message to Ollama's chat shape. Text-only here:
    /// concatenate text parts; image parts are ignored (supportsVision
    /// is false, so the runtime won't route images to this provider).
    private func buildOllamaMessage(_ msg: LLMMessage) -> [String: Any] {
        let role = msg.role == "model" ? "assistant" : msg.role
        let text = msg.parts.compactMap {
            if case .text(let s) = $0 { return s } else { return nil }
        }.joined()
        return ["role": role, "content": text]
    }

    public func cleanupFailureHint(for error: LLMError) -> String? {
        switch error {
        case .requestFailed:
            return "Couldn't reach Ollama at \(baseURL). Start it (`ollama serve`) and confirm the model is pulled (`ollama pull \(model)`)."
        case .badStatus(404, _):
            return "Ollama returned 404 — model \"\(model)\" isn't pulled. Run `ollama pull \(model)`."
        default:
            return nil
        }
    }
}

// MARK: - Ollama /api/chat NDJSON payload

/// Each NDJSON line from /api/chat decodes to this. Streaming deltas
/// carry `message.content`; the terminal line has `done:true` plus the
/// token counts (`prompt_eval_count` = input, `eval_count` = output).
private struct OllamaStreamPayload: Decodable {
    let message: Message?
    let done: Bool?
    let prompt_eval_count: Int?
    let eval_count: Int?

    struct Message: Decodable {
        let content: String?
    }
}
```
