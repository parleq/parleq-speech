# parleq-app

The Parleq macOS app. Swift 6 + SwiftPM, macOS 14+.

This package is the user-facing app: hotkey listener, audio capture, overlay UI, paste, settings, LLM cleanup, and supervision of the bundled FluidAudio sidecar.

For end-user provider setup (Gemini, Vertex AI, Bedrock, Azure OpenAI), see [parleq.app/docs](https://parleq.app/docs/). AWS-specific operational notes are in [`docs/SETUP.md`](../docs/SETUP.md). For the architecture walkthrough, see [parleq.app/how-it-works](https://parleq.app/how-it-works/). For a security review packet, see [`docs/SECURITY_REVIEW.md`](../docs/SECURITY_REVIEW.md).

## Build from this directory

```bash
swift build              # debug build at .build/debug/ParleqApp
swift run ParleqApp      # build + run (TCC prompts attribute to the terminal)
```

For a real `.app` bundle (signed, with the bundled sidecar embedded, installable to `/Applications`), use the top-level Makefile:

```bash
cd ..
make install             # release build → /Applications/Parleq.app
make build               # release build → parleq-app/build/Parleq.app (no install)
make build-debug         # debug build (faster compile, larger binary)
make notarize            # build + Apple notarize + staple (requires keychain profile)
```

## Source layout

| File | What it does |
|---|---|
| `ParleqApp.swift` | `@main` entry. Wires recorder, ASR client, LLM provider, overlay, hotkey, supervisor. |
| `AppState.swift` | `@MainActor` coordinator. Owns the per-utterance state machine; everything else hangs off it. |
| `HotkeyListener.swift` | CGEventTap-based press-and-hold detector. Distinguishes left/right modifier keys via the device-dependent flag bit. |
| `AudioRecorder.swift` | AVAudioEngine input → 16 kHz mono int16 → in-memory WAV `Data`. Audio never touches disk. |
| `ASRClient.swift` | POSTs the WAV bytes to the sidecar's `/inference` endpoint, optionally with an `X-Parleq-Vocabulary` header for custom dictionary biasing. |
| `LLMProvider.swift` | Provider-agnostic streaming interface. `LLMMessage`, `LLMStreamEvent`, `LLMStreamSummary`, the `LLMProvider` protocol. |
| `LLMClient.swift` + `LLMStreaming.swift` | Google Gemini direct-API implementation (streaming SSE). API key sent via the `x-goog-api-key` header (not URL query parameter) so the secret never lives in any URL string. |
| `BedrockProvider.swift` | AWS Bedrock implementation via Soto's `ConverseStream`. Two auth modes: SSO via AWS CLI session cache, and static IAM credentials from the Keychain. |
| `BedrockBearerProvider.swift` + `BedrockEventStream.swift` | Scoped Bedrock-API-key auth path. Plain HTTPS with `Authorization: Bearer <key>`, in-tree event-stream parser — bypasses Soto entirely. |
| `VertexProvider.swift` + `VertexServiceAccount.swift` | Google Vertex AI implementation. Two auth modes: gcloud ADC (shells out for tokens) and service-account JSON (mints OAuth tokens via JWT-bearer / RS256 signing). |
| `AzureOpenAIProvider.swift` | Azure OpenAI implementation. Two auth modes (resource API key, Microsoft Entra ID via `az login`). Two model families (Standard, Reasoning) since Azure routes by deployment name. |
| `SystemPrompts.swift` | The cleanup and refine prompts. The cleanup prompt grows a smart-vocabulary addendum when the user's dictionary is non-empty. |
| `OverlayWindow.swift` | Borderless `NSPanel` + SwiftUI content. Captures Enter/Esc without stealing app focus. |
| `Paster.swift` | Captures frontmost app, sets pasteboard, simulates Cmd-V, restores previous pasteboard contents. |
| `SidecarSupervisor.swift` | Forks + supervises the bundled FluidAudio sidecar. Watches for crashes, restarts, runs the warmup probe. Generates a per-launch bearer token shared with the sidecar via `PARLEQ_SIDECAR_TOKEN`. |
| `SettingsWindow.swift` | NSWindow + SwiftUI Form. Provider picker, dictionary editor, Gemini API key (Keychain-backed) row, restart banner with one-click relaunch. |
| `MenuBar.swift` | Status-item menu (capture toggle, settings, login item, **Recent Dictations** submenu, quit). |
| `Config.swift` | `~/.parleq/config.json` loader/saver. |
| `UsageLedger.swift` + `PricingCache.swift` | Append-only JSONL at `~/.parleq/usage.jsonl` (**metadata only** — no transcript content) plus a LiteLLM live-pricing fetcher cached at `~/.parleq/pricing-cache.json`. |
| `KeychainStore.swift` | Wraps SecItem APIs for the Gemini API key. Service `com.parleq.app`, account `gemini-api-key`, accessibility `kSecAttrAccessibleAfterFirstUnlock`. Settings UI is the canonical writer; never displayed in plaintext after save. |
| `LogFile.swift` | At launch, `dup2`s stderr to `~/.parleq/app.log` (10 MB cap, truncates on launch when over). Skipped when stderr is a TTY so `swift run` from a terminal still shows live output. |
| `TranscriptHistory.swift` | In-memory ring buffer (cap 20) of recent cleaned transcripts. **Process memory only — never written to disk.** Surfaced via the menu bar's Recent Dictations submenu. |

## Per-utterance pipeline

1. **Right-Option down** → `HotkeyListener.onKeyDown` → `AppState.hotkeyDown`:
   - capture frontmost app via `Paster.captureFrontmost`
   - `AudioRecorder.start`
   - overlay → `capturing` state
   - "Tink" cue
2. **Right-Option up** → `HotkeyListener.onKeyUp` → `AppState.hotkeyUp`:
   - `AudioRecorder.stop()` returns `Capture(wavData:durationSeconds:)`
   - overlay → `cleaning` state, "Pop" cue
   - background task:
     - `ASRClient.transcribe(wav: data, vocabulary: ...)` → raw text
     - `LLMProvider.generateStreaming(...)` → text chunks → `overlay.appendText`
   - overlay → `awaitingAccept`, auto-accept timer (if configured)
3. **Enter** (or timer) → `AppState.accept`:
   - snapshot pasteboard, set to cleaned text, activate target, simulate Cmd-V, restore.

Refinement: re-press of right Option while the overlay is open cancels the in-flight stream, re-enters `capturing`, and on release uses the refine prompt with `{current overlay text + new instruction}`.

## Operational invariants

Non-obvious things that are easy to forget. Documented here so they survive future refactors:

1. **`thinkingConfig.thinkingBudget = 0`** on every Gemini call. Default-on thinking costs 2-3× latency, 5-7× cost, no quality gain on cleanup.
2. **`additionalModelRequestFields = {"reasoning_effort": "low"}`** on every Bedrock `openai.gpt-oss-*` call. Drops the 220-token hidden reasoning channel to ~30 tokens, 2.5× faster TTFT.
3. **Fresh stateless LLM call per refinement turn.** No server-side conversation history.
4. **Audio is memory-only end-to-end.** `AudioRecorder.stop()` returns a `Data`; no `/tmp/parleq-*.wav`, no audio cache. Required for compliance with enterprise policies on Bedrock-using apps.
5. **Logs carry length-only diagnostics.** ASR diagnostic shows `(N chars / W words)`, never the transcript text. Sidecar `[vocab]` log defaults to count-only; per-replacement detail is opt-in via `PARLEQ_VOCAB_TRACE=1`.
6. **Audio never leaves the device** — ASR is the local FluidAudio sidecar only. Cleanup payloads (the transcript text) go to the configured LLM provider; that's the only network boundary input data crosses.

## Quick verification

```bash
# Sidecar reachable?
curl -s http://127.0.0.1:8767/health

# App builds?
swift build

# Settings file written?
cat ~/.parleq/config.json | jq

# Recent LLM calls (token counts only, no content)?
tail -5 ~/.parleq/usage.jsonl | jq
```

For Bedrock auth debugging or other runtime issues, see [`docs/SETUP.md` § Troubleshooting](../docs/SETUP.md#troubleshooting).
