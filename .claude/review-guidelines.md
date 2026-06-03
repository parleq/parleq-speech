# Parleq — code review guidelines

Repo-specific priorities and false-positive suppressions for `commit-review`. Supplements the default review criteria.

## Review priorities

- **Swift 6 strict-concurrency correctness** — data races, actor isolation violations, missing `Sendable`, unsafe cross-actor access. This is the #1 bug class here.
- **Secret handling** — provider secrets (Gemini key, Bedrock key/static creds, Vertex SA JSON, Azure key) must go through `KeychainStore`; never logged, never displayed in plaintext after save.
- **Provider auth correctness** — Bedrock SigV4 / bearer path, Vertex JWT (RS256) token minting, Azure family routing (`max_tokens` vs `max_completion_tokens` by deployment family). Mismatches here silently break a provider.
- **Compliance invariants** (see "NOT to flag" — these are *enforced*, so flag any change that *violates* them): audio stays memory-only; transcript content never reaches logs/stderr.

## Things NOT to flag (intentional — flagging these is noise)

- **Memory-only audio.** `AudioRecorder.stop()` returns `Data`; there is deliberately no URL/file path. Do **not** suggest writing audio to `/tmp`, buffering WAV to disk, or any audio-on-disk persistence — it's a load-bearing compliance promise. (Flag the opposite: any new code that *does* write audio to disk.)
- **`thinkingConfig.thinkingBudget = 0`** on Gemini calls and **`reasoning_effort: "low"`** on Bedrock `gpt-oss` calls — intentional latency/cost controls, not bugs.
- **Fresh stateless LLM call per refinement turn** (no server-side conversation history) — intentional.
- **`asr.endpoint` default `http://127.0.0.1:8767/inference`** — a magic sentinel kept verbatim for config back-compat; matching it triggers the in-process `LocalASR` path. Not dead config, not a real URL to "fix."
- **Localhost / HTTP endpoints** (the optional user ASR endpoint, in-process ASR) — local by design.
- **Dependency version pinning** in `Package.swift` / committed `Package.resolved` — intentional supply-chain hygiene, not over-restriction.
- **`setContentSize(...)` before `center()`** in window code — intentional ordering to fix a SwiftUI centering bug.
- **Length-only ASR diagnostics** (`(N chars / W words)`) and count-only `[vocab]` logs — intentional; full detail is opt-in via `PARLEQ_VOCAB_TRACE=1`.
