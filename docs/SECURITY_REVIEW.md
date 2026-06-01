# Parleq security review packet

This document is the starting point for an enterprise security / cloudops review of Parleq. It describes what Parleq is, what data it handles, where that data flows, what controls are in place, and what trade-offs were made deliberately.

The intended audience is a security reviewer who needs to decide whether deploying Parleq on a managed workstation meets the organization's policy. We've tried to make every claim grep-able to a specific file in the source tree, so anything here can be verified independently.

**Last reviewed:** 2026-06-01 (v0.17.0 — refreshed to cover all five LLM providers and their auth modes, Reference Windows screen capture, persistent text-free metrics, and the expanded managed-configuration surface)
**Source:** [github.com/parleq/parleq-speech](https://github.com/parleq/parleq-speech) at v0.17.0 or later
**Review trigger / context:** [docs/SETUP.md](SETUP.md) covers end-user installation; this document covers the security model.

---

## 1. What Parleq is

Parleq is an open-source macOS dictation utility. The user holds a global hotkey (right Option), speaks, and a cleaned-up transcript appears in a floating overlay; on accept, the cleaned text pastes into whatever app was focused. Two passes:

1. **Speech-to-text (ASR):** local FluidAudio Parakeet TDT v3 inference on the Apple Neural Engine, **in-process** (no separate sidecar, no listening sockets). Audio never leaves the device.
2. **LLM cleanup:** the raw transcript goes to a configurable LLM provider — one of **Google Gemini** (direct API), **OpenAI** (direct API), **Google Vertex AI**, **AWS Bedrock**, or **Azure OpenAI** — or cleanup can be skipped entirely (paste raw ASR). Cleanup output streams into the overlay; on accept it pastes and is forgotten.

There is no server-side storage of audio or transcripts. Parleq's only persistent local state is under `~/.parleq/`: user configuration (settings + custom dictionary), a metadata-only LLM-call ledger, and a metadata-only per-dictation metrics file — none contain transcript text. Provider secrets live in the macOS Keychain.

**What changed since this packet was last reviewed (v0.9.0).** Four LLM providers were added beyond Gemini (OpenAI, Vertex AI, Bedrock, Azure OpenAI), each with its own authentication; the **Reference Windows** feature lets the user optionally attach a window's content (captured via ScreenCaptureKit) as cleanup context, which introduces a Screen Recording permission and a new outbound data class; a persistent **text-free** metrics file was added; and the managed-configuration (MDM) surface grew substantially. Each is covered below.

---

## 2. Data flow & trust boundaries

```
                          (user speech)
                                │
                                ▼
   ┌──────────────────────────────────────────────┐
   │              macOS user device               │
   │                                              │
   │   ParleqApp (single process)                 │
   │     ├── AudioRecorder ── PCM in memory ──┐   │
   │     │                                    ▼   │
   │     │                     LocalASR (in-process)
   │     │                     FluidAudio Parakeet TDT v3
   │     │                     on the Apple Neural Engine
   │     │                                    │   │
   │     ◄────────── transcript text ─────────┘   │
   │     │                                        │
   │     ▼ transcript text (+ attached reference   │
   │       window content, only if the user used   │
   │       Reference Windows this dictation)        │
   └─────┬──────────────────────────────────────────┘
         │
         │  (HTTPS; per-provider auth — API key / Bearer / SigV4 / OAuth)
         │
         ▼
   ┌────────────────────────────────────────────────────────┐
   │   configured LLM provider(s), chosen from:              │
   │     Gemini · OpenAI · Vertex AI · Bedrock · Azure OpenAI │
   │   Two tiers — a Cleanup provider/model (ordinary, non-   │
   │   reference dictations) and an optional Context provider/│
   │   model (reference-aware turns, when configured) — which │
   │   may be DIFFERENT providers, so                         │
   │   data can egress to up to two of them. (host + auth:    │
   │   see §3.2 and §6)                                       │
   └────────────────────────────────────────────────────────┘
                                              │
                                              ▼ (cleaned text)
   ┌──────────────────────────────────────────────────────┐
   │  ParleqApp overlay → user accept → paste to focused  │
   │  app (Cmd-V simulation), pasteboard restored after.  │
   └──────────────────────────────────────────────────────┘
```

**No listening sockets.** Parleq's default ASR path runs in-process. Earlier builds (≤ v0.8.x) hosted FluidAudio inside a bundled HTTP sidecar on `127.0.0.1:8767`; v0.9.0 retired that boundary. Audio buffers move between AudioRecorder and LocalASR as a Swift `Data` value within the same process — no socket, no IPC, no bearer-token negotiation between two halves of the same install. Users who explicitly configure a custom `asr.endpoint` to point at their own external server (Sherpa-ONNX, faster-whisper) opt into a localhost HTTP path; that's the only scenario in which any local socket is involved, and the server's lifecycle and auth are the user's responsibility.

### Data classifications

| Data | Where it exists | When |
|---|---|---|
| Raw audio (16 kHz mono WAV) | Process memory only | During a single dictation; freed at end of `AppState.finalizeCapture` |
| Raw ASR transcript | Process memory only | From `LocalASR.transcribe` until paste. When cleanup fails, the raw fallback *is* the accepted text and is retained in the in-memory `TranscriptHistory` for the session under the same retention controls as cleaned transcripts (§5.1). Never written to disk. |
| Cleaned transcript | Process memory + paste destination app | In overlay during accept; held in the `TranscriptHistory` ring (in memory only; **default unlimited for the session**, bounded or disabled via the retention keys — §5.1) for the rest of the session; pasted into target app |
| Reference-window captures (PNG + OCR'd text) | Process memory only | Captured via ScreenCaptureKit when the user attaches a window; sent to the LLM as part of the cleanup payload; released at end of dictation (accept/cancel). Never written to disk. |
| Provider secrets (key-based auth modes) | macOS Keychain (service `com.parleq.app`) | Persistent until user removes. Gemini / OpenAI / Azure API keys, the scoped Bedrock API key, static AWS IAM credentials, and the Vertex service-account JSON — whichever the configured provider/mode uses. |
| CLI-session credentials (SSO / ADC / Entra modes) | AWS/gcloud/az CLI caches (e.g. `~/.aws/sso/cache/`) | Per the user's existing CLI session — Parleq stores nothing and delegates refresh to the CLI. |
| User dictionary + settings | `~/.parleq/config.json` | User-authored, local-only |
| LLM-call ledger | `~/.parleq/usage.jsonl` | Token counts + provider/model + target-app bundle ID. **No transcript content.** |
| Per-dictation metrics | `~/.parleq/metrics.jsonl` | id, timestamp, audio duration, ASR/LLM latency, `hadReference` + `cleanupFailed` booleans. **No transcript text, no window labels.** Bounded retention (§5). |

### Trust boundaries

Parleq trusts:
- The user's macOS user account (process isolation, Keychain ACLs, AWS/gcloud/az CLI session-cache integrity).
- The configured LLM provider HTTPS endpoint(s) — chosen from Gemini, OpenAI, Vertex AI, Bedrock, or Azure OpenAI. Parleq has two tiers (a Cleanup provider and an optional Context provider for reference-aware turns) that may be *different* providers, so data can reach up to two of them (§3.2, §6).
- macOS system frameworks **ScreenCaptureKit** and **Vision** (used by Reference Windows to capture + OCR a window the user explicitly picks; only exercised when that feature is used).
- LiteLLM's community pricing JSON (`raw.githubusercontent.com/BerriAI/litellm/...`) — used for cost reporting only; not load-bearing for any user-facing functionality. **Disable-able via the `livePricingEnabled: false` MDM key (fleet-wide) or the `PARLEQ_DISABLE_LIVE_PRICING=1` env var (single user).**
- The FluidAudio model artifacts in `~/Library/Application Support/FluidAudio/Models/` (downloaded by FluidAudio's own loader from `huggingface.co` on first run; their integrity is FluidAudio's responsibility, not Parleq's).

Parleq does **not** trust:
- Other processes on the user's device (Keychain is per-app via service identifier; no listening sockets to attack in the first place — see §3.1).
- Network attackers between the user and the configured provider (HTTPS via the system trust store; no certificate pinning, but no plaintext fallback either).
- The user's own custom `asr.endpoint` setting if set (no shared secret with external servers; user manages their own server's auth). On managed Macs this setting can be pinned via MDM so a user cannot redirect audio to an arbitrary endpoint (§9.6).

---

## 3. Authentication & authorization

### 3.1 No listening sockets on the default ASR path

Parleq's bundled ASR path has no network exposure of any kind. `LocalASR` calls FluidAudio's `AsrManager.transcribe(_:decoderState:)` in-process; the audio buffer is a Swift `Data` value that never crosses a process or socket boundary.

This replaces the bearer-token-authed `127.0.0.1:8767` HTTP sidecar that earlier builds (≤ v0.8.x) used. The sidecar's bearer token was generated fresh per launch and required on every `POST /inference`, which adequately protected the local endpoint from other processes on the same machine — but v0.9.0 dropped the boundary entirely on the principle that the strongest "no other process can submit audio against the user's loaded models" guarantee is no listening socket to send audio to.

**The only scenario in which a local socket is involved at all** is when the user explicitly sets `asr.endpoint` in `~/.parleq/config.json` to a non-default value. In that case ASRClient POSTs WAV bytes to whatever URL the user configured (typically a Sherpa-ONNX or faster-whisper server they're running locally). Parleq sends no Authorization header on that path — there's no shared secret to use — and the server's lifecycle, bind address, and access control are entirely the user's responsibility. The bundled in-process FluidAudio engine is then never initialized, so its model isn't loaded and its memory isn't paid for.

### 3.2 LLM provider authentication

Five providers are supported. The user configures up to **two tiers**: a **Cleanup** tier (used for ordinary, non-reference dictations) and an optional **Context** tier (used for reference-aware turns when a window/file/clipboard is attached — *if* a Context provider/model is set; otherwise those turns fall back to the Cleanup tier). Each tier has its own provider + model, so they can be two *different* providers, and transcript/reference content may therefore egress to up to two of them. On managed Macs both tiers' provider + allowed models + auth mode can be pinned via MDM (§6, §9.7). Each provider authenticates differently:

- **Gemini direct API:** API key sent as the `x-goog-api-key` HTTP **header** on every request (Google also accepts a `?key=…` query param; we use the header so the key never appears in a URL string that framework logging could capture). Resolved per-request from env (`GEMINI_API_KEY`) → Keychain (§4.1) — no plaintext-on-disk fallback.
- **OpenAI direct API:** API key sent as `Authorization: Bearer <key>`, stored in the Keychain (account `openai-api-key`) and resolved from the Keychain only — no env fallback. Endpoint `api.openai.com`.
- **Google Vertex AI:** two auth modes. **gcloud ADC** — shells out to the user's `gcloud` for a short-lived OAuth token (no secret stored by Parleq). **Service-account JSON** — the SA key JSON is stored in the Keychain (account `vertex-service-account-json`) and Parleq mints OAuth tokens itself via JWT-bearer/RS256 against `oauth2.googleapis.com/token`. Endpoint `{region}-aiplatform.googleapis.com`.
- **AWS Bedrock:** three auth modes (`aws.auth_mode`). **`sso`** (a slight misnomer — it hands Soto a credential *chain*, not SSO-only) — Parleq stores no AWS secret; with a profile set (Settings or `AWS_PROFILE`) Soto resolves, in order, **environment AWS credentials** (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`) → the named `~/.aws/config` profile → the SSO cache at `~/.aws/sso/cache/`; with no profile, Soto's **default credential chain** runs (§4.2). **`static`** — static IAM access keys, stored **in the Keychain** (account `aws-static-credentials`, JSON-encoded). **`bedrockApiKey`** — a scoped Bedrock API key stored in the Keychain (account `bedrock-api-key`), sent as `Authorization: Bearer <key>` over plain HTTPS by `BedrockBearerProvider`, bypassing Soto entirely. (This supersedes the earlier "#21 not yet supported / Parleq never stores AWS credentials" note — static and bearer-key auth have since shipped and *do* persist credentials in the Keychain. See §4.2.)
- **Azure OpenAI:** two auth modes (`azure.auth_mode`). **`apiKey`** — the resource key sent as the `api-key:` header, stored in the Keychain (account `azure-openai-key`). **Microsoft Entra ID** — shells out to `az` for a token (no secret stored by Parleq). Endpoint `{resource}.openai.azure.com`.

In every key-based mode the secret lives only in the macOS Keychain (service `com.parleq.app`) — never in a Parleq-owned file on disk. In the non-Keychain modes Parleq stores nothing: Bedrock `sso` delegates to Soto's credential chain (reading `~/.aws` config + SSO cache + env directly), while Vertex ADC and Azure Entra shell out to `gcloud`/`az` for short-lived tokens. An MDM key (`staticApiKeysAllowed: false`) can forbid the key-based modes fleet-wide, forcing CLI-session auth.

### 3.3 Macros / Login Items

The user's hotkey requires the **Accessibility** TCC grant (CGEventTap-based listener). **Microphone** TCC is required for AVAudioEngine input. **Screen Recording** TCC is required *only* for the optional Reference Windows feature (ScreenCaptureKit window capture) — it is requested lazily the first time the user attaches a window, never at startup, and the rest of the app works without it. No app-sandbox; Hardened Runtime entitlements are minimal: `audio-input`, `network.client`, `network.server`, `cs.allow-jit` (for CoreML JIT). See `parleq-app/Resources/Parleq.entitlements`. (Microphone, Accessibility, and Screen Recording are TCC permissions, not Hardened Runtime entitlements, so they don't appear in that file — verify them in System Settings → Privacy & Security.)

**Implication:** the Accessibility grant gives Parleq the technical ability to read all keystrokes globally. The actual code uses CGEventTap only for the right-Option press-and-hold detection, but a reviewer should treat this as "Parleq is a privileged process on this machine" and weigh the source code accordingly. Mitigation: open-source code audit, Apple notarization, stable bundle-ID + signature so TCC grants don't silently transfer to a tampered build.

---

## 4. Secrets management

### 4.1 Provider secrets in the Keychain

Every key-based provider secret lives in the macOS Keychain under service `com.parleq.app`, class `kSecClassGenericPassword`, accessibility `kSecAttrAccessibleAfterFirstUnlock`. The Settings UI is the only writer (`KeychainStore.swift`); secrets are never displayed in plaintext after save and never written to a Parleq-owned file:

| Keychain account | Secret | Used by |
|---|---|---|
| `gemini-api-key` | Google AI API key | Gemini direct |
| `openai-api-key` | OpenAI API key | OpenAI direct |
| `azure-openai-key` | Azure resource key | Azure OpenAI (`apiKey` mode) |
| `bedrock-api-key` | Scoped Bedrock API key | Bedrock (`bedrockApiKey` mode) |
| `aws-static-credentials` | Static IAM access key + secret (JSON) | Bedrock (`static` mode) |
| `vertex-service-account-json` | GCP service-account key JSON | Vertex AI (`serviceAccount` mode) |

The non-Keychain auth modes also store **nothing**, but they obtain credentials differently: **Bedrock `sso`** delegates to Soto's credential chain, which reads `~/.aws/config`, the SSO cache, and environment AWS credentials **directly** (no AWS-CLI process is invoked — see §4.2); **Vertex gcloud ADC** and **Azure Entra** shell out to the user's `gcloud` / `az` CLI for short-lived tokens.

**Resolution order.** Only Gemini has a key-bearing environment variable: `LLMClient.resolveAPIKey()` checks `GEMINI_API_KEY` first (CI / `swift run` / dotfiles), then the Keychain. Every other key-based provider — OpenAI, Azure, the Bedrock API key, the Vertex service-account JSON — resolves **only** from the Keychain; there is no env fallback for them. (Bedrock's `sso` mode is the exception to "Keychain only" — it delegates to Soto's AWS credential **chain**, which can resolve environment AWS credentials, a `~/.aws/config` profile, or the SSO cache; see §4.2 for the order. Parleq still persists nothing in that mode. The AWS region comes from Parleq's configured region, not an env var.) There is **no plaintext-on-disk fallback** for any provider — if no secret resolves in a key-based mode, LLM cleanup is disabled and Parleq pastes the raw ASR transcript.

### 4.2 AWS / Bedrock credentials

Bedrock has three auth modes (`aws.auth_mode`); what Parleq stores depends on the mode:

- **`sso` (default):** Parleq stores **nothing** — it hands Soto a credential **chain** (the mode name is a slight misnomer; it is not SSO-only). With a profile set (the Settings field, or the `AWS_PROFILE` env var when the field is empty), Soto's selector tries, in order: **environment AWS credentials** (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`), then the named `~/.aws/config` profile, then the SSO cache (`~/.aws/sso/cache/<sha1>.json`, refreshed against `oidc.<region>.amazonaws.com` / `portal.sso.<region>.amazonaws.com`). With **no** profile, Soto's **default credential chain** runs (which also includes environment, config, and SSO sources). Whatever the source, the credentials are user-/environment-provided and live only in Soto's in-memory rotating cache — never persisted by Parleq. So a reviewer evaluating "what can authenticate in `sso` mode" should account for standard AWS env credentials, not just the SSO cache.
- **`static`:** the user's static IAM access key + secret are stored **in the macOS Keychain** (account `aws-static-credentials`, JSON-encoded) and handed to Soto as static credentials — not read from `~/.aws/credentials`.
- **`bedrockApiKey`:** a scoped Bedrock API key is stored in the Keychain (account `bedrock-api-key`) and sent as `Authorization: Bearer <key>` over plain HTTPS by `BedrockBearerProvider`, bypassing Soto.

> **Correction vs. the v0.9.0 packet.** Earlier revisions said "Parleq does not store AWS credentials of any kind" and that static / Bedrock-API-key auth was "not currently consumed (tracked in #21)." That work shipped: in `static` and `bedrockApiKey` modes Parleq **does** persist credentials — in the Keychain, never in a Parleq-owned file on disk. The `sso` mode remains zero-storage.

MDM can pin the Bedrock auth mode (`bedrockAuthMode`) and forbid key-based modes fleet-wide (`staticApiKeysAllowed: false`).

### 4.3 ASR auth tokens

None. The bundled ASR path runs in-process and has no auth surface (§3.1). The optional external `asr.endpoint` path sends no Authorization header — the user-run server's auth is the user's responsibility.

---

## 5. Local persistence

Parleq writes the following files. Audited against the enterprise rule "no input data on local computer":

| Path | Content | Compliance note |
|---|---|---|
| `~/.parleq/config.json` | Settings: hotkey, dictionary terms, AWS profile name, model selection, etc. | User-authored config. No transcripts, no audio, no API keys. |
| `~/.parleq/usage.jsonl` | One JSON line per LLM call: timestamp, kind (cleanup/refine), provider, model, input/output token counts, latency, target-app bundle ID. | **Metadata only.** No transcript or cleanup-output content. |
| `~/.parleq/metrics.jsonl` | One JSON line per dictation (`MetricsRecord`): id, timestamp, audio duration, ASR latency, LLM latency, `hadReference` boolean, `cleanupFailed` boolean. Feeds the cross-session Stats dashboard. | **Metadata only — no transcript text, no window labels, no app names.** The on-disk file is **hard-bounded to a fixed 30-day horizon regardless of config** (`persistedRetentionDays = 30`; the Stats view renders only 7 days). `transcriptHistoryRetentionHours` additionally age-prunes persisted records when set; `transcriptHistoryMaxEntries` caps only the in-memory *text* history, **not** these metrics. Setting **either** key to 0 disables history entirely — metrics are cleared and not persisted (the zero-retention lever for compliance fleets). Default: unlimited in memory, 30 days on disk. |
| `~/.parleq/pricing-cache.json` | LiteLLM JSON snapshot (public reference data). | Not user data. Disable-able via `PARLEQ_DISABLE_LIVE_PRICING=1`. |
| `~/.parleq/app.log` | Stderr-redirected diagnostics: phase transitions, ASR latency + length, LLM token counts, model-load progress, error stack traces. Capped at 10 MB; truncates to last 5 MB on launch when over the cap. | **No transcript content, no audio, no auth values.** Same redaction discipline as the rest of the codebase. Skipped in dev mode (when stderr is a TTY). |
| `~/Library/Application Support/FluidAudio/Models/` | Downloaded Parakeet TDT v3 + CTC vocab encoder model weights. | Public model artifacts, not user data. |

**Explicitly NOT written to disk:**
- Audio bytes (WAV or PCM). `AudioRecorder.stop()` returns `Data` in memory; the bundled `LocalASR` decodes that buffer to Float samples in-process and hands them to FluidAudio without touching the filesystem. When the user has configured a custom `asr.endpoint`, `ASRClient` POSTs via `request.httpBody` (in-memory), not `httpBodyStream` (potentially file-backed).
- Transcript text. `AppState`'s ASR diagnostic logs `(N chars / W words)` — length only.
- Cleanup output text **on disk**. Held in process memory only — first in the overlay during cleanup, then in the `TranscriptHistory` ring buffer (see § 5.1 below) for the rest of the session, then gone on app quit. Never serialized to a file.
- Reference-window captures. PNG screenshots + OCR'd text from Reference Windows (and any attached file/clipboard content) live in process memory for the duration of one dictation and are released on accept/cancel — never written to disk, never cached between sessions.

This was explicitly verified after a full source sweep on 2026-05-06 (see git history for commits `631f6e0` and `6d64646`).

### 5.1 In-memory transcript history (Recent Dictations)

The Parleq window's **Recent Dictations** section surfaces recent accepted transcripts so the user can grab one back if a paste lands somewhere unexpected (focus changed mid-flight, target app rejected the paste, etc.). Implementation: `TranscriptHistory.swift`, an `@MainActor` ring of `TranscriptEntry` structs (UUID, timestamp, transcript text, original target-app name, reference labels, and a `wasCleanupSuccessful` boolean). Entries whose cleanup failed carry the raw ASR transcript that Parleq actually pasted — the same text the user accepted — with the boolean false so the list can mark them ` · raw`. Successful entries carry the cleaned text with the boolean true. From a compliance standpoint the data classification is identical either way (in-memory transcript text the user just dictated); the boolean is a display hint, not a security boundary.

**Compliance posture:**
- **Process memory only.** The buffer is held in a singleton `@MainActor` class; never serialized to disk, never sent over the network. Deleted when the process exits — a `Quit Parleq` from the menu bar wipes the entire history.
- **No new persistence surface.** The transcript text (cleaned or raw fallback) was already in process memory while the overlay was open during cleanup. We hold it for the remainder of the session (default unlimited; bounded or disabled via the retention keys below) instead of dropping it the moment the user pastes. From the policy's perspective, the data classification of "transcript the user just dictated" is unchanged — it's still in-memory state, just held longer.
- **Configurable retention; can be fully disabled.** The session text history is **unlimited by default** (the old hardcoded 20-entry cap was removed when Recent Dictations moved into the Parleq window). Two keys bound it — `transcriptHistoryMaxEntries` (count) and `transcriptHistoryRetentionHours` (age) — settable per-user or pinned fleet-wide via MDM. **Setting either to `0` disables history entirely** — both the text ring *and* the persisted metrics (§5) — the zero-retention lever for compliance fleets. The user can also wipe everything on demand via **Clear all dictation history** in the section, or quit to drop the in-memory state.
- **App/destination labels — sent only on reference-aware turns.** The destination app name (e.g. "iTerm2") is captured for display in the Recent Dictations list. It is **not** sent anywhere for ordinary (no-reference) dictations. On a *reference-aware* dictation, `PromptBuilder` does include it (a `Destination:` line) plus each attached reference's app name and sanitized window title in the LLM prompt, so cleanup can match tone/context (§6, §9.6). None of these labels are ever written to disk.

**Click-to-clipboard handler.** When the user clicks a recent entry, the full text is written to the system pasteboard via `NSPasteboard.general.setString(...)`. The pasteboard is a system-level shared resource — once a text value lands there, any process running as the same user can read it via the standard pasteboard APIs. This is the same posture as any user-initiated copy; nothing Parleq-specific. Users on shared machines or with paranoid threat models can avoid the click-to-copy path entirely (the entries remain visible in the menu without copying).

**Threat model.** Memory dumps of a running Parleq process would surface the buffer; this is the same exposure as any in-flight cleaned text (the overlay's `currentText`, the LLM's response stream buffer, etc.). Anyone with the privilege to dump Parleq's memory already has the privilege to dump any process running as the same user, so this is not a new attack surface — it's the existing one with a slightly larger value at risk (the session's retained dictations — default unlimited, bounded/disable-able via the retention keys — vs. just the current one).

**Verification:** `grep -rn "TranscriptHistory" parleq-app/Sources/` shows the singleton exists at `TranscriptHistory.swift`, is read by `RecentDictationsView.swift` (the Parleq window's Recent Dictations list — the old menu-bar submenu is gone), and is written once per accepted dictation via the shared `appendTranscriptHistory` helper — on both accept paths: `AppState.accept()` (normal review) and the quick-mode auto-paste path in `applyResult`. The text-bearing `TranscriptEntry` is **not** `Codable` and has no `write(to:)` path — the transcript text cannot reach disk through the type. The *only* persisted state is the separate, **text-free** `MetricsRecord` → `metrics.jsonl` (§5), which carries no transcript or labels. The `wasCleanupSuccessful` boolean is set from a `lastCleanupFailed` flag that AppState tracks across the `applyResult → accept` handoff, and is reset by `startFreshCapture` and `closeAndReset` so a prior dictation's failure never leaks into a later entry.

---

## 6. Network egress

All network calls are HTTPS via URLSession or Soto, both using the system trust store. No HTTP fallbacks anywhere in the codebase.

| Destination | Purpose | Frequency | Disable? |
|---|---|---|---|
| `generativelanguage.googleapis.com` | Gemini cleanup (provider=gemini) | Per dictation | Switch provider / skip cleanup |
| `api.openai.com` | OpenAI cleanup (provider=openai) | Per dictation | Switch provider / skip cleanup |
| `{region}-aiplatform.googleapis.com` | Vertex AI cleanup (provider=vertex) | Per dictation | Switch provider / skip cleanup |
| `bedrock-runtime.<region>.amazonaws.com` | Bedrock cleanup (provider=bedrock) | Per dictation | Switch provider / skip cleanup |
| `{resource}.openai.azure.com` | Azure OpenAI cleanup (provider=azure) | Per dictation | Switch provider / skip cleanup |
| `oidc.<region>.amazonaws.com`, `portal.sso.<region>.amazonaws.com` | AWS SSO token refresh (Bedrock `sso` mode) | Periodic, near token expiry | N/A (managed by Soto) |
| `oauth2.googleapis.com` | Vertex service-account OAuth token mint (`serviceAccount` mode) | Periodic, token refresh | Use gcloud ADC mode |
| `login.microsoftonline.com` | Azure Entra ID token (Entra mode, via `az`) | Periodic, token refresh | Use `apiKey` mode |
| `raw.githubusercontent.com/BerriAI/litellm/...` | LiteLLM pricing JSON | Once per 24 h, on launch | MDM `livePricingEnabled: false` (fleet) or `PARLEQ_DISABLE_LIVE_PRICING=1` (single user) |
| `huggingface.co` (FluidAudio's loader) | First-run model download (Parakeet TDT v3 ≈ 150 MB; CTC encoder ≈ 97 MB if custom dictionary used) | Once per machine, then cached at `~/Library/Application Support/FluidAudio/Models/` | N/A — bundled ASR requires the models. Switch to a custom `asr.endpoint` to skip. |
| `parleq.app/appcast.xml` | Sparkle auto-update check | On app launch + every 24 h (default; configurable) | Settings → Updates → "Automatically check for updates" off. The menu-bar "Check for Updates…" item still hits the URL on demand. |
| `github.com/parleq/parleq-speech/releases/download/...` | Downloads the .dmg referenced by the appcast, when the user accepts an update prompt | Per update install (user-initiated) | Don't accept the prompt; the request never fires. |

**Outbound data classifications:**
- Transcript text → the configured **Cleanup** provider for ordinary dictations. A reference-aware dictation's transcript + reference content goes to the **Context** provider/model instead when one is configured (otherwise it also uses the Cleanup provider) — so over time data can reach both configured providers (§3.2).
- Attached reference content (OCR'd window/file/clipboard text, or a PNG when a vision model is selected) → the **Context** provider when one is configured, else the Cleanup provider — **only** when the user used Reference Windows for that dictation (§9.6).
- Reference-aware prompts also carry lightweight **labels** built by `PromptBuilder`: a `Destination: <app>` line (the paste-target app name) and, per attached reference, a `Reference N — <app> — <sanitized window title>` line. So the target app name and the attached windows' app names + (sanitized) titles reach the LLM on reference-aware dictations. **Ordinary (no-reference) cleanup sends none of this** — just the transcript (+ dictionary hint).
- Request metadata (model ID, region/resource, token-shaped JSON body) → the provider.
- Provider auth travels in headers, never in a URL: `x-goog-api-key` (Gemini), `Authorization: Bearer` (OpenAI; Bedrock `bedrockApiKey` mode), `api-key` (Azure `apiKey` mode), SigV4 signature (Bedrock `sso`/`static`), OAuth bearer (Vertex; Azure Entra).
- Sparkle's update check sends a User-Agent including the app version + macOS version; no other identifying information. The appcast response is a static XML file; Sparkle verifies each enclosure's Ed25519 signature against the `SUPublicEDKey` baked into Info.plist before installing.
- No telemetry, no analytics, no crash reporting to any Parleq-controlled server. Parleq itself has no backend.

---

## 7. Dependencies & supply chain

| Dependency | Use | Pin | Source |
|---|---|---|---|
| Soto (`SotoBedrockRuntime`) | AWS SigV4, ConverseStream, SSO credential resolution | `"7.14.0"..<"7.15.0"` | `soto-project/soto` |
| FluidAudio | In-process ASR (Parakeet TDT v3) + CTC custom-vocab boosting | `"0.14.3"..<"0.15.0"` | `FluidInference/FluidAudio` |
| Sparkle | Auto-update framework (Ed25519-signed appcast → download → relaunch). Open-source, the de-facto standard for third-party Mac auto-updates, widely deployed across the ecosystem. | `"2.9.0"..<"2.10.0"` | `sparkle-project/Sparkle` |
| swift-nio, swift-crypto, swift-certificates | Transitive | (Soto / FluidAudio deps) | Apple |

`Package.resolved` is **committed** to the repository — fresh clones build against the exact dependency graph we tested. Bumping a dependency requires an explicit `swift package update` + reviewable commit diff. See [CLAUDE.md § Dependency upgrade policy](../CLAUDE.md) for the periodic-upgrade ritual.

There is no longer a separate sidecar `Package.swift` to track. The retired sidecar package's only direct deps (Hummingbird, FluidAudio) collapsed into the main app target as part of v0.9.0 — Hummingbird is gone, FluidAudio is pinned above.

---

## 7a. Auto-update

Parleq uses Sparkle for auto-updates. The end-user experience is the standard "an update is available" prompt familiar from most Mac apps. Two parts to the security posture:

### Where the public/private key pair lives

- The **public** Ed25519 key is baked into every Parleq build as `SUPublicEDKey` in `Info.plist`. Anyone can read it from any installed Parleq.app, and that's the design — Sparkle on every user's machine uses it to verify each downloaded .dmg's signature before installing.
- The **private** Ed25519 key lives only in the maintainer's macOS Keychain (where Sparkle's `generate_keys` tool placed it) and a backup in the maintainer's password manager. It never enters the repository, never appears in any built artifact, and never travels off the maintainer's machine. `sign_update` finds it via the Keychain lookup at release time.
- **If the private key is lost**, Parleq can no longer issue updates to existing installs (Sparkle refuses anything signed by a different key). Users would need to manually download a new build from a new public key. The maintainer treats the backup the same way as the notarization Apple ID + app-specific password.

### What gets checked at each update

1. Sparkle GETs `https://parleq.app/appcast.xml` over HTTPS using the system trust store.
2. If the appcast's latest `<item>` describes a newer version than the running build, Sparkle prompts the user. **No download happens without user consent.**
3. On user accept, Sparkle downloads the .dmg from the `<enclosure url="...">` URL (typically `github.com/parleq/parleq-speech/releases/download/v.../...dmg`).
4. Sparkle verifies the downloaded bytes match the `<enclosure length="...">` byte count and that the Ed25519 signature in `<enclosure sparkle:edSignature="...">` verifies against the build's compiled-in `SUPublicEDKey`. **Mismatch → refused.** Any attacker who tampers with the appcast XML, swaps out the .dmg, or MITMs the download cannot push an arbitrary binary because they don't have the private key.
5. Sparkle's installer relaunches Parleq.

### Outbound information on update checks

Sparkle sends a User-Agent string containing the app version and macOS version with each check. No other identifying information — no UUID, no install ID, no telemetry payload. The appcast response is a static XML file; the server doesn't log Parleq specifically.

### User control

- **Settings → Updates** has an "Automatically check for updates" toggle (writes to UserDefaults' `SUEnableAutomaticChecks` key; Sparkle reads from there). Disable to suppress the periodic background check.
- The menu-bar **"Check for Updates…"** item triggers an on-demand check regardless of the toggle.
- An installed Parleq that opts out of automatic checks still verifies every update's Ed25519 signature when the user runs a manual check — the verification is unconditional, the network call timing is what the toggle gates.

### Failure modes

- **parleq.app unreachable.** Sparkle silently skips the check; no error surfaced to the user. The next successful check resumes normal operation.
- **Appcast malformed.** Sparkle logs a warning to Console.app and skips the check. The app continues running.
- **Signature verification fails.** Sparkle refuses the download and shows a clear error dialog. The running app continues to work; no rollback needed because the .app bundle is unchanged.

### Implementation references

- `parleq-app/Sources/parleq-app/main.swift` — `SPUStandardUpdaterController` instantiation.
- `parleq-app/Sources/ParleqAppCore/UpdatesView.swift` — Settings → Updates pane.
- `parleq-app/Resources/Info.plist` — `SUFeedURL` + `SUPublicEDKey`.
- `web/public/appcast.xml` — the feed itself, regenerated by `make release` per release.
- `Makefile` — `release` recipe runs `sign_update` against each .dmg + inserts the corresponding `<item>` into the appcast.

---

## 8. Audit findings & remediations (2026-05-06 internal audit)

The following items were identified during an internal security audit and have been addressed in commit `6d64646`:

| # | Item | Severity | Status |
|---|---|---|---|
| 1 | Sidecar `/inference` had no authentication; any local process could submit audio. | HIGH | **OBSOLETE** — first remediated in 2026-05-06 (`6d64646`) with bearer-token auth, then dropped entirely in v0.9.0 by retiring the sidecar boundary (§3.1). No listening socket means nothing to authenticate. |
| 2 | Gemini API key resolved from a plaintext-on-disk fallback path. | HIGH | **FIXED** — Keychain is the only on-disk store; the plaintext fallback was removed entirely (§4.1). Closes [#18](https://github.com/parleq/parleq-speech/issues/18). |
| 3 | Soto package pinned `from: "7.0.0"` allowed any 7.x at resolve time. | MEDIUM | **FIXED** — pinned to `"7.14.0"..<"7.15.0"`, `Package.resolved` committed (§7). |
| 4 | LiteLLM JSON download was not user-controllable. | MEDIUM | **FIXED** — `PARLEQ_DISABLE_LIVE_PRICING=1` env var (§6), plus the `livePricingEnabled: false` MDM key for fleet-wide control (added 0.15.0). |
| 5 | Accessibility entitlement = full keystroke read capability. | MEDIUM | **DOCUMENTED** (§3.3). No technical fix possible without losing the global hotkey feature. Mitigated by code transparency, notarization, and stable bundle ID. |
| 6 | `usage.jsonl` records target-app bundle IDs (user behavior metadata). | LOW | **DOCUMENTED** (§5). Not transcript content. Optional config knob to suppress can be added on request. |

**Changes since this audit (v0.9.0 → v0.17.0).** Four more LLM providers shipped, each authenticated as in §3.2 with key-based secrets confined to the Keychain (§4.1); the multi-mode AWS auth previously tracked as #21 landed (correction in §4.2). Reference Windows added a Screen Recording permission and a new outbound data class (§3.3, §9.6). The only new persistent file, `metrics.jsonl`, is metadata-only (§5) — no new on-disk store of transcript content was introduced. These post-date the 2026-05-06 audit and have not had a dedicated audit pass of their own; they are documented here for reviewer awareness.

---

## 9. Known limitations & accepted risks

### 9.1 Cleanup payload sent to LLM provider

When LLM cleanup is enabled (default), the **raw transcript text** (plus any attached reference content — §9.6) is sent to a configured LLM provider as part of the cleanup request. This is intentional — it's the entire point of the cleanup pass — but it means transcript content crosses an organizational boundary. **Both tiers matter:** ordinary dictations go to the **Cleanup** provider, and reference-aware dictations go to the **Context** provider when one is configured (otherwise the Cleanup provider) — so **both configured providers must satisfy your data-residency policy**, not just one. Mitigation: choose providers that match it — Gemini = Google; OpenAI = OpenAI; Vertex AI = Google but in *your* GCP project (IAM + audit logs); Bedrock = your own AWS account; Azure OpenAI = your Microsoft tenant — and on managed Macs pin **both** tiers fleet-wide via MDM (§9.7).

If transcript content must never leave the device, you must turn off **both** LLM tiers — they are independent:

1. **Cleanup tier:** choose **"None — skip cleanup, paste raw ASR"** in the **Setup wizard** (menu bar → **Run Setup…**, re-runnable any time), set `llm.provider = "none"` in `~/.parleq/config.json`, or pin `cleanupProvider` off via MDM. (The in-app **Settings** picker does *not* list None — it's a setup-wizard / config / MDM action.) This stops *ordinary* dictations from making any LLM call.
2. **Context tier:** if a `context_model` is still configured, a *reference-aware* dictation (one where the user attached a window/file/clipboard) routes to that Context provider **even when cleanup is `none`** (`Config.modelForInvocation` resolves the Context tier independently). To close this, also clear `context_model` (config) / pin `contextProvider` to `none` (MDM), **or** disable Reference Windows (`referenceWindowsEnabled: false`).

Two traps: (a) merely *not configuring an API key* is **not** sufficient — the federated auth modes (Bedrock SSO, Vertex ADC, Azure Entra) need no key yet still egress; (b) disabling only Cleanup still leaves reference-aware turns egressing if a Context tier remains. The dependable no-egress posture is **cleanup = none AND a neutralized Context tier** (or Reference Windows off).

### 9.2 Accessibility permission scope

CGEventTap requires the broadest macOS keystroke-monitoring permission. Parleq uses it only for hotkey detection, but the operating system can't enforce that scope. A compromised Parleq build would have the technical ability to log all keystrokes. Mitigations: open-source code, Apple notarization, stable Developer ID, and (for managed environments) MDM policies that track which apps have Accessibility granted.

### 9.3 LiteLLM pricing JSON as third-party trust boundary

We trust an external GitHub-hosted JSON file for accurate model pricing. The worst case if the upstream is compromised is incorrect cost reporting in the Settings UI; we don't enforce any spending limits, so cost lies don't translate to real harm. The fetch also exposes the user's IP and launch cadence to GitHub/Fastly. Disable fleet-wide with the `livePricingEnabled: false` MDM key (recommended for locked-down or air-gapped deployments), or per-user with `PARLEQ_DISABLE_LIVE_PRICING=1`, if even this trust/exposure is too much; the bundled price table then serves.

### 9.4 No audit trail of dictations

Parleq does not log a per-dictation audit record beyond token counts. Organizations that need a per-dictation log for compliance review would need to build that themselves, or do it at the LLM-provider boundary (e.g., AWS CloudTrail records every Bedrock invocation; Google Cloud's API logs do similarly for Gemini).

### 9.5 No certificate pinning

We rely on the system trust store for TLS validation. If your security policy requires pinned certificates for outbound connections, that's a feature request — not currently implemented.

### 9.6 Reference Windows captures sent to the LLM

When the user attaches a window (or file / clipboard) as context, that content — OCR'd text via Vision, or a full-resolution PNG when a vision-capable model is selected — is sent alongside the transcript to the **Context** provider/model when one is configured (otherwise the Cleanup provider — §3.2, §9.1). It is opt-in per dictation and never persisted (§2, §5), but it means on-screen content the user points at crosses a provider boundary — so the **Context** provider must also satisfy your data-residency policy. The feature requires the Screen Recording TCC grant (§3.3). The feature and each sub-capability can be disabled fleet-wide via MDM (`referenceWindowsEnabled`, `imageReferenceEnabled`, `clipboardReferenceEnabled`, `fileReferenceEnabled`); when the parent key is off, Parleq never requests Screen Recording and the window picker is unavailable.

### 9.7 Destination pinning on managed Macs

Beyond enabling/disabling features, managed configuration can pin *where data goes* so a user can't redirect it to a personal account: cleanup/context provider, allowed providers + models (`cleanupProvider`, `cleanupAllowedProviders`, `cleanupModel`, `contextProvider`, …), auth mode (`bedrockAuthMode`, `azureAuthMode`, `staticApiKeysAllowed`), the Sparkle update feed URL, logging mode, transcript-history retention, and the **ASR endpoint** (pinning it closes the "point dictation audio at an arbitrary server" gap within an otherwise-allowed config). The authoritative key set lives in `ManagedConfig.swift`; the public reference is [parleq.app/docs/managed-configuration](https://parleq.app/docs/managed-configuration/).

---

## 10. Where to look in source

For reviewers who want to verify the claims above against code:

| Concern | File(s) |
|---|---|
| Audio in memory only | `parleq-app/Sources/ParleqAppCore/AudioRecorder.swift`, `LocalASR.swift`, `ASRClient.swift` |
| No listening sockets on the default path | `parleq-app/Sources/ParleqAppCore/LocalASR.swift` (FluidAudio called as a Swift function, not over HTTP); confirm with `lsof -i -nP -a -p <pid>` on a running Parleq (the `-a` flag is required — without it, lsof ORs the filters instead of ANDing) |
| Provider secrets in the Keychain (all six accounts) | `parleq-app/Sources/ParleqAppCore/KeychainStore.swift` |
| Per-provider auth + endpoints | `LLMClient.swift`/`LLMStreaming.swift` (Gemini), `OpenAIProvider.swift`, `VertexProvider.swift` + `VertexServiceAccount.swift`, `BedrockProvider.swift` + `BedrockBearerProvider.swift`, `AzureOpenAIProvider.swift` — all under `parleq-app/Sources/ParleqAppCore/` |
| Screen Recording permission + window capture/OCR | `parleq-app/Sources/ParleqAppCore/Permissions.swift`, `ReferenceCapture.swift` |
| Managed-configuration (MDM) keys | `parleq-app/Sources/ParleqAppCore/ManagedConfig.swift` |
| Per-dictation metrics file (text-free) | `parleq-app/Sources/ParleqAppCore/TranscriptHistory.swift` (`persistMetrics`, `MetricsRecord`) |
| Length-only ASR diagnostic | `parleq-app/Sources/ParleqAppCore/AppState.swift` (search "ASR batch") |
| Count-only vocab log | `parleq-app/Sources/ParleqAppCore/LocalASR.swift` (search "[vocab]") |
| Usage ledger schema (metadata-only) | `parleq-app/Sources/ParleqAppCore/UsageLedger.swift` |
| Hardened Runtime entitlements | `parleq-app/Resources/Parleq.entitlements` |
| Recent Dictations in-memory history | `parleq-app/Sources/ParleqAppCore/TranscriptHistory.swift`, `RecentDictationsView.swift` (the Parleq window's list) |
| `Package.resolved` (pinned versions) | `parleq-app/Package.resolved` |
| LiteLLM disable knob | `parleq-app/Sources/ParleqAppCore/PricingCache.swift` (search "PARLEQ_DISABLE_LIVE_PRICING") |
| Code-signing flow | `parleq-app/scripts/make-app.sh` |

---

## 11. Reviewer cheat sheet

If you have 15 minutes, verify the high-impact claims by running these from a checkout of the repo:

```bash
# 1. Confirm there is no longer a sidecar package or supervisor.
test ! -d third_party/fluidaudio-sidecar && echo "OK: sidecar package removed"
test ! -f parleq-app/Sources/ParleqAppCore/SidecarSupervisor.swift && echo "OK: supervisor removed"

# 2. Confirm no listening sockets are bound by a running Parleq.
#    (Launch /Applications/Parleq.app first; replace the pgrep target
#    with `pidof ParleqApp` if pgrep doesn't match. The -a flag ANDs
#    the -i and -p filters together — without it, lsof ORs them and
#    you'll see every listening socket on the machine, not just the
#    ones owned by Parleq.)
lsof -i -nP -a -p "$(pgrep -n ParleqApp)" | grep LISTEN || echo "OK: no LISTEN sockets"

# 3. Confirm no /tmp/parleq-*.wav writes (audio in memory).
grep -rn "/tmp/parleq-" parleq-app/Sources/

# 4. Confirm transcript text is never logged.
grep -rn "asrResultRaw.text\|asrResult.text" parleq-app/Sources/ \
  | grep -E "log|stderr|FileHandle"

# 5. Confirm the entitlements set is minimal.
cat parleq-app/Resources/Parleq.entitlements

# 6. Confirm dependency versions are pinned.
test -f parleq-app/Package.resolved && echo "Package.resolved tracked"

# 7. Confirm Keychain helper exists.
grep -l "SecItemAdd\|kSecClassGenericPassword" parleq-app/Sources/

# 8. Confirm usage ledger is metadata-only.
head -3 ~/.parleq/usage.jsonl 2>/dev/null | jq
```

For the operational side (AWS account configuration, Identity Center, Bedrock model access), see [`docs/SETUP.md`](SETUP.md). For the public-facing architecture walkthrough, see [parleq.app/how-it-works](https://parleq.app/how-it-works/).

---

## Appendix: change log relevant to security posture

- **2026-06-01** (v0.17.0): security-review refresh — documented all five LLM providers + their auth modes, Reference Windows screen capture, the text-free `metrics.jsonl`, and the expanded MDM surface. (0.17.0's own feature changes — dictation/review gestures, configurable sounds, self-correction/spelled-out-word cleanup rules — stay within existing trust boundaries.)
- **v0.10.0–v0.16.0** (rolled up): multi-provider LLM auth added — OpenAI direct, Vertex AI (gcloud ADC / service-account JSON), Azure OpenAI (resource key / Entra), and Bedrock `static` + scoped-`bedrockApiKey` modes — with all key-based secrets confined to the Keychain; **Reference Windows** (ScreenCaptureKit capture + Vision OCR; Screen Recording TCC; memory-only); persistent **text-free** `metrics.jsonl` (0.15.0; bounded retention, zero-retention-able); and a much larger **managed-configuration** surface (provider/model/auth pins, `asrEndpoint` pin, `staticApiKeysAllowed`, `livePricingEnabled`, transcript-history retention keys).
- **2026-05-06** (`6d64646`): bearer-token sidecar auth, Keychain Gemini key, Soto pin tightening, LiteLLM disable knob.
- **2026-05-05** (`631f6e0`): compliance pass — audio in memory only, transcript redaction from all logs.
- **2026-05-05** (`50d5905`): Bedrock auth — AWS_PROFILE env-var fallback, Soto INI parser bug documented.
- **2026-05-04** (`3afda0d`): Bedrock LLM provider initial wiring.
