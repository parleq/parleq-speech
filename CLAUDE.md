# Parleq codebase guide

Reference for human contributors and AI assistants working in this repo. Parleq is an open-source macOS dictation app: press a global hotkey, speak, see post-processed text in a floating overlay, accept to paste. ASR runs locally on the Apple Neural Engine (FluidAudio Parakeet TDT v3); LLM cleanup is provider-pluggable across Google Gemini, Google Vertex AI, AWS Bedrock, and Azure OpenAI.

The user-facing site is at [parleq.app](https://parleq.app).

## Tech stack

- **Swift 6** (strict concurrency), **SwiftPM**, **macOS 14+**.
- **Soto** for AWS Bedrock SigV4 (`SotoBedrockRuntime`); custom `BedrockBearerProvider` for the Bedrock-API-key path that bypasses Soto entirely.
- **FluidAudio** for Parakeet TDT v3 + CTC vocabulary boosting on the Apple Neural Engine. **Runs in-process** (see `LocalASR.swift`); v0.9.0 retired the bundled HTTP sidecar that previously wrapped it.
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

## Development & release workflow

The loop that works well here — follow it unless told otherwise:

1. **Work in worktrees.** Build a meaningful chunk on a feature branch in a worktree under `../parleq-worktrees/` (single branch, or stacked branches). Keep the main checkout on `main`.
2. **AI-assisted step-by-step testing.** When the chunk is ready, the AI assistant builds and restarts the app (`parleq-app/scripts/make-app.sh --debug`, then `pkill -x ParleqApp` + `open parleq-app/build/Parleq.app`) and walks the maintainer through testing one numbered step at a time. The maintainer just follows the steps and reports back — they shouldn't have to drive the build/restart themselves.
3. **Audit round (often).** After testing passes, do another pass — serious bugs, security, proprietary-data exposure, open-source-license-page completeness (`THIRD_PARTY_LICENSES.md` + `NOTICE`), and unwanted competitor references. Fix findings; re-test.
4. **Local review pass until clean.** Commit in small increments; run your local code-review and lint tooling (`swift build` at minimum) and resolve what it flags before moving on. Don't push to GitHub until it's clean.
5. **Hard approval gate.** Do **NOT** push to GitHub or open/update a PR until the maintainer gives explicit approval. Stage everything (branch committed, local checks clean) and wait.
6. **Version bump happens inside the PR (the AI assistant handles it, not the maintainer).** `make set-version VERSION=x.y.z` (edits `parleq-app/Resources/Info.plist`) + a `CHANGELOG.md` section + rewrite `RELEASE_NOTES.txt` (first line must be `Parleq <version>` — `make release` validates this).
7. **One PR per logical change.** Bundle phased/stacked work into a single PR. Push + `gh pr create` only after approval; use a separate `Closes #N.` sentence per issue (comma-separated lists only close the first).
8. **Maintainer merges** (usually squash — so the branch tip won't be an ancestor of `main`; use `git branch -D` after confirming the PR merged).
9. **Maintainer pulls `main` and runs `make release`** (DMG + GitHub release + appcast). Don't run destructive git ops (worktree remove / branch delete) while `make release` is running — wait for it to exit. After merge + release, clean up worktrees and delete the merged branches.

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
- **FluidAudio** — Parakeet model versions, CTC vocab boosting tweaks, ANE performance. Now a direct dependency of the main app target (not its retired sidecar package).
- **swift-nio**, **swift-crypto**, **swift-certificates** — Apple-maintained, security-relevant. Pulled in transitively by Soto.

## Repository layout

```
parleq-speech/
├── parleq-app/                          ← the macOS app (Swift / SwiftPM)
│   ├── Sources/ParleqApp/               ← all Swift sources
│   ├── Resources/                       ← Info.plist, entitlements
│   ├── scripts/make-app.sh              ← bundle build + sign
│   └── README.md                        ← per-module reference
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
| `LocalASR.swift` | In-process FluidAudio batch ASR (Parakeet TDT v3) + CTC vocabulary rescoring. The bundled-path engine `ASRClient` routes to when `asr.endpoint` matches `Config.bundledASREndpoint`. |
| `ASRClient.swift` | Two-headed: bundled path calls `LocalASR` in-process; HTTP path `POST`s WAV bytes + `X-Parleq-Vocabulary` header to a user-configured external `asr.endpoint` (Sherpa-ONNX, faster-whisper, …). |
| `LLMProvider.swift` | Provider protocol + shared types (`LLMMessage`, `LLMStreamEvent`, `LLMStreamSummary`). |
| `LLMClient.swift` + `LLMStreaming.swift` | Google Gemini direct-API impl (SSE streaming). |
| `VertexProvider.swift` + `VertexServiceAccount.swift` | Google Vertex AI impl. Four auth modes: gcloud ADC (shells out for tokens), service-account JSON (mints OAuth tokens via JWT-bearer / RS256), `oidcFederation` (Workforce Identity federated bearer from `CachedExchange` + `x-goog-user-project`), and `googleOAuth` (native Google sign-in via the OIDC engine — the session's OAuth access token, with the `cloud-platform` scope, is the Vertex bearer directly; no exchanger/STS hop; same `x-goog-user-project` header). |
| `BedrockProvider.swift` | AWS Bedrock impl via Soto `ConverseStream`. SSO + static-credential auth modes, plus `oidc` mode (federated STS credentials from `CachedExchange`). |
| `BedrockBearerProvider.swift` + `BedrockEventStream.swift` | Scoped Bedrock-API-key auth path. Plain HTTPS with `Authorization: Bearer <key>`, in-tree event-stream parser — bypasses Soto entirely. |
| `AzureOpenAIProvider.swift` | Azure OpenAI impl. Two auth modes (resource API key, Microsoft Entra ID via `az login`). Two model families (Standard, Reasoning) since Azure routes by deployment name. |
| `OIDCSession.swift` | Cloud-ignorant OIDC actor for enterprise federation: discovery, PKCE sign-in, rotation-safe single-flight refresh (rotated refresh token persisted to Keychain on receipt), published state machine. The browser seam (`OIDCAuthenticator`) takes a build-authorization-URL closure so the authenticator can supply the effective redirect URI (loopback flows know it only after binding); the token exchange echoes that exact value. `OIDCSessionModel` is the MainActor facade for SwiftUI. ID/access tokens are memory-only; only the refresh token + identity snapshot persist (Keychain). |
| `LoopbackRedirectServer.swift` | Transient `NWListener` bound to 127.0.0.1 only on an ephemeral port, for the OIDC loopback-redirect sign-in (Google "Desktop app" client; `http://127.0.0.1:<port>/<path>` redirect that `ASWebAuthenticationSession` can't intercept). One callback, STATIC HTML response (no `code`/`state` reflected), defer-based teardown, no callback URL/query logged. The **one** carve-out to the no-listening-sockets invariant — exists only during an active sign-in. Selected in `CompanyAccountView.makeOIDCAuthenticator` when the configured redirect is http+loopback; custom schemes still use `ASWebAuthenticationSession`. |
| `CloudCredentialExchangers.swift` | Turns an OIDC ID token into per-cloud credentials behind a single-flight TTL cache (`CachedExchange`, 5-min refresh-ahead, hotkey-down `warm()`). `AWSWebIdentityExchanger` (Soto STS `AssumeRoleWithWebIdentity` → temp credentials; email as role-session name for CloudTrail) and `GCPWorkforceExchanger` (Workforce Identity Federation token exchange → federated bearer). Per-hop status feeds the connection doctor; logs are state+code only. |
| `CompanyAccountView.swift` | "Company Account" Settings section: corporate sign-in, signed-in identity (renders name/email in UI only — never logged), and a connection doctor (token-free discovery → silent refresh → per-leg AWS/GCP exchange status). Fails closed to raw on-device ASR when federation is unavailable. |
| `SystemPrompts.swift` | Cleanup + refine prompts. `cleanup(dictionary:)` returns the prompt with an optional smart-vocabulary addendum. |
| `OverlayWindow.swift` | Borderless `NSPanel` + SwiftUI. Captures Enter/Esc without stealing focus. |
| `Paster.swift` | Pasteboard snapshot → set → activate target → simulate Cmd-V → restore. |
| `SettingsWindow.swift` | SwiftUI two-pane Settings. Sidebar with sections (Hotkey, Audio, Behavior, Paste, Cleanup, Dictionary, Usage, Advanced); per-section content cards. Always-center window, brand amber accent. |
| `PresetsSettingsView.swift` | "Presets" Settings pane: transform-preset list editor (name + prompt) + per-app default mapping. A preset is a canned refine instruction; an app default folds into that app's cleanup prompt (one LLM call) with a "Styled with X · Undo" chip in the overlay. |
| `SetupWizard.swift` | First-run / re-runnable setup wizard. Step-pill progress indicator at top, per-provider configuration cards, matched palette to Settings. |
| `MenuBar.swift` | Status-item menu (Microphone submenu, Settings, Run Setup, Open at Login, Recent Dictations, Quit). Microphone submenu rebuilds on open; selection posts `parleqMicrophoneSelectionChanged` so Settings reflects it. |
| `Config.swift` | `~/.parleq/config.json` loader/saver. |
| `UsageLedger.swift` + `PricingCache.swift` | Append-only JSONL at `~/.parleq/usage.jsonl` (**metadata only** — no transcript content) plus a LiteLLM live-pricing fetcher cached at `~/.parleq/pricing-cache.json`. |
| `KeychainStore.swift` | Wraps SecItem APIs for every provider secret: Gemini API key, Bedrock API key, AWS static credentials, Vertex service-account JSON, Azure resource API key, OIDC refresh token + identity snapshot (enterprise federation; access/ID tokens are memory-only). Service `com.parleq.app`. Settings UI is the canonical writer; never displayed in plaintext after save. |
| `LogFile.swift` | At launch, `dup2`s stderr to `~/.parleq/app.log` (10 MB cap, truncates on launch when over). Skipped when stderr is a TTY (developer mode). |
| `TranscriptHistory.swift` | Unlimited by default (bounded via the managed/config caps; `0` disables) in-memory list of recent cleaned transcripts. **Process memory only — never written to disk.** Surfaced in the Parleq window's Recent Dictations section (the menu-bar submenu was removed in 0.14.0); clicking copies text to the pasteboard. Wiped on app quit. |
| `SpellOutDetector.swift` | Detects spelled-out word candidates (e.g. "A-P-I") in the raw ASR transcript and surfaces the assembled term + context as a correction signal for the learning journal. |
| `CorrectionJournal.swift` | Opt-in, bounded, **in-memory-only** ring buffer of correction signals — voice-refine events (instruction + the edit's before/after text) and spell-out candidates (assembled term + the cleaned text it appeared in). Captures correction *events* only, not a log of every dictation (a refine record holds that edit's full before/after text). Count + age caps bound the ring; **never written to disk**; wiped on app quit; off by default. |
| `LearningAnalyzer.swift` | Periodic off-hot-path actor that reads the in-memory correction ring, asks the configured cleanup LLM to propose dictionary additions/modifications, then hands high-confidence non-colliding proposals to `LearnedStore` for auto-apply and the rest as pending suggestions. Analysis logging is count-only (no transcript content). |
| `LearnedStore.swift` | Apply / suggest / revert surface. Auto-applies high-confidence term proposals into the custom dictionary (tagged `source: learned`, revertibly); everything else becomes a pending suggestion. **In-memory only** (pending suggestions + applied-changes log are process memory, wiped on quit); the only durable output is the learned dictionary terms written to `config.json`. |
| `LearnedView.swift` | SwiftUI "Learned" sidebar section in Settings. Surfaces pending suggestions (Accept / Dismiss) and the applied-changes log (Revert). Toggle to enable/disable the feature with an offer to purge the journal. |

## Hard invariants — preserve through refactors

These are non-obvious and worth flagging to anyone editing the codebase:

1. **Audio is memory-only end-to-end.** `AudioRecorder.stop()` returns a `Data`. There is no URL-based path. **Do not** add `/tmp/parleq-*.wav` writes or any other audio-on-disk persistence — this is a load-bearing compliance promise.
2. **Transcript content never lands in stderr / log files.** ASR diagnostic is length-only (`(N chars / W words)`). `LocalASR`'s `[vocab]` log is count-only by default; full per-replacement detail is opt-in via `PARLEQ_VOCAB_TRACE=1` env.
3. **`thinkingConfig.thinkingBudget` defaults LOW on every Gemini call** (`LLMClient.swift`, `LLMStreaming.swift`, `VertexProvider.swift`): `0` on Flash/Flash-Lite; the `128`-token floor on Pro, which mandates thinking and rejects `0`. These are the DEFAULTS when unset — config-overridable via `llm.tuning.thinking_budget` (config-file only, range `0…32768`; no UI/MDM), so the value isn't hard-pinned, just defaulted low. Default-on/dynamic thinking is 2-3× latency, 5-7× cost, no quality gain on cleanup — Pro's dynamic default is worse still (10-20s to first token).
4. **`additionalModelRequestFields = {"reasoning_effort": "low"}`** on every Bedrock `openai.gpt-oss-*` call (`BedrockProvider.swift`). Drops the 220-token hidden reasoning channel to ~30 tokens.
5. **Fresh stateless LLM call per refinement turn.** No server-side conversation history.
6. **Audio never leaves the device.** In-process FluidAudio is the only ASR path by default; no local listening socket on the dictation path, no IPC. Cleanup payloads (transcript text) go to the configured LLM provider; that's the only network boundary input data crosses. The optional user-configured `asr.endpoint` (Sherpa-ONNX / faster-whisper running locally) is also a localhost endpoint by convention but the user owns its lifecycle. **One carve-out to "no local listening socket":** the OIDC loopback-redirect sign-in (`LoopbackRedirectServer.swift`) binds a 127.0.0.1-only ephemeral-port listener for the *duration of an active corporate sign-in only* — single callback, static response, defer-based teardown, never logs the callback URL. It does not carry audio and does not exist during dictation. The carve-out is gated **solely** by the redirect_uri (http+loopback selects it; every custom scheme uses `ASWebAuthenticationSession` and binds nothing), so it is fully suppressible by pinning the `oidcRedirectURI` MDM key to a custom-scheme value — there is intentionally no separate "disable loopback" key. Disclosed in `docs/SECURITY_REVIEW.md` §3.4.1.
7. **"Learn from corrections" is opt-in, off by default, and never writes dictation-derived text to disk.** When enabled, `CorrectionJournal` holds correction snippets in an **in-memory ring only** (never written to `~/.parleq/` or anywhere else); `LearningAnalyzer` sends those snippets to the **already-configured** cleanup LLM during periodic off-hot-path analysis (no new network boundary). Analysis log output is count-only — no transcript content in logs. The ring has count + age caps (`learnedCorrectionsMaxEntries` / `learnedCorrectionsRetentionHours`); setting either to `0` disables entirely. Disabling the feature from Settings offers to clear the in-memory ring (and it's cleared on quit regardless). The only on-disk artifact is the learned dictionary terms in `config.json`.

## Active gotchas (will trip new contributors)

- **Soto INI parser strips `#` mid-value** in `~/.aws/config`. AWS Identity Center start URLs ending in `/#` cause `tokenCacheNotFound` for SSO. Workaround: drop the trailing `#`. Documented inline in `BedrockProvider.swift`.
- **launchd-spawned apps don't inherit shell env.** `AWS_PROFILE` set in `.zshrc` works when launching from a terminal, doesn't work when launching from Finder/Spotlight. Provider secrets and AWS profiles should go through Settings (Keychain) rather than env vars. `ShellEnvironment.swift` augments PATH so spawned `gcloud`/`az` CLIs are findable in the launchd-spawned case.
- **Bedrock model access is per-region.** Same account can have GPT-OSS enabled in `us-east-2` and Claude Haiku enabled in `us-east-1` only. The `us.*` cross-region inference profile prefix doesn't change this.
- **Azure routes by deployment name, not model name.** Parleq's Settings has a Model family picker (Standard vs Reasoning) instead of a model name field — that picker drives request-shape branching (`max_tokens` vs `max_completion_tokens`), since Parleq can't infer the family from the user-chosen deployment name.
- **Restart-required settings** show an orange banner with a "Restart Now" button. Settings the runtime reads at launch (provider, model, region, profile, hotkey, audio routing) need a relaunch; settings re-read per-utterance (custom dictionary) don't.
- **`asr.endpoint`'s default value is a magic sentinel, not a real URL.** The string `http://127.0.0.1:8767/inference` was the retired sidecar's listen address and is kept verbatim so config files written by 0.7.x / 0.8.x builds keep working — but in 0.9.0+ matching this exact value triggers the in-process `LocalASR` path. Any other value routes through `ASRClient`'s HTTP code (Sherpa-ONNX, faster-whisper, etc.).
- **Window centering bug class.** Setting `setContentSize(...)` BEFORE `center()` matters: SwiftUI hosts measure async, so calling `center()` before the content size is set centers a tiny default frame, after which SwiftUI grows the window from its bottom-left origin into the upper-right of the screen.
- **`NavigationSplitView` detail panes must pin to the viewport height.** A detail pane whose root is a `VStack` of a fixed header + fixed-height content cards (e.g. `RecentDictationsView`) must be pinned to the host's height — wrap it in `GeometryReader { geo in … .frame(width: geo.size.width, height: geo.size.height, alignment: .top) }`. Letting it resolve to its ideal height via `.frame(maxHeight: .infinity)` makes a tall pane overflow off the **top** of a short window, dragging *both* split columns (sidebar included) above the visible area. Panes that are already a single top-level `ScrollView` (e.g. `StatsView`) don't hit this. Adding/removing a banner row changes the ideal height, so this stays latent until a banner is toggled.

## Configuration shape

`~/.parleq/config.json`:

```json
{
  "hotkey":     { "binding": "option-right" },
  "ui":         { "auto_accept_seconds": 0, "acoustic_feedback": true },
  "audio":      { "continue_other_audio": true, "input_device_uid": "" },
  "asr":        { "mode": "default", "endpoint": "http://127.0.0.1:8767/inference" },
  "llm":        { "mode": "default", "provider": "gemini", "model": "gemini-2.5-flash",
                  "tuning": { "thinking_budget": null, "max_output_tokens": 2048,
                              "temperature": 0, "ttft_deadline_seconds": [5.5, 8.0],
                              "ttft_deadline_thinking_seconds": [25.0],
                              "request_timeout_seconds": 60 } },
  "aws":        { "region": "us-east-2", "profile": "", "auth_mode": "sso",
                  "role_arn": "", "session_duration_seconds": 3600 },
  "vertex":     { "project": "", "region": "us-central1", "auth_mode": "adc",
                  "workforce_provider": "" },
  "azure":      { "resource": "", "deployment": "", "api_version": "2025-04-01-preview", "auth_mode": "apiKey", "family": "standard" },
  "oidc":       { "issuer": "", "client_id": "",
                  "scopes": ["openid", "profile", "email", "offline_access"],
                  "ephemeral_browser": false,
                  "redirect_uri": "parleq-auth://oidc/callback",
                  "extra_auth_params": {} },
  "wizard":     { "completed": false },
  "paste":      { "trailing_space": true, "no_trailing_space_apps": [] },
  "dictionary": { "terms": [{ "term": "Parleq", "context": "voice dictation app", "aliases": ["parlay", "parlez"], "biasing": "asrAndLLM" }] },
  "presets":    [{ "id": "…", "name": "Concise", "prompt": "Rewrite the text to be as concise as possible while preserving all key information." }],
  "preset_app_defaults": { "com.apple.mail": "<preset id>" },
  "features":   { "learn_from_corrections_enabled": false,
                  "learned_corrections_max_entries": null,
                  "learned_corrections_retention_hours": null }
}
```

Schema is documented in source comments at the top of `Config.swift`. The Settings UI is the canonical editor; manual JSON edits also work but settings-window opens auto-load and rewrite the file.

## Environment variables

| Variable | Purpose |
|---|---|
| `GEMINI_API_KEY` | Google AI key for Gemini provider. Resolved at app launch; Keychain takes precedence in Settings UI. |
| `AWS_PROFILE` / `AWS_REGION` | Fallbacks when Settings AWS profile/region are empty. Won't work for Finder launches (sparse launchd env). |
| `PARLEQ_VOCAB_TRACE=1` | Opt-in: restores per-replacement detail in the `LocalASR` `[vocab]` log lines (`replaced 'X' → 'Y' [reason]`). Off by default for compliance. |
| `PARLEQ_HOTKEY_TRACE=1` | Opt-in: hotkey gesture-classifier timing trace (gap/held ms) to stderr. Off by default. |
| `PARLEQ_BEDROCK_TRACE=1` | Opt-in: enables Soto's debug logger to stderr. Off by default. |
| `PARLEQ_PASTE_TRACE=1` | Opt-in: at synthetic-paste time logs the ambient corruption-prone modifier mask (hex) + how long Paster waited for it to clear (`paste post (ambientMods=0x…, waited=…ms)`). Flags + ms only — never transcript/pasteboard content. Off by default. |
| `PARLEQ_LEARN_TRIGGER=<n>` | Demo/debug: lowers the learning analyzer's correction-count trigger threshold (e.g. `=1` to run after a single correction). Default 5. |
| `PARLEQ_LEARN_MIN_INTERVAL=<seconds>` | Demo/debug: shortens the learning analyzer's minimum interval between runs (e.g. `=0` for back-to-back runs). Default 600. |

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
