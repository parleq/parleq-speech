# Parleq codebase guide

Reference for human contributors and AI assistants working in this repo. Parleq is an open-source macOS dictation app: press a global hotkey, speak, see post-processed text in a floating overlay, accept to paste. ASR runs locally on the Apple Neural Engine (FluidAudio Parakeet TDT v3); LLM cleanup is provider-pluggable across Google Gemini, Google Vertex AI, AWS Bedrock, and Azure OpenAI.

The user-facing site is at [parleq.app](https://parleq.app).

## Tech stack

- **Swift 6** (strict concurrency), **SwiftPM**, **macOS 14+**.
- **Soto** for AWS Bedrock SigV4 (`SotoBedrockRuntime`); custom `BedrockBearerProvider` for the Bedrock-API-key path that bypasses Soto entirely.
- **Hummingbird** (HTTP server) for the bundled FluidAudio sidecar.
- **FluidAudio** for Parakeet TDT v3 + CTC vocabulary boosting on Apple Neural Engine.
- **AVFoundation** for audio capture, **CoreGraphics CGEventTap** for the hotkey listener, **AppKit + SwiftUI** for the overlay, Settings, and Setup Wizard.

## Build commands

```bash
make install         # release build → /Applications/Parleq.app
make build           # release build → parleq-app/build/Parleq.app (no install)
make build-debug     # debug build (faster compile)
make notarize        # build + Apple notarize + staple
make dmg             # notarize + sign + build DMG
make release         # dmg + named/hashed copy + RELEASE_NOTES.txt stub
make clean           # remove .build / build dirs

# From parleq-app/ directly:
swift build          # debug build at .build/debug/ParleqApp
swift run ParleqApp  # build + run (TCC prompts attribute to terminal)
```

There is no formal test target. Verification is `swift build` + `make install` + manual end-to-end dictation.

## Dependency upgrade policy

`parleq-app/Package.swift` pins each external dependency to a tight version range (e.g. `"7.14.0"..<"7.15.0"` for Soto), and `Package.resolved` is committed to the repo so fresh clones build against the exact versions we tested. This is intentional supply-chain hygiene: it eliminates "works on my machine" version drift and forces dependency bumps to be explicit, reviewable commits rather than silent picks at resolve time.

**Periodic-upgrade ritual** — every few weeks, or when an upstream ships a security fix or a feature you want, run an upgrade check:

```bash
cd parleq-app
swift package update --dry-run     # show what would change
swift package update               # apply (touches Package.resolved)
swift build                        # confirm it still compiles
swift package show-dependencies    # walk the full tree
```

When in doubt, leave it alone — Parleq dictation works today on the pinned versions. Drift only happens when someone touches the files. Worth checking after any update:

- **Soto** — AWS service shape changes, eventstream parsing fixes, credential-provider improvements.
- **FluidAudio** — Parakeet model versions, CTC vocab boosting tweaks, ANE performance.
- **Hummingbird** — HTTP server used by the sidecar.
- **swift-nio**, **swift-crypto**, **swift-certificates** — Apple-maintained, security-relevant.

## Repository layout

```
parleq-speech/
├── parleq-app/                          ← the macOS app (Swift / SwiftPM)
│   ├── Sources/ParleqApp/               ← all Swift sources
│   ├── Resources/                       ← Info.plist, entitlements
│   ├── scripts/make-app.sh              ← bundle build + sign
│   └── README.md                        ← per-module reference
├── third_party/
│   └── fluidaudio-sidecar/              ← bundled HTTP server (Swift)
├── docs/
│   ├── SETUP.md                         ← end-user AWS Bedrock setup walkthrough
│   └── SECURITY_REVIEW.md               ← data flows, trust boundaries, secrets
├── web/                                 ← marketing site (Astro), deployed to parleq.app
└── Makefile                             ← top-level build/install/notarize
```

## Module map (parleq-app)

| Module | Purpose |
|---|---|
| `ParleqApp.swift` | `@main` entry. Reads `Config`, instantiates the right `LLMProvider` based on `config.llmProvider`, wires `AppState`. Installs the standard `NSApp.mainMenu` so ⌘V/⌘X/⌘C/⌘A work in text fields. |
| `MainMenuInstaller.swift` | Builds App + Edit submenus for `NSApp.mainMenu`. Required because `LSUIElement` apps don't get a default main menu, and SwiftUI text fields need it for keyboard-shortcut routing. |
| `AppState.swift` | `@MainActor` coordinator, per-utterance state machine. Re-reads `Config.customDictionary` per utterance for live updates. |
| `HotkeyListener.swift` | CGEventTap. Distinguishes left/right modifier keys via device-dependent flag. |
| `AudioRecorder.swift` | AVAudioEngine → 16 kHz mono int16 → in-memory `Data`. **No filesystem writes.** Honors explicit microphone selection by Core Audio device UID; falls through to the system default + auto-route heuristic when none is set. |
| `ShellEnvironment.swift` | Builds an augmented PATH for spawned CLI tools (`/opt/homebrew/bin`, `/usr/local/bin`) so launchd-spawned Parleq can find user-installed `gcloud` / `az`. |
| `ASRClient.swift` | `POST /inference` to the sidecar with WAV bytes + `X-Parleq-Vocabulary` header. |
| `LLMProvider.swift` | Provider protocol + shared types (`LLMMessage`, `LLMStreamEvent`, `LLMStreamSummary`). |
| `LLMClient.swift` + `LLMStreaming.swift` | Google Gemini direct-API impl (SSE streaming). |
| `VertexProvider.swift` + `VertexServiceAccount.swift` | Google Vertex AI impl. Two auth modes: gcloud ADC (shells out for tokens) and service-account JSON (mints OAuth tokens via JWT-bearer / RS256). |
| `BedrockProvider.swift` | AWS Bedrock impl via Soto `ConverseStream`. SSO + static-credential auth modes. |
| `BedrockBearerProvider.swift` + `BedrockEventStream.swift` | Scoped Bedrock-API-key auth path. Plain HTTPS with `Authorization: Bearer <key>`, in-tree event-stream parser — bypasses Soto entirely. |
| `AzureOpenAIProvider.swift` | Azure OpenAI impl. Two auth modes (resource API key, Microsoft Entra ID via `az login`). Two model families (Standard, Reasoning) since Azure routes by deployment name. |
| `SystemPrompts.swift` | Cleanup + refine prompts. `cleanup(dictionary:)` returns the prompt with an optional smart-vocabulary addendum. |
| `OverlayWindow.swift` | Borderless `NSPanel` + SwiftUI. Captures Enter/Esc without stealing focus. |
| `Paster.swift` | Pasteboard snapshot → set → activate target → simulate Cmd-V → restore. |
| `SidecarSupervisor.swift` | Fork + supervise the bundled FluidAudio sidecar; warmup probe; PARLEQ_VOCAB_PRELOAD env when dictionary is non-empty. Passes its PID to the sidecar so the sidecar self-terminates on supervisor crash (kqueue NOTE_EXIT watch). |
| `SettingsWindow.swift` | SwiftUI two-pane Settings. Sidebar with sections (Hotkey, Audio, Behavior, Paste, Cleanup, Dictionary, Usage, Advanced); per-section content cards. Always-center window, brand amber accent. |
| `SetupWizard.swift` | First-run / re-runnable setup wizard. Step-pill progress indicator at top, per-provider configuration cards, matched palette to Settings. |
| `MenuBar.swift` | Status-item menu (Microphone submenu, Settings, Run Setup, Open at Login, Recent Dictations, Quit). Microphone submenu rebuilds on open; selection posts `parleqMicrophoneSelectionChanged` so Settings reflects it. |
| `Config.swift` | `~/.parleq/config.json` loader/saver. |
| `UsageLedger.swift` + `PricingCache.swift` | Append-only JSONL at `~/.parleq/usage.jsonl` (**metadata only** — no transcript content) plus a LiteLLM live-pricing fetcher cached at `~/.parleq/pricing-cache.json`. |
| `KeychainStore.swift` | Wraps SecItem APIs for every provider secret: Gemini API key, Bedrock API key, AWS static credentials, Vertex service-account JSON, Azure resource API key. Service `com.parleq.app`. Settings UI is the canonical writer; never displayed in plaintext after save. |
| `LogFile.swift` | At launch, `dup2`s stderr to `~/.parleq/app.log` (10 MB cap, truncates on launch when over). Skipped when stderr is a TTY (developer mode). |
| `TranscriptHistory.swift` | In-memory ring buffer (cap 20) of recent cleaned transcripts. **Process memory only — never written to disk.** Surfaced via the menu bar's Recent Dictations submenu; clicking copies text to the pasteboard. Wiped on app quit. |

## Hard invariants — preserve through refactors

These are non-obvious and worth flagging to anyone editing the codebase:

1. **Audio is memory-only end-to-end.** `AudioRecorder.stop()` returns a `Data`. There is no URL-based path. **Do not** add `/tmp/parleq-*.wav` writes or any other audio-on-disk persistence — this is a load-bearing compliance promise.
2. **Transcript content never lands in stderr / log files.** ASR diagnostic is length-only (`(N chars / W words)`). Sidecar `[vocab]` log is count-only by default; full detail is opt-in via `PARLEQ_VOCAB_TRACE=1` env.
3. **`thinkingConfig.thinkingBudget = 0`** on every Gemini call (`LLMClient.swift`, `LLMStreaming.swift`). Default-on thinking is 2-3× latency, 5-7× cost, no quality gain on cleanup.
4. **`additionalModelRequestFields = {"reasoning_effort": "low"}`** on every Bedrock `openai.gpt-oss-*` call (`BedrockProvider.swift`). Drops the 220-token hidden reasoning channel to ~30 tokens.
5. **Fresh stateless LLM call per refinement turn.** No server-side conversation history.
6. **Audio never leaves the device.** Local FluidAudio sidecar only. Cleanup payloads (transcript text) go to the configured LLM provider; that's the only network boundary input data crosses.

## Active gotchas (will trip new contributors)

- **Soto INI parser strips `#` mid-value** in `~/.aws/config`. AWS Identity Center start URLs ending in `/#` cause `tokenCacheNotFound` for SSO. Workaround: drop the trailing `#`. Documented inline in `BedrockProvider.swift`.
- **launchd-spawned apps don't inherit shell env.** `AWS_PROFILE` set in `.zshrc` works when launching from a terminal, doesn't work when launching from Finder/Spotlight. Provider secrets and AWS profiles should go through Settings (Keychain) rather than env vars. `ShellEnvironment.swift` augments PATH so spawned `gcloud`/`az` CLIs are findable in the launchd-spawned case.
- **Bedrock model access is per-region.** Same account can have GPT-OSS enabled in `us-east-2` and Claude Haiku enabled in `us-east-1` only. The `us.*` cross-region inference profile prefix doesn't change this.
- **Azure routes by deployment name, not model name.** Parleq's Settings has a Model family picker (Standard vs Reasoning) instead of a model name field — that picker drives request-shape branching (`max_tokens` vs `max_completion_tokens`), since Parleq can't infer the family from the user-chosen deployment name.
- **Restart-required settings** show an orange banner with a "Restart Now" button. Settings the runtime reads at launch (provider, model, region, profile, hotkey, audio routing) need a relaunch; settings re-read per-utterance (custom dictionary) don't.
- **Sidecar is a separate Swift package** at `third_party/fluidaudio-sidecar/`. It builds independently. Changes to the wire protocol (`/inference` request shape, the `X-Parleq-Vocabulary` header) need coordinated edits in both places.
- **Window centering bug class.** Setting `setContentSize(...)` BEFORE `center()` matters: SwiftUI hosts measure async, so calling `center()` before the content size is set centers a tiny default frame, after which SwiftUI grows the window from its bottom-left origin into the upper-right of the screen.

## Configuration shape

`~/.parleq/config.json`:

```json
{
  "hotkey":     { "binding": "option-right" },
  "ui":         { "auto_accept_seconds": 0, "acoustic_feedback": true },
  "audio":      { "continue_other_audio": true, "input_device_uid": "" },
  "asr":        { "mode": "default", "endpoint": "http://127.0.0.1:8767/inference" },
  "llm":        { "mode": "default", "provider": "gemini", "model": "gemini-2.5-flash" },
  "aws":        { "region": "us-east-2", "profile": "", "auth_mode": "sso" },
  "vertex":     { "project": "", "region": "us-central1", "auth_mode": "adc" },
  "azure":      { "resource": "", "deployment": "", "api_version": "2025-04-01-preview", "auth_mode": "apiKey", "family": "standard" },
  "wizard":     { "completed": false },
  "paste":      { "trailing_space": true, "no_trailing_space_apps": [] },
  "dictionary": { "terms": [{ "term": "Parleq", "context": "the app I'm building", "aliases": ["parlay", "parlez"], "biasing": "asrAndLLM" }] },
  "telemetry":  { "enabled": false }
}
```

Schema is documented in source comments at the top of `Config.swift`. The Settings UI is the canonical editor; manual JSON edits also work but settings-window opens auto-load and rewrite the file.

## Environment variables

| Variable | Purpose |
|---|---|
| `GEMINI_API_KEY` | Google AI key for Gemini provider. Resolved at app launch; Keychain takes precedence in Settings UI. |
| `AWS_PROFILE` / `AWS_REGION` | Fallbacks when Settings AWS profile/region are empty. Won't work for Finder launches (sparse launchd env). |
| `PARLEQ_VOCAB_PRELOAD=1` | Set automatically by `SidecarSupervisor` when dictionary is non-empty — eager-loads the CTC vocab encoder at startup. |
| `PARLEQ_VOCAB_TRACE=1` | Opt-in: restores per-replacement detail in the sidecar log. Off by default for compliance. |
| `PARLEQ_BEDROCK_TRACE=1` | Opt-in: enables Soto's debug logger to stderr. Off by default. |
| `PARLEQ_SUPERVISOR_PID` | Set by the supervisor on the sidecar process so the sidecar can arm a kqueue NOTE_EXIT watch and self-terminate when Parleq exits. |

## Commit conventions

Match the existing log style (e.g. `git log --oneline -10`):

- `feat(scope): …` — new feature
- `fix(scope): …` — bug fix
- `ui(scope): …` / `docs(scope): …` — UI / documentation polish
- `chore(scope): …` — housekeeping

Multi-paragraph body explaining the *why*. Reference issue numbers (`closes #N`, `tracked in #N`). Co-author tag for AI-assisted commits.

Don't commit `Package.resolved` (gitignored), `.build/` artifacts, or `node_modules/`.

## Documentation pointers

- [`docs/SETUP.md`](docs/SETUP.md) — AWS Bedrock setup walkthrough (account, model access, credentials).
- [`docs/SECURITY_REVIEW.md`](docs/SECURITY_REVIEW.md) — packet for enterprise security / cloudops review. Data flows, trust boundaries, secrets management, audit findings + remediations, known limitations.
- [`parleq-app/README.md`](parleq-app/README.md) — module-level reference for the app target.
- [parleq.app/docs](https://parleq.app/docs/) — public per-provider setup guides (Gemini, Vertex AI, Bedrock, Azure OpenAI).
- [parleq.app/how-it-works](https://parleq.app/how-it-works/) — public architecture walkthrough (capture → transcribe → clean up → paste).
