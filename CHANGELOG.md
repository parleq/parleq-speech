# Changelog

All notable changes to Parleq are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/) once released.

## [Unreleased]

### Added

- **Microphone selector** in both the menu-bar popup and **Settings → Audio**, with a "Selected microphone disconnected" fallback when a saved device isn't currently connected. Persists by Core Audio device UID. ([#25](https://github.com/parleq/parleq-speech/issues/25))
- **Two-pane Settings window redesign**: sidebar with sections (Hotkey, Audio, Behavior, Paste, Cleanup, Dictionary, Usage, Advanced), card-styled detail content, brand amber accent. Always centers on open. ([#26](https://github.com/parleq/parleq-speech/issues/26))
- **Setup Wizard refresh** matching the Settings palette — step-pill progress indicator, card-style provider configuration panels, brand amber accent.
- **Custom-model picker** in Settings for every provider (Gemini, Vertex, Bedrock, Azure) — curated model dropdown plus "Custom (enter below)" for free-form entry.
- **Vertex AI provider** with two auth modes (gcloud Application Default Credentials, service-account JSON via JWT-bearer / RS256).
- **Azure OpenAI provider** with two auth modes (resource API key, Microsoft Entra ID via `az login`) and explicit Standard / Reasoning model-family picker (since Azure routes by deployment name).
- **Bedrock API-key auth** as a third Bedrock auth mode (alongside SSO and static IAM credentials), bypassing Soto entirely via a hand-rolled bearer-auth client.
- **Public website** at [parleq.app](https://parleq.app) with How It Works, per-provider Docs, FAQ, and About pages.

### Changed

- **Bundle identifier** renamed from `com.jonyoder.parleq` to `com.parleq.app` for the public release. Existing users updating across this boundary will need to re-grant Microphone + Accessibility permissions and re-add their Login Item registration. Keychain-stored secrets are unaffected (the Keychain service was already `com.parleq.app`).
- **Settings → "LLM" section** renamed to "Cleanup" for friendlier framing.
- **Free-tier claims** for Google Gemini softened — the previous "covers normal personal use" wording was rephrased to "available without a credit card; depends on Google's current quotas and how heavily you dictate."

### Fixed

- **⌘V / ⌘X / ⌘C / ⌘A in text fields** of the Setup Wizard and Settings windows. Parleq is an `LSUIElement` app and didn't install a default `NSApp.mainMenu`, so the standard text-editing keyboard shortcuts weren't routed via the responder chain. ([#24](https://github.com/parleq/parleq-speech/issues/24))
- **Orphaned sidecar process** when Parleq crashes without going through `applicationWillTerminate`. The bundled FluidAudio sidecar now arms a kqueue `NOTE_EXIT` watch on the supervisor PID and self-terminates on parent death, freeing port 8767 immediately.
- **Window centering** for Settings + Wizard — both windows now always center on open, including the very first open after launch. Earlier behavior anchored them in the upper-right of the screen on first launch due to a SwiftUI content-sizing race with `NSWindow.center()`.

## [0.5.0] - 2026-05-07

Initial public release. Press a global hotkey, speak, see post-processed text in a floating overlay, accept to paste. ASR runs locally on the Apple Neural Engine via FluidAudio Parakeet TDT v3; LLM cleanup uses Google Gemini (default) or AWS Bedrock with Claude Haiku 4.5 / GPT-OSS 120B.

[Unreleased]: https://github.com/parleq/parleq-speech/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.5.0
