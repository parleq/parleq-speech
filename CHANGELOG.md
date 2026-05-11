# Changelog

All notable changes to Parleq are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

(no changes yet)

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

[Unreleased]: https://github.com/parleq/parleq-speech/compare/v0.8.0...HEAD
[0.8.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.8.0
[0.7.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.7.0
