<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="web/public/logo-dark.svg">
    <img src="web/public/logo.svg" alt="Parleq" height="80">
  </picture>
</p>

# Parleq

Open-source, voice-driven text composition for macOS.

Press a global hotkey, speak, see post-processed text appear in a floating overlay. Hold the hotkey again to refine, reformat, or extend it. Accept to paste into whatever app you were using.

> **Status:** in active personal use. The bundled Mac path (FluidAudio Parakeet TDT v3 on the Apple Neural Engine for ASR + your choice of Gemini, Vertex AI, AWS Bedrock, or Azure OpenAI for cleanup) works end-to-end.

**Website:** <https://parleq.app> — landing page with an end-user-friendly download path. Source under [`web/`](web/), deployed by GitHub Actions on every push to `main`.

## What's distinctive

- **Preview-and-refine overlay.** Cleaned text appears in a floating overlay first; further voice commands edit, reformat, or extend it in a multi-turn conversation. Final accept pastes into the originally-focused app.
- **Mac-native primary.** ASR runs locally on the Apple Neural Engine via FluidAudio Parakeet TDT v3 — ~64 ms transcription, ~150 MB resident, audio never leaves the device. No cold start, no provisioned GPU, no cents-per-call.
- **Pluggable LLM cleanup across four providers.** Google Gemini (direct AI Studio API) is the default for personal use; Google Vertex AI, AWS Bedrock (Claude Haiku 4.5 / GPT-OSS 120B), and Azure OpenAI are the enterprise paths. Each provider supports both pasted API keys and your existing CLI session (gcloud, AWS SSO, az login). Or skip cleanup entirely and paste raw transcripts.
- **Custom dictionary.** Names and terms that ASR commonly mis-transcribes (project names, proper nouns) bias both the STT pass (CTC keyword-spotting) and the LLM cleanup (smart-vocabulary hint with optional context blurbs). Each entry can list alternate spellings the ASR commonly emits — the rescorer matches against any of them but always emits the canonical term. Per-entry biasing toggle lets you skip the STT pass on terms that trigger false positives there while keeping the LLM hint. Edits apply on the next dictation, no restart.
- **Recent dictations recovery.** Last 20 cleaned transcripts are kept in process memory and surfaced via the menu bar's Recent Dictations submenu. Click an entry to copy it back to the clipboard — useful when a paste landed somewhere unexpected. Wiped on app quit; never written to disk.
- **Compliance-friendly.** Audio is memory-only end-to-end. Logs at `~/.parleq/app.log` carry length-only diagnostics (no transcripts, no audio, no auth values). Provider API keys live in the macOS Keychain (no plaintext-on-disk fallback); CLI-session auth modes (gcloud, AWS SSO, az login) delegate token refresh to the relevant CLI cache so Parleq doesn't store long-lived cloud session tokens directly. Designed to satisfy enterprise policies that prohibit storing input data on the local computer.

## Quick start

**Pre-built (notarized):** download the latest `.dmg` from [github.com/parleq/parleq-speech/releases](https://github.com/parleq/parleq-speech/releases), open it, and drag `Parleq.app` to the Applications folder. Each release ships with a `.sha256` for verification.

**From source:**
```bash
git clone https://github.com/parleq/parleq-speech.git
cd parleq-speech
make install
open /Applications/Parleq.app
```

Grant Microphone + Accessibility on first launch (both required). Hold **right Option** to dictate; release to clean and paste.

First launch downloads the speech model (~150 MB) — the menu-bar icon shows a download glyph until ready, typically 30–60 s on first run and under 5 s on subsequent launches. The icon switches to a microphone once the app is ready to capture.

To enable LLM cleanup, pick a provider in the first-run setup wizard or **Settings → LLM**. Google Gemini is the simplest (one API key from AI Studio); the enterprise paths (Vertex AI, AWS Bedrock, Azure OpenAI) all support your existing CLI sign-in. **See [parleq.app/docs](https://parleq.app/docs/) for per-provider setup walkthroughs.** AWS-specific operational notes are in [`docs/SETUP.md`](docs/SETUP.md).

## Architecture at a glance

| Component | What it does | Where it lives |
|---|---|---|
| ParleqApp | Hotkey listener, audio capture, overlay UI, paste, settings, setup wizard | `parleq-app/Sources/ParleqApp/` |
| LocalASR | In-process Parakeet TDT v3 (Apple Neural Engine) + CTC vocab boosting — no listening sockets, no separate process | `parleq-app/Sources/ParleqApp/LocalASR.swift` |
| LLMProvider | Provider-agnostic streaming cleanup interface — implementations for Gemini, Vertex AI, Bedrock, Azure OpenAI | `parleq-app/Sources/ParleqApp/{LLMProvider,LLMClient,VertexProvider,BedrockProvider,BedrockBearerProvider,AzureOpenAIProvider}.swift` |
| Custom dictionary | User-maintained term list biasing both ASR and LLM passes | `~/.parleq/config.json` |

A walkthrough of the four-stage pipeline (capture → transcribe → clean up → paste) is at [parleq.app/how-it-works](https://parleq.app/how-it-works/). For an enterprise security / cloudops review, [`docs/SECURITY_REVIEW.md`](docs/SECURITY_REVIEW.md) is a self-contained packet covering data flows, trust boundaries, secrets management, and known limitations. A codebase guide for contributors lives at [`CLAUDE.md`](CLAUDE.md).

## Project posture

- **Open-source from day one** under Apache 2.0. Designed to be self-hosted, forked, modified.
- **Local-first storage.** Settings, dictionary, and the LLM-call ledger live at `~/.parleq/`. Audio and transcripts are never persisted.
- **Pluggable seams.** ASR endpoint, LLM provider, AWS profile/region, hotkey binding, custom dictionary — all configurable. Same binary works on a personal Mac with Gemini and on a work Mac with Bedrock.

## Related

- **Parleq Router** — sibling library for natural-language intent routing in AI apps. Different problem space (text → intent classification); shared brand.

## Acknowledgments

Parleq stands on the shoulders of several excellent open-source projects:

- **[FluidAudio](https://github.com/FluidInference/FluidAudio)** for the CoreML pipeline that runs Parakeet TDT v3 and the CTC keyword spotter on the Apple Neural Engine. Linked directly into the main app target since v0.9.0.
- **[Soto](https://github.com/soto-project/soto)** for the Swift-native AWS SDK that powers the Bedrock cleanup path.
- **[Apple's Swift open source projects](https://www.swift.org/)** — SwiftNIO, Swift Crypto, Swift Collections, and the rest of the swift-* family — for the foundation everything else builds on.

The NeMo Parakeet TDT v3 checkpoint (CoreML-converted by FluidInference and downloaded from Hugging Face on first run) is what makes private, fast on-device transcription possible at all. Thanks to NVIDIA's NeMo team for the upstream model.

A complete inventory of every third-party package, version, license, and source URL — plus the obligations they impose on redistributors — is in [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md). Aggregated upstream attribution lives in [`NOTICE`](NOTICE).

## License

Apache 2.0. See [`LICENSE`](LICENSE) for the full text and [`NOTICE`](NOTICE) for upstream attribution. A package-by-package inventory, including each dependency's license and source URL, is in [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).
