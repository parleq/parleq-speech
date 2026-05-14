# Changelog

All notable changes to Parleq are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

(no changes yet)

## [0.9.0] - 2026-05-14

Architectural simplification: FluidAudio now runs in-process, retiring the bundled HTTP sidecar that earlier builds spawned alongside the main app. No user-visible behavior change to dictation; visible UI change is the menu item formerly called "Restart Sidecar" is now "Reset ASR" and gains a clearer load-failure tooltip with a retry hint.

### Changed

- **FluidAudio runs in-process; the bundled HTTP sidecar is gone.** Earlier builds (≤ v0.8.x) hosted the speech recognizer in a separate `fluidaudio-sidecar` Swift package, supervised as a child process and reached over `127.0.0.1:8767` with bearer-token auth. v0.9.0 folds that pipeline into the main app target via a new `LocalASR` module. Wins: no listening sockets on the default ASR path (stronger compliance posture — "no local server" beats "local server with bearer auth"), single signed binary in the bundle, Hummingbird is dropped as a dependency, the app and the speech engine share fate (an ASR crash takes the app down loudly instead of leaving the menu bar alive but black-holed). The menu's **Restart Sidecar** item is now **Reset ASR** — same recovery affordance, but it unloads + reloads the FluidAudio model in-process instead of cycling a child process.
- **`asr.endpoint`'s default value is now a sentinel, not a URL.** The string `http://127.0.0.1:8767/inference` is kept verbatim for back-compat with config files written by 0.7.x / 0.8.x builds — but in 0.9.0+ matching it triggers the in-process `LocalASR` path. Any other value continues to route through `ASRClient`'s HTTP code so existing Sherpa-ONNX / faster-whisper / custom-server users keep working without a config change.
- **Model load failures are now recoverable from the menu.** If the first-run download fails (network blip, disk full, sandbox denial), `LocalASR` auto-retries once after ~10 s; if that also fails, the menu bar surfaces "Speech model failed to load" with a tooltip pointing the user at "Reset ASR" to retry. The retired sidecar's exponential-backoff restarts didn't surface this clearly.

### Removed

- `SidecarSupervisor.swift`, `SidecarHealth.swift`, and the entire `third_party/fluidaudio-sidecar/` Swift package.
- The `PARLEQ_SIDECAR_TOKEN`, `PARLEQ_SUPERVISOR_PID`, `PARLEQ_VOCAB_PRELOAD`, and `FLUIDAUDIO_PORT` environment variables. `PARLEQ_VOCAB_TRACE=1` still works against `LocalASR`'s in-process vocab log lines.
- The `/tmp/parleq-sidecar.log` file. Diagnostics now go to the main app log at `~/.parleq/app.log` like everything else.
- Hummingbird dependency. FluidAudio is now a direct dependency of the main app target.
- The second codesigning pass in `scripts/make-app.sh` — the bundle is now a single signed binary.

## [0.8.1] - 2026-05-11

Two follow-on fixes to v0.8.0's Permissions work, plus a more atomic release flow internally.

### Fixed

- **Open at Login now actually registers.** The v0.8.0 bundle was missing the LaunchAgent plist that macOS's `SMAppService.mainApp` API looks for at `Contents/Library/LaunchAgents/<bundle-id>.plist`; without it, `SMAppService.mainApp.status` reported `.notFound` forever and `register()` had no service description to register. The plist now ships inside the bundle, so the toggle transitions through "Off → On" cleanly with macOS's standard "Parleq added items that can run in the background" approval prompt the first time.
- **`CADeviceDefaultAggregate` no longer leaks into the Microphone submenu** on macOS Sequoia. The discriminator is a UID-prefix filter for Apple's Core Audio system-aggregate naming conventions (`CADefaultDevice`, `CADeviceDefault`, `AppleAggregateDevice`), applied only to transport-Aggregate devices so user-created aggregates from Audio MIDI Setup are unaffected. Closes [#9](https://github.com/parleq/parleq-speech/issues/9).

### Internal

- New input-device diagnostic in `~/.parleq/app.log` at launch. One line per input device, recording transport type fourcc, IsHidden flag, IsPrivate flag, UID, name, and which filter (if any) excluded it from the Microphone submenu. Cheap (a handful of HAL queries), runs once per launch, gives us forensic data the next time a system-internal device leaks through without needing a debug build.
- `make release` is now atomic: validates `RELEASE_NOTES.txt`'s first line references the current version, builds the DMG, creates the GitHub release with assets attached, and dispatches the website redeploy in a single command. Requires the local branch to be pushed first. Companion `RELEASE_NOTES.txt` now lives at the repo root and is updated as part of the version-bump PR.

## [0.8.0] - 2026-05-11

Permissions section, brand polish, and several menu-bar fixes.

### Added

- **Permissions section in Settings** — a new "Permissions" sidebar entry (between Usage and Advanced) surfacing the current state of Microphone, Accessibility, and "Open at Login" with at-a-glance status pills and a primary action per row. Replaces the menu-bar "Open Login Items Settings…" entry that was removed in 0.7.0's chrome cleanup.
- **Permissions step in the Setup wizard** — first-run users now see the same three rows on a new wizard step (between Welcome and Pick Provider). The Continue button is gated on Microphone + Accessibility being granted and surfaces the blocking reason inline ("Continue (grant Microphone first)") so the user is never confused about why it's disabled. Open at Login stays optional.
- **System Settings deep-links** for the missing-permission rows — clicking "Allow…" routes directly to the right Privacy & Security pane rather than dumping the user at the top of System Settings.
- **SMAppService `.notFound` fallback** for Open at Login — when the underlying API can't manage the current build (unnotarized installs, `swift run`, etc.), the row degrades to a "Manual" pill plus an "Open Login Items Settings…" button. The functionality the old menu entry provided is preserved inside its new Permissions home.

### Changed

- **Brand the menu-bar status icon.** The status item near the clock now renders Parleq's five-bar mark instead of the generic SF Symbol microphone — same shape as the favicon, app icon, and wordmark. Two states: bars at the favicon's asymmetric rhythm (idle) and bars in a centered peak (active / capture in flight). Drawn as a template image so AppKit auto-tints for light/dark menu bars and re-rasterizes at Retina scale.
- **Microphone submenu now hides system-internal aggregates.** Filters cover three signals: `kAudioDevicePropertyIsHidden`, `kAudioDeviceTransportTypeAutoAggregate`, and (for transport-Aggregate devices) `kAudioAggregateDevicePropertyIsPrivate`. User-created aggregates from Audio MIDI Setup and Virtual devices (BlackHole, Audio Hijack, Loopback) stay visible. One known gap on macOS Sequoia where `CADeviceDefaultAggregate` still leaks through is tracked at [#9](https://github.com/parleq/parleq-speech/issues/9).
- **"Settings…" menu item is text-only.** Renamed the underlying action selector away from `openSettings` (the canonical macOS Ventura+ "Open Settings" responder action) so AppKit no longer auto-decorates the item with a gearshape SF Symbol. ⌘, continues to work.

### Internal

- Permissions detection wraps `AVCaptureDevice.authorizationStatus`, `AXIsProcessTrusted()`, and `LoginItem.{isEnabled, isSupported, requiresApproval}` behind a synchronous probe API. A shared `PermissionsModel` observes `NSApplication.didBecomeActiveNotification` and republishes the snapshot only when something actually changed, so the UI updates the moment a user returns from System Settings without churning on every ⌘-tab.
- New `PermissionRow` SwiftUI component plus three descriptor builders so the Settings section and the wizard step render the same content from the same source of truth.

## [0.7.0] - 2026-05-10

Initial public release.

Press a global hotkey, speak, see post-processed text in a floating overlay, accept to paste. Speech recognition runs locally on the Apple Neural Engine; LLM cleanup uses your choice of cloud AI provider — or skip cleanup entirely and paste the raw transcript.

### Capture and transcribe

- **On-device speech recognition** via FluidAudio Parakeet TDT v3 on the Apple Neural Engine. ~64 ms transcription latency for 5-second clips after warm-up. ~150 MB resident; no per-call cost; audio bytes never leave the device.
- **Bundled HTTP sidecar** with bearer-token auth on `127.0.0.1:8767`. Survives parent-process crashes via a kqueue parent-PID watch (frees the port immediately on supervisor death).
- **Microphone selector** in both the menu-bar popup and Settings → Audio, with a "Selected microphone disconnected" fallback when a saved device isn't currently connected. Persists by Core Audio device UID.
- **Bluetooth-aware audio routing** — when the system default is a BT headset, Parleq forces input to the built-in mic so headphones stay in A2DP and your music doesn't pause for the duration of the dictation. Toggle in Settings.

### LLM cleanup

- **Four pluggable providers** for the cleanup pass: Google Gemini (direct AI Studio API), Google Vertex AI, AWS Bedrock, Azure OpenAI. Or pick **None** to paste the raw transcript with no cloud round-trip.
- **Per-provider auth flexibility:**
  - **Gemini**: API key (Keychain or `GEMINI_API_KEY` env).
  - **Vertex AI**: gcloud Application Default Credentials, or service-account JSON via JWT-bearer / RS256.
  - **AWS Bedrock**: AWS SSO via Soto, static IAM credentials, or scoped Bedrock API keys (Bearer auth, bypasses Soto entirely).
  - **Azure OpenAI**: resource API key, or Microsoft Entra ID via `az login`. Standard / Reasoning model-family picker (Azure routes by deployment name, so Parleq can't infer the family).
- **Custom-model picker** in Settings for every provider — curated dropdown plus "Custom (enter below)" for free-form model identifiers.
- **Recommended Bedrock defaults**: GPT-OSS 120B with `reasoning_effort=low`, or Claude Haiku 4.5.

### Refinement loop

- **Preview-and-refine overlay** — cleaned text appears in a floating overlay before pasting; further hotkey presses become voice-driven edit instructions over the existing text. Tone changes, format swaps, corrections, multi-step composition, all driven by voice.

### Customization

- **Custom dictionary** — names and terms the speech model commonly mishears, with optional aliases for variant spellings, context blurbs to help the AI judge topic alignment, and a per-term toggle to skip STT-side biasing on terms that cause false positives.
- **Configurable hotkey** — right Option (default), left Option, either Control, either Command, either Shift, or Fn.
- **Per-app trailing-space override** — terminal apps and other contexts that handle their own spacing can opt out of the trailing space.

### Compliance posture

- **Audio is memory-only end-to-end** — `AudioRecorder.stop()` returns `Data`; no `/tmp/parleq-*.wav` writes, no audio cache files.
- **Length-only diagnostics** in `~/.parleq/app.log` — never transcript content.
- **All provider secrets in the macOS Keychain** (Gemini API key, Bedrock API key, AWS static IAM credentials, Vertex service-account JSON, Azure resource API key). No plaintext-on-disk fallback.
- **CLI-session auth modes** (AWS SSO, gcloud, az login) delegate to your existing CLI session caches — Parleq stores no long-lived AWS, GCP, or Azure session tokens directly.
- **Recent dictations** kept in process memory only (cap 20 entries, surfaced via a menu-bar submenu, wiped on app quit).

### UX polish

- **Two-pane Settings window** — sidebar with sections (Hotkey, Audio, Behavior, Paste, Cleanup, Dictionary, Usage, Advanced), card-styled detail content, brand amber accent. Always centers on open.
- **Setup Wizard** — first-run flow with a step-pill progress indicator, card-style provider configuration panels, matched palette to Settings.
- **Standard text-editing shortcuts** (⌘V, ⌘X, ⌘C, ⌘A, ⌘Z) work in every text field. (Required installing `NSApp.mainMenu` manually since Parleq is an `LSUIElement` app.)
- **Public website** at [parleq.app](https://parleq.app) with How It Works, per-provider Docs, FAQ, and About pages.

### Platform

- **Apple Silicon** (M1 / M2 / M3 / M4) running **macOS 14 (Sonoma) or later**.
- **Apache-2.0 licensed**. Source at [github.com/parleq/parleq-speech](https://github.com/parleq/parleq-speech).

[Unreleased]: https://github.com/parleq/parleq-speech/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.9.0
[0.8.1]: https://github.com/parleq/parleq-speech/releases/tag/v0.8.1
[0.8.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.8.0
[0.7.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.7.0
