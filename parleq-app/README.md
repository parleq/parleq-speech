# parleq-app

The Parleq macOS app. Swift 6 + SwiftPM, macOS 14+.

This package is the user-facing app: hotkey listener, audio capture, overlay UI, paste, settings, LLM cleanup, and in-process FluidAudio speech recognition (Parakeet TDT v3 on the Apple Neural Engine).

For end-user provider setup (Gemini, Vertex AI, Bedrock, Azure OpenAI), see [parleq.app/docs](https://parleq.app/docs/). AWS-specific operational notes are in [`docs/SETUP.md`](../docs/SETUP.md). For the architecture walkthrough, see [parleq.app/how-it-works](https://parleq.app/how-it-works/). For a security review packet, see [`docs/SECURITY_REVIEW.md`](../docs/SECURITY_REVIEW.md).

## Build from this directory

```bash
swift build              # debug build at .build/debug/ParleqApp
swift run ParleqApp      # build + run (TCC prompts attribute to the terminal)
```

For a real `.app` bundle (signed, single binary, installable to `/Applications`), use the top-level Makefile:

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
| `ParleqApp.swift` | `@main` entry. Wires recorder, ASR client, LLM provider, overlay, hotkey, in-process speech engine. |
| `AppState.swift` | `@MainActor` coordinator. Owns the per-utterance state machine; everything else hangs off it. |
| `HotkeyListener.swift` | CGEventTap-based press-and-hold detector. Distinguishes left/right modifier keys via the device-dependent flag bit. |
| `AudioRecorder.swift` | AVAudioEngine input → 16 kHz mono int16 → in-memory WAV `Data`. Audio never touches disk. |
| `LocalASR.swift` | In-process FluidAudio Parakeet TDT v3 + CTC vocab rescoring. No listening sockets, no separate process. Replaced the bundled HTTP sidecar in v0.9.0. |
| `ASRClient.swift` | Routes batch ASR requests. Bundled path calls `LocalASR` in-process; HTTP path (used only when the user has configured a custom `asr.endpoint`) POSTs WAV bytes with an optional `X-Parleq-Vocabulary` header. |
| `LLMProvider.swift` | Provider-agnostic streaming interface. `LLMMessage`, `LLMStreamEvent`, `LLMStreamSummary`, the `LLMProvider` protocol. |
| `LLMClient.swift` + `LLMStreaming.swift` | Google Gemini direct-API implementation (streaming SSE). API key sent via the `x-goog-api-key` header (not URL query parameter) so the secret never lives in any URL string. |
| `BedrockProvider.swift` | AWS Bedrock implementation via Soto's `ConverseStream`. Auth modes: SSO via AWS CLI session cache, static IAM credentials from the Keychain, and `oidc` (federated STS credentials minted from a corporate OIDC sign-in via `CachedExchange`). |
| `BedrockBearerProvider.swift` + `BedrockEventStream.swift` | Scoped Bedrock-API-key auth path. Plain HTTPS with `Authorization: Bearer <key>`, in-tree event-stream parser — bypasses Soto entirely. |
| `VertexProvider.swift` + `VertexServiceAccount.swift` | Google Vertex AI implementation. Auth modes: gcloud ADC (shells out for tokens), service-account JSON (mints OAuth tokens via JWT-bearer / RS256 signing), and `oidcFederation` (Workforce Identity federated bearer from `CachedExchange`, with `x-goog-user-project`). |
| `AzureOpenAIProvider.swift` | Azure OpenAI implementation. Two auth modes (resource API key, Microsoft Entra ID via `az login`). Two model families (Standard, Reasoning) since Azure routes by deployment name. |
| `OIDCSession.swift` | Cloud-ignorant OIDC actor for enterprise federation: discovery, PKCE sign-in (`ASWebAuthenticationSession`), rotation-safe single-flight refresh (rotated refresh token persisted to the Keychain on receipt), published state machine. `OIDCSessionModel` is the MainActor/SwiftUI facade. ID and access tokens stay in process memory; only the refresh token + identity snapshot persist (Keychain). |
| `CloudCredentialExchangers.swift` | Turns an OIDC ID token into per-cloud credentials behind a single-flight TTL cache (`CachedExchange`, 5-min refresh-ahead, hotkey-down `warm()`). `AWSWebIdentityExchanger` (Soto STS `AssumeRoleWithWebIdentity` → temporary credentials; signed-in email as the role session name for CloudTrail) and `GCPWorkforceExchanger` (Workforce Identity Federation token exchange → federated bearer). Per-hop status feeds the connection doctor; logging is state name + code only. |
| `CompanyAccountView.swift` | "Company Account" Settings section: corporate sign-in, signed-in identity (name/email render in the UI only — never logged), and a connection doctor (token-free discovery → silent refresh → per-leg AWS/GCP exchange status). Federation fails closed to the raw on-device ASR transcript when unavailable. |
| `SystemPrompts.swift` | The cleanup and refine prompts. The cleanup prompt grows a smart-vocabulary addendum when the user's dictionary is non-empty. |
| `OverlayWindow.swift` | Borderless `NSPanel` + SwiftUI content. Captures Enter/Esc without stealing app focus. When enterprise federation fails closed, the "signed out" failure row is clickable — it runs the shared interactive OIDC sign-in and then offers an opt-in ↻ re-clean of the retained raw transcript (wired via `onReauthSignIn` / `onReauthReclean` to AppState). |
| `Paster.swift` | Captures frontmost app, sets pasteboard, simulates Cmd-V, restores previous pasteboard contents. |
| `SettingsWindow.swift` | NSWindow + SwiftUI Form. Provider picker, dictionary editor, Gemini API key (Keychain-backed) row, restart banner with one-click relaunch. |
| `MenuBar.swift` | Status-item menu (capture toggle, settings, login item, **Recent Dictations** submenu, quit). |
| `Config.swift` | `~/.parleq/config.json` loader/saver. |
| `UsageLedger.swift` + `PricingCache.swift` | Append-only JSONL at `~/.parleq/usage.jsonl` (**metadata only** — no transcript content) plus a LiteLLM live-pricing fetcher cached at `~/.parleq/pricing-cache.json`. |
| `KeychainStore.swift` | Wraps SecItem APIs for every provider secret plus the enterprise-OIDC refresh token + identity snapshot (accounts `oidc-refresh-token`, `oidc-identity`). Service `com.parleq.app`, accessibility `kSecAttrAccessibleAfterFirstUnlock`. Settings UI is the canonical writer; secrets are never displayed in plaintext after save. |
| `LogFile.swift` | At launch, `dup2`s stderr to `~/.parleq/app.log` (10 MB cap, truncates on launch when over). Skipped when stderr is a TTY so `swift run` from a terminal still shows live output. |
| `TranscriptHistory.swift` | Unlimited by default (bounded via the managed/config caps; `0` disables) in-memory list of recent cleaned transcripts. **Process memory only — never written to disk.** Surfaced in the Parleq window's Recent Dictations section (the menu-bar submenu was removed in 0.14.0). Wiped on quit. |
| `SpellOutDetector.swift` | Detects spelled-out word candidates (e.g. "A-P-I") in the raw ASR transcript; assembles the term and feeds it as a correction signal when "learn from corrections" is enabled. |
| `CorrectionJournal.swift` | Opt-in, bounded **in-memory-only** ring buffer. Records voice-refine events (instruction + the edit's before/after text) and spell-out candidates (assembled term + the cleaned text it appeared in) — correction *events* only, not a log of every dictation (a refine record does hold that edit's full before/after text). Count + age caps; off by default; **never written to disk**; wiped on quit. |
| `LearningAnalyzer.swift` | Periodic off-hot-path actor. Reads the in-memory correction ring, calls the configured cleanup LLM to propose dictionary changes, auto-applies high-confidence non-colliding term additions (via `LearnedStore`), and surfaces the rest as pending suggestions. |
| `LearnedStore.swift` | Apply / suggest / revert surface for learned dictionary changes. High-confidence proposals auto-apply into the custom dictionary tagged `source=learned`; others become pending suggestions. **In-memory only** — pending suggestions and the applied-changes log are process memory, wiped on quit; the only durable output is the learned terms in `config.json`. |
| `LearnedView.swift` | SwiftUI "Learned" sidebar section in Settings. Shows pending suggestions (Accept / Dismiss), the applied-changes log (Revert), and the feature on/off toggle. Disabling offers to clear the in-memory correction data immediately (cleared on quit regardless). |
| `PresetsSettingsView.swift` | "Presets" Settings pane: transform-preset list editor (name + prompt) + per-app default mapping. A preset is a canned refine instruction; an app default folds into that app's cleanup prompt (one LLM call) with a "Styled with X · Undo" chip in the overlay. |

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
     - `ASRClient.transcribe(wav: data, vocabulary: ...)` → raw text (routes through in-process `LocalASR` by default, or to a custom external `asr.endpoint` if configured)
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
5. **Logs carry length-only diagnostics.** ASR diagnostic shows `(N chars / W words)`, never the transcript text. `LocalASR`'s `[vocab]` log defaults to count-only; per-replacement detail is opt-in via `PARLEQ_VOCAB_TRACE=1`.
6. **Audio never leaves the device** — ASR is in-process FluidAudio by default; no listening sockets, no IPC. Cleanup payloads (the transcript text) go to the configured LLM provider; that's the only network boundary input data crosses. Users who configure a custom `asr.endpoint` opt into a localhost HTTP path to their own server.

## Quick verification

```bash
# App builds?
swift build

# Speech engine loaded? (Look for "ASR" / "LocalASR" lines.)
grep -E "LocalASR|ASR" ~/.parleq/app.log | tail -10

# No listening sockets on a running Parleq? (Should print "no LISTEN".
# The -a flag is required — without it, lsof ORs -i and -p instead
# of ANDing, dumping every listening socket on the machine.)
lsof -i -nP -a -p "$(pgrep -n ParleqApp)" | grep LISTEN || echo "no LISTEN"

# Settings file written?
cat ~/.parleq/config.json | jq

# Recent LLM calls (token counts only, no content)?
tail -5 ~/.parleq/usage.jsonl | jq
```

For Bedrock auth debugging or other runtime issues, see [`docs/SETUP.md` § Troubleshooting](../docs/SETUP.md#troubleshooting).
