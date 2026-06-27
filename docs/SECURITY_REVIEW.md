# Parleq security review packet

This document is the starting point for an enterprise security / cloudops review of Parleq. It describes what Parleq is, what data it handles, where that data flows, what controls are in place, and what trade-offs were made deliberately.

The intended audience is a security reviewer who needs to decide whether deploying Parleq on a managed workstation meets the organization's policy. We've tried to make every claim grep-able to a specific file in the source tree, so anything here can be verified independently.

**Last reviewed:** 2026-06-10 (added the on-device cleanup option: in-process MLX inference path where transcript text crosses no network boundary (§1, §2, §6, §9.1); one new outbound flow — user-initiated Gemma 4 E4B model download from huggingface.co (~4 GB, TLS; §6); eval/debug env vars noted (§5); bundled mlx.metallib supply-chain note (§7); prior 2026-06-08 v0.22.0 content unchanged)
**Source:** [github.com/parleq/parleq-speech](https://github.com/parleq/parleq-speech) at v0.23.0 or later
**Review trigger / context:** [docs/SETUP.md](SETUP.md) covers end-user installation; this document covers the security model.

---

## 1. What Parleq is

Parleq is an open-source macOS dictation utility. The user holds a global hotkey (right Option), speaks, and a cleaned-up transcript appears in a floating overlay; on accept, the cleaned text pastes into whatever app was focused. Two passes:

1. **Speech-to-text (ASR):** local FluidAudio Parakeet TDT v3 inference on the Apple Neural Engine, **in-process** (no separate sidecar, no listening sockets). Audio never leaves the device.
2. **LLM cleanup:** the raw transcript goes to a configurable LLM provider — one of **Google Gemini** (direct API), **OpenAI** (direct API), **Google Vertex AI**, **AWS Bedrock**, or **Azure OpenAI** — or to the **on-device cleanup** option (in-process MLX inference on the user's Mac, **no network boundary**), or cleanup can be skipped entirely (paste raw ASR). Cleanup output streams into the overlay; on accept it pastes and is forgotten.

There is no server-side storage of audio or transcripts. Parleq's only persistent local state is under `~/.parleq/`: user configuration (settings + custom dictionary), a metadata-only LLM-call ledger, and a metadata-only per-dictation metrics file — none contain transcript text. Provider secrets live in the macOS Keychain.

**What changed since this packet was last reviewed (v0.9.0).** Four LLM providers were added beyond Gemini (OpenAI, Vertex AI, Bedrock, Azure OpenAI), each with its own authentication; the **Reference Windows** feature lets the user optionally attach a window's content (captured via ScreenCaptureKit) as cleanup context, which introduces a Screen Recording permission and a new outbound data class; a persistent **text-free** metrics file was added; the managed-configuration (MDM) surface grew substantially; the opt-in **"learn from corrections"** feature (v0.18.0) introduces a bounded in-memory correction journal covered in §5.2 and §9.8; the **on-device cleanup option** (`provider=local`, v0.23.0) adds in-process MLX inference (Gemma 4 E4B) so transcript text crosses no network boundary — see §2 and §9.1; and v0.25.0's **Recover last dictation** retains the most recent capture's audio bytes in process memory (never on disk; overwritten next dictation, wiped on quit) — see §5 data-flows; and the opt-in **voice-enrollment / acoustic-disambiguation** feature (release/Concord builds only) introduces the first **biometric** data class — per-term voiceprints (derived embeddings, never audio) persisted **encrypted at rest** to `~/.parleq/voiceprints.enc`, covered in §5.4. Each is covered below.

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
   │     │  ┌─ on-device cleanup (provider=local) ┤
   │     │  │  LocalLLMProvider (in-process MLX)  │
   │     │  │  Gemma 4 E4B · NO network boundary  │
   │     │  │  (model downloaded once from        │
   │     │  │  huggingface.co ~4 GB — see §6)     │
   │     ◄──┘                                     │
   │     │                                        │
   │     ▼ transcript text (+ attached reference   │
   │       window content, only if the user used   │
   │       Reference Windows this dictation)        │
   └─────┬──────────────────────────────────────────┘
         │  (cloud provider path only — not taken when provider=local)
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

**On-device cleanup (provider=local).** When the user selects the on-device cleanup option, transcript text is processed entirely in-process by `LocalLLMProvider` using the MLX framework and a locally-resident Gemma 4 E4B model. **Transcript text crosses no network boundary** on that path — the only outbound flows associated with the local tier are:

1. **One-time model download:** ~4 GB of model weights from `huggingface.co`, user-initiated (via Settings or the Setup Wizard), TLS-only, anonymous, resume-capable. This does not carry any user speech or transcript data. Blocking `huggingface.co` entirely leaves all cloud-provider and "none" modes fully functional; the local option simply cannot be set up. For MDM-managed fleets that must prevent all `huggingface.co` access, pin away from `provider=local` (or block the download host at the network layer); the app fails closed to whatever other provider is configured.
2. **Nothing else.** No LLM API call, no cleanup payload egress, no telemetry.

The eval/debug hook environment variables `PARLEQ_LEARN_TRIGGER` and `PARLEQ_LEARN_MIN_INTERVAL` are **debug-only tuning knobs for the learning analyzer** (see §5.2 and the environment-variable table in CLAUDE.md). They carry no credential or transcript content and are not a network boundary — they only change when the off-hot-path LearningAnalyzer fires relative to its default thresholds.

**No listening sockets on the default path.** Parleq's default ASR path runs in-process. Earlier builds (≤ v0.8.x) hosted FluidAudio inside a bundled HTTP sidecar on `127.0.0.1:8767`; v0.9.0 retired that boundary. Audio buffers move between AudioRecorder and LocalASR as a Swift `Data` value within the same process — no socket, no IPC, no bearer-token negotiation between two halves of the same install. Users who explicitly configure a custom `asr.endpoint` to point at their own external server (Sherpa-ONNX, faster-whisper) opt into a localhost HTTP path; that's the only scenario in which any local socket is involved, and the server's lifecycle and auth are the user's responsibility.

**One precisely-scoped exception: the OIDC loopback-redirect sign-in.** When an organization configures its corporate OIDC client as a Google "Desktop app" (or any client using an `http://127.0.0.1:<port>/<path>` redirect URI), the system browser cannot deliver the callback to an in-process custom-scheme handler — it navigates to a loopback URL that something must answer. For the **duration of an active interactive sign-in only**, Parleq binds a transient `NWListener` to **127.0.0.1 only** (never a wildcard/0.0.0.0 interface) on a **kernel-assigned ephemeral port**. It accepts the single OAuth callback, replies with a **static HTML page** (no `code`/`state`/token is ever reflected back to the browser), and the listener is **torn down immediately** (defer-based) the instant the callback resolves, times out, or the sign-in is cancelled. The callback URL and its query are **never logged** (the OIDC logger is code/count-only). This listener does not exist during normal dictation; it exists only while a sign-in browser flow is open. The custom-scheme OIDC flow (the default) binds nothing. Implementation: `parleq-app/Sources/ParleqAppCore/LoopbackRedirectServer.swift`.

### Data classifications

| Data | Where it exists | When |
|---|---|---|
| Raw audio (16 kHz mono WAV) | Process memory only | During a single dictation; freed at end of `AppState.finalizeCapture` |
| Raw ASR transcript | Process memory only | From `LocalASR.transcribe` until paste. When cleanup fails, the raw fallback *is* the accepted text and is retained in the in-memory `TranscriptHistory` for the session under the same retention controls as cleaned transcripts (§5.1). Never written to disk. |
| Cleaned transcript | Process memory + paste destination app | In overlay during accept; held in the `TranscriptHistory` ring (in memory only; **default unlimited for the session**, bounded or disabled via the retention keys — §5.1) for the rest of the session; pasted into target app |
| Reference-window captures (PNG + OCR'd text) | Process memory only | Captured via ScreenCaptureKit when the user attaches a window; sent to the LLM as part of the cleanup payload; released at end of dictation (accept/cancel). Never written to disk. |
| Provider secrets (key-based auth modes) | macOS Keychain (service `com.parleq.app`) | Persistent until user removes. Gemini / OpenAI / Azure API keys, the scoped Bedrock API key, static AWS IAM credentials, and the Vertex service-account JSON — whichever the configured provider/mode uses. |
| CLI-session credentials (SSO / ADC / Entra modes) | AWS/gcloud/az CLI caches (e.g. `~/.aws/sso/cache/`) | Per the user's existing CLI session — Parleq stores nothing and delegates refresh to the CLI. |
| User dictionary + settings | `~/.parleq/config.json` | User-authored config. No transcripts. |
| LLM-call ledger | `~/.parleq/usage.jsonl` | Token counts + provider/model + target-app bundle ID. **No transcript content.** |
| Per-dictation metrics | `~/.parleq/metrics.jsonl` | id, timestamp, audio duration, ASR/LLM latency, `hadReference` + `cleanupFailed` booleans. **No transcript text, no window labels.** Bounded retention (§5). |
| Preset-usage ledger | `~/.parleq/preset-usage.jsonl` + `~/.parleq/preset-usage-declined.json` | Timestamp + preset ID/name (config label) + target-app bundle ID + `manual`/`default` source per preset application; declined (app, preset) pairs in the sidecar. **No transcript content.** Same class as `usage.jsonl` (§5). |
| Correction journal (opt-in, off by default) | Process memory only | Refine-event records (instruction + the edit's before/after text) and spell-out candidates (assembled term + the cleaned text it appeared in). Captures correction *events* only, not a log of every dictation — but a refine record's before/after can be that dictation's full cleaned text (same data class the provider already saw during cleanup). Held in memory only when `learnFromCorrectionsEnabled = true`; count + age caps bound the ring; cleared on quit (§5.2). **Never written to disk.** |
| Learned-changes store (opt-in, off by default) | Process memory only | Pending suggestions and applied-changes log for revert. Provenance only — no extra transcript content. Held in memory only when "learn from corrections" is enabled; cleared on quit (§5.2). **Never written to disk.** |

### Trust boundaries

Parleq trusts:
- The user's macOS user account (process isolation, Keychain ACLs, AWS/gcloud/az CLI session-cache integrity).
- The configured LLM provider HTTPS endpoint(s) — chosen from Gemini, OpenAI, Vertex AI, Bedrock, or Azure OpenAI. Parleq has two tiers (a Cleanup provider and an optional Context provider for reference-aware turns) that may be *different* providers, so data can reach up to two of them (§3.2, §6). When `provider=local` is selected, no cloud LLM endpoint is trusted or contacted for cleanup.
- macOS system frameworks **ScreenCaptureKit** and **Vision** (used by Reference Windows to capture + OCR a window the user explicitly picks; only exercised when that feature is used).
- LiteLLM's community pricing JSON (`raw.githubusercontent.com/BerriAI/litellm/...`) — used for cost reporting only; not load-bearing for any user-facing functionality. **Disable-able via the `livePricingEnabled: false` MDM key (fleet-wide) or the `PARLEQ_DISABLE_LIVE_PRICING=1` env var (single user).**
- The FluidAudio model artifacts in `~/Library/Application Support/FluidAudio/Models/` (downloaded by FluidAudio's own loader from `huggingface.co` on first run; their integrity is FluidAudio's responsibility, not Parleq's).
- The on-device cleanup model artifacts in `~/Library/Application Support/Parleq/models/` (downloaded by Parleq's own `LocalModelStore` from `huggingface.co` at user request; model weights are downloaded over TLS and accepted on that channel's integrity — the `.parleq-ready` marker is a completion sentinel written only after all files land, not a cryptographic hash of the weights — the same trust posture as the FluidAudio ASR models; the Metal shader library `mlx.metallib` IS SHA-256-verified at build time — §7).

Parleq does **not** trust:
- Other processes on the user's device (Keychain is per-app via service identifier; no listening sockets to attack in the first place — see §3.1).
- Network attackers between the user and the configured provider (HTTPS via the system trust store; no certificate pinning, but no plaintext fallback either).
- The user's own custom `asr.endpoint` setting if set (no shared secret with external servers; user manages their own server's auth). On managed Macs this setting can be pinned via MDM so a user cannot redirect audio to an arbitrary endpoint (§9.6).

---

## 3. Authentication & authorization

### 3.1 No listening sockets on the default ASR path

Parleq's bundled ASR path has no network exposure of any kind. `LocalASR` calls FluidAudio's `AsrManager.transcribe(_:decoderState:)` in-process; the audio buffer is a Swift `Data` value that never crosses a process or socket boundary.

This replaces the bearer-token-authed `127.0.0.1:8767` HTTP sidecar that earlier builds (≤ v0.8.x) used. The sidecar's bearer token was generated fresh per launch and required on every `POST /inference`, which adequately protected the local endpoint from other processes on the same machine — but v0.9.0 dropped the boundary entirely on the principle that the strongest "no other process can submit audio against the user's loaded models" guarantee is no listening socket to send audio to.

**Two scenarios involve a local socket at all.** The first is when the user explicitly sets `asr.endpoint` in `~/.parleq/config.json` to a non-default value. In that case ASRClient POSTs WAV bytes to whatever URL the user configured (typically a Sherpa-ONNX or faster-whisper server they're running locally). Parleq sends no Authorization header on that path — there's no shared secret to use — and the server's lifecycle, bind address, and access control are entirely the user's responsibility. The bundled in-process FluidAudio engine is then never initialized, so its model isn't loaded and its memory isn't paid for.

The second is the **OIDC loopback-redirect sign-in listener** (§3.4.1), which is the only socket Parleq itself ever *binds*, and only while an interactive corporate sign-in is open.

### 3.2 LLM provider authentication

Five providers are supported. The user configures up to **two tiers**: a **Cleanup** tier (used for ordinary, non-reference dictations) and an optional **Context** tier (used for reference-aware turns when a window/file/clipboard is attached — *if* a Context provider/model is set; otherwise those turns fall back to the Cleanup tier). Each tier has its own provider + model, so they can be two *different* providers, and transcript/reference content may therefore egress to up to two of them. On managed Macs both tiers' provider + allowed models + auth mode can be pinned via MDM (§6, §9.7). Each provider authenticates differently:

- **Gemini direct API:** API key sent as the `x-goog-api-key` HTTP **header** on every request (Google also accepts a `?key=…` query param; we use the header so the key never appears in a URL string that framework logging could capture). Resolved per-request from env (`GEMINI_API_KEY`) → Keychain (§4.1) — no plaintext-on-disk fallback.
- **OpenAI direct API:** API key sent as `Authorization: Bearer <key>`, stored in the Keychain (account `openai-api-key`) and resolved from the Keychain only — no env fallback. Endpoint `api.openai.com`.
- **Google Vertex AI:** two auth modes. **gcloud ADC** — shells out to the user's `gcloud` for a short-lived OAuth token (no secret stored by Parleq). **Service-account JSON** — the SA key JSON is stored in the Keychain (account `vertex-service-account-json`) and Parleq mints OAuth tokens itself via JWT-bearer/RS256 against `oauth2.googleapis.com/token`. Endpoint `{region}-aiplatform.googleapis.com`.
- **AWS Bedrock:** three auth modes (`aws.auth_mode`). **`sso`** (a slight misnomer — it hands Soto a credential *chain*, not SSO-only) — Parleq stores no AWS secret; with a profile set (Settings or `AWS_PROFILE`) Soto resolves, in order, the named `~/.aws/config` profile → the SSO cache at `~/.aws/sso/cache/` → **environment AWS credentials** (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`) as a last-resort fallback — so a valid SSO session takes precedence over stray ambient env keys; with no profile, Soto's **default credential chain** runs (§4.2). **`static`** — static IAM access keys, stored **in the Keychain** (account `aws-static-credentials`, JSON-encoded). **`bedrockApiKey`** — a scoped Bedrock API key stored in the Keychain (account `bedrock-api-key`), sent as `Authorization: Bearer <key>` over plain HTTPS by `BedrockBearerProvider`, bypassing Soto entirely. (This supersedes the earlier "#21 not yet supported / Parleq never stores AWS credentials" note — static and bearer-key auth have since shipped and *do* persist credentials in the Keychain. See §4.2.)
- **Azure OpenAI:** two auth modes (`azure.auth_mode`). **`apiKey`** — the resource key sent as the `api-key:` header, stored in the Keychain (account `azure-openai-key`). **Microsoft Entra ID** — shells out to `az` for a token (no secret stored by Parleq). Endpoint `{resource}.openai.azure.com`.

In every key-based mode the secret lives only in the macOS Keychain (service `com.parleq.app`) — never in a Parleq-owned file on disk. In the non-Keychain modes Parleq stores nothing: Bedrock `sso` delegates to Soto's credential chain (reading `~/.aws` config + SSO cache + env directly), while Vertex ADC and Azure Entra shell out to `gcloud`/`az` for short-lived tokens. An MDM key (`staticApiKeysAllowed: false`) can forbid the key-based modes fleet-wide, forcing CLI-session auth.

### 3.3 Macros / Login Items

The user's hotkey requires the **Accessibility** TCC grant (CGEventTap-based listener). **Microphone** TCC is required for AVAudioEngine input. **Screen Recording** TCC is required *only* for the optional Reference Windows feature (ScreenCaptureKit window capture) — it is requested lazily the first time the user attaches a window, never at startup, and the rest of the app works without it. No app-sandbox; Hardened Runtime entitlements are minimal: `audio-input`, `network.client`, `network.server`, `cs.allow-jit` (for CoreML JIT). See `parleq-app/Resources/Parleq.entitlements`. (Microphone, Accessibility, and Screen Recording are TCC permissions, not Hardened Runtime entitlements, so they don't appear in that file — verify them in System Settings → Privacy & Security.)

**Implication:** the Accessibility grant gives Parleq the technical ability to read all keystrokes globally. The actual code uses CGEventTap only for the right-Option press-and-hold detection, but a reviewer should treat this as "Parleq is a privileged process on this machine" and weigh the source code accordingly. Mitigation: open-source code audit, Apple notarization, stable bundle-ID + signature so TCC grants don't silently transfer to a tampered build.

### 3.4 Enterprise OIDC federation

An optional auth path lets an organization back Parleq's cloud access with a single corporate OIDC sign-in instead of per-user API keys. It is off unless explicitly configured (`oidc.issuer` + `oidc.client_id`, with `aws.auth_mode = "oidc"` and/or `vertex.auth_mode = "oidcFederation"`; all four are MDM-pinnable). Two generic-OP knobs (`oidc.redirect_uri`, MDM `oidcRedirectURI`; and `oidc.extra_auth_params`, MDM `oidcExtraAuthParams`) let the same engine work with providers that use non-default conventions (e.g. a Google native client's reversed-client-ID redirect scheme and its `access_type=offline`/`prompt=consent` requirement). Both default off (the fixed `parleq-auth://oidc/callback` redirect, no extra params), so a config without them produces the exact pre-existing authorization request. Reserved authorization params (`client_id`, `redirect_uri`, `state`, `nonce`, `code_challenge*`, `response_type`, `scope`) cannot be overridden via `extra_auth_params` — collisions are dropped with a count-only log, preserving the flow's PKCE/state/nonce binding. The data-handling shape:

- **One sign-in, per-cloud exchange.** The user signs in once via PKCE in a system web view (`ASWebAuthenticationSession`) or — for a Google "Desktop app" client with a loopback redirect (§3.4.1) — the default system browser; Parleq holds only the resulting refresh token (Keychain) and mints short-lived ID tokens from it on demand. Each cloud leg exchanges that ID token for its own credentials at call time: AWS via `AssumeRoleWithWebIdentity` (→ temporary STS credentials), GCP via Workforce Identity Federation (→ a federated access token). No long-lived cloud secret is stored. On the AWS leg the `AssumeRoleWithWebIdentity` call is **unauthenticated** (no Parleq-held AWS secret) — the **IAM role's trust policy (its issuer + audience pinning) is the customer-side gate** that decides which OIDC identities may assume the role, and Parleq cannot enforce it; a misconfigured trust policy is an org-side exposure.
- **Direct-token mode for Vertex (`vertex.auth_mode = "googleOAuth"`).** A no-broker variant for native Google sign-in: when the sign-in is granted the `https://www.googleapis.com/auth/cloud-platform` scope, the OAuth **access token** itself is used directly as the Vertex bearer — no STS hop, no Workforce Identity Federation (which GCP refuses for Google as an IdP), and no GCP organization required. In this mode the cached access token carries **broad GCP API power acting as the signed-in user** — the same trust model as gcloud Application Default Credentials' cached credentials. As with every other token in this feature it is **memory-only** (never written to disk; cleared on sign-out and on quit); the only persisted secret remains the **refresh token in the Keychain**. Quota and billing attribute to the configured `vertex.project` via the `x-goog-user-project` header.

  **Client provisioning is the enterprise hardening here.** Google offers no separate enterprise sign-in service for Cloud APIs — user OAuth *is* the first-party mechanism (gcloud itself signs in this way). What an org controls is how the OAuth client is provisioned, two supported routes:
  - **Internal-audience OAuth client in the customer's own Google Cloud org.** An Internal client shows no unverified-app warning, has no 100-user cap, no 7-day testing-mode refresh-token expiry, and requires no Google verification; sign-in is **hard-blocked for any account outside the org**. This is the recommended posture for a managed fleet.
  - **A Workspace admin marking the client ID Trusted** via API controls → App access control, for clients provisioned outside the org's own project.

  In either route the access token this mode mints carries the `cloud-platform` scope — **broad GCP power acting as the signed-in user, the same trust model as gcloud ADC** (above). The token remains **memory-only**, and **IAM on the target project is the authorization boundary**: scope it to what dictation cleanup needs (e.g. Vertex AI prediction on `vertex.project`), not org-wide roles.

  **Trust model, stated plainly.** This mode is a deliberate **direct-bearer** design: it bypasses workforce federation entirely (GCP refuses Google as a workforce IdP), so there is no STS/Workforce broker to scope-down the token. The minted access token is **bearer-powerful for the full `cloud-platform` scope** — anyone holding it can act as the signed-in user, and its **blast radius is exactly what that user's IAM allows** (hence the "scope IAM tight" guidance above is the load-bearing control, not a nicety). Parleq's **granted-scope verification at sign-in depends on the OP echoing the `scope` field** in the token response: Google does echo it, so Parleq confirms `cloud-platform` was actually granted before using the token; an OP that omits `scope` from the response **skips that verification by design** (Parleq cannot verify a grant the OP doesn't report) and the request proceeds on the assumption the requested scope was honored.
- **Fail-closed.** If sign-in, refresh, or the per-cloud exchange fails, cleanup does not silently fall back to a personal credential or a different provider — it fails closed, and Parleq pastes the **raw on-device ASR transcript** (the same behavior as any cleanup failure). The transcript is never blocked from the user; only the LLM cleanup pass is skipped. **Recovery (0.22.0+):** for the federation case the overlay's fail-closed "signed out" notice is itself the recovery affordance — tapping it runs the **same** interactive sign-in as Settings → Company Account against the one shared session (no new network boundary, listening socket, or token surface — only sign-in *state* crosses into the overlay layer), after which the user may opt to re-run cleanup on the retained raw transcript. Re-cleaning is never automatic.
- **Refresh rotation, persist-on-receipt.** When the IdP rotates refresh tokens (e.g. Okta replay-detection, Keycloak `revokeRefreshToken`), Parleq persists the newly-issued refresh token to the Keychain **immediately on receipt**, before any other work — losing a rotated token would otherwise force a re-login. Concurrent callers share a single in-flight refresh (single-flight).
- **Revocation latency.** Offboarding (disabling the user at the IdP, or revoking the refresh token) takes effect at the **next token refresh** — Parleq's next refresh attempt fails and the session moves to a signed-out / needs-interactive state. Already-issued cloud credentials, however, live to their session maximum: AWS STS credentials default to 1 h (MDM-tunable via `awsSessionDurationSeconds`, 900–43200 s) and **STS credentials are not revocable** once minted; GCP federated tokens similarly live out their lifetime. An org needing tighter offboarding should keep the AWS session duration short.
- **Log discipline.** OIDC logging is **state names + machine-readable codes only** — e.g. `oidc state=sessionExpired code=invalid_grant`. Tokens, JWT claims, and the user's email are **never** logged. The signed-in identity (name / email) renders in the **UI only** (Company Account view); the connection doctor's IT-facing error detail strings are shown in the UI and never written to the log file.

#### 3.4.1 Loopback-redirect sign-in (Google "Desktop app" clients)

The interactive sign-in uses one of two browser-callback mechanisms, chosen by the configured `oidc.redirect_uri`:

- **Custom scheme (default).** A `parleq-auth://oidc/callback` (or org-pinned reversed-client-ID) redirect is intercepted **in-process** by `ASWebAuthenticationSession`. **No socket is bound.** This is the path for Okta/Entra/Keycloak/Cognito and Google native (iOS-type) clients.
- **Loopback (Google "Desktop app" client type).** Google's current desktop-app guidance is an `http://127.0.0.1:<port>/<path>` redirect, which `ASWebAuthenticationSession` cannot intercept. For this case Parleq opens the authorization URL in the user's **default system browser** and answers the callback with a transient local listener. The validator accepts only `http://` + a **loopback host** (`127.0.0.1`/`localhost`/`::1`); `https://` and non-loopback `http://` are rejected at config load.

The loopback listener (`LoopbackRedirectServer.swift`) is the **only socket Parleq binds**, and its scope is deliberately minimal:

- **127.0.0.1 only**, never a wildcard interface — unreachable off the loopback adapter.
- A **kernel-assigned ephemeral port** every time. The port in the configured redirect URI is **ignored** (Google Desktop clients accept any loopback port); only the path is honored.
- **Static HTML response** — the success/400 pages are constant bytes. The OAuth `code`/`state` are never reflected back into the browser response.
- **One-shot, immediate teardown.** Stray probes (favicon, health checks) get a static 400 and do not consume the flow; the first valid callback wins, after which the listener is **torn down via `defer`** the instant the callback resolves, times out, or the sign-in is cancelled. The listener does not exist during normal dictation — only while a sign-in browser flow is open.
- **No callback URL or query is ever logged** (the OIDC logger is code/count-only; loopback log lines are `oidc loopback listener bound/closed`).
- **Same PKCE + state binding** as the custom-scheme path. The `redirect_uri` sent in the authorization request and echoed in the token exchange is the exact ephemeral-port loopback URI.

Note that `oidc.ephemeral_browser` (an `ASWebAuthenticationSession`-only feature) does not apply to the loopback flow — it uses the real default browser; the config is honored on the custom-scheme path and a code-only notice is logged if it's set alongside a loopback redirect.

**Controlling / disabling the loopback listener.** The listener is selected **solely** by `oidc.redirect_uri`, and only when that value's scheme is `http` and its host is loopback. Every other redirect — a custom scheme (`parleq-auth://oidc/callback`), a reversed-client-ID scheme — routes through `ASWebAuthenticationSession` and **binds no socket** (`makeOIDCAuthenticator` in `CompanyAccountView.swift`). The redirect URI is therefore the complete control over whether the listener can ever activate. For a managed fleet, `oidcRedirectURI` is an **MDM-pinnable key** (§9.7): an org that wants the no-local-listener guarantee pins it to its custom-scheme value, after which the user cannot change it, a loopback redirect can never be configured, and the listener can never bind. **There is intentionally no separate "disable loopback" managed-config key** — the `oidcRedirectURI` pin already fully and provably controls it, and a dedicated off-switch would be redundant surface. (Orgs using Okta/Entra/Keycloak/Cognito with a custom-scheme redirect never trigger the loopback path at all, pinned or not — it is not the default.)

---

## 4. Secrets management

### 4.1 Provider secrets in the Keychain

Every key-based provider secret lives in the macOS Keychain under service `com.parleq.app`, class `kSecClassGenericPassword`, accessibility `kSecAttrAccessibleAfterFirstUnlock`. The Settings UI is the only writer (`KeychainStore.swift`); secrets are never displayed in plaintext after save and never written to a Parleq-owned file. The `kSecAttrAccessibleAfterFirstUnlock` class is consistent across **all** provider secrets (including the OIDC refresh token and identity snapshot below); the rationale is **login-item autostart** — Parleq can be launched at login (Open at Login) before the user interactively unlocks a Settings/Keychain prompt, and `AfterFirstUnlock` lets the credential resolve on that autostart path while still keeping the item inaccessible before the first post-boot unlock (it is never `…Always`).

| Keychain account | Secret | Used by |
|---|---|---|
| `gemini-api-key` | Google AI API key | Gemini direct |
| `openai-api-key` | OpenAI API key | OpenAI direct |
| `azure-openai-key` | Azure resource key | Azure OpenAI (`apiKey` mode) |
| `bedrock-api-key` | Scoped Bedrock API key | Bedrock (`bedrockApiKey` mode) |
| `aws-static-credentials` | Static IAM access key + secret (JSON) | Bedrock (`static` mode) |
| `vertex-service-account-json` | GCP service-account key JSON | Vertex AI (`serviceAccount` mode) |
| `oidc-refresh-token` | Enterprise OIDC refresh token (rotated on each refresh) | Company Account federation (AWS `oidc` / Vertex `oidcFederation` modes) |
| `oidc-identity` | Signed-in identity snapshot (sub, email, name, issuer) as JSON | Company Account UI display + attribution |
| `oidc-client-secret` | Optional OAuth client secret for Google "Desktop app" clients — **client configuration, not a user credential**; survives sign-out (cleared only when the user removes it in Settings) | Company Account federation (Google Desktop-client token exchange) |

**OIDC client secret.** Optional; needed only for a Google "Desktop app" OAuth client, which Google requires to send a `client_secret` on the token exchange even with PKCE. Per Google's own docs an installed-app secret is **not confidential** (public-by-design), but Parleq still keeps it in the Keychain rather than `config.json`. Unlike the refresh token + identity snapshot, the client secret is **client configuration** (the same kind of value as the issuer and client ID), so it **survives sign-out** — `KeychainOIDCTokenStore.clear()` deliberately leaves it intact; it is removed only when the user explicitly clears it in Settings. It is appended to the token-exchange and refresh-grant form bodies (percent-encoded like every other field) and is never logged. The stored secret is **owner-stamped** with the `client_id` + `issuer` it was saved for: on read, if the configured client/issuer no longer matches, the stale secret is dropped (and deleted) rather than sent — so reconfiguring to a different OIDC client never transmits a previous client's secret to the new IdP. (Sign-out is not a reconfiguration, so the secret correctly survives it.)

**OIDC token lifetimes.** Only the long-lived **refresh token** and a small **identity snapshot** persist — both in the Keychain, never in a Parleq-owned file. The OIDC **access token and ID token are held in process memory only** and are never written to disk; the ID token is minted on demand from the refresh token, handed to the cloud STS exchange, and discarded. The identity snapshot exists so the Company Account view can show who's signed in across launches without a network round-trip; it is stored in the Keychain (not `config.json`) so PII never lands in a plain file, and it renders in the UI only — never in logs.

The non-Keychain auth modes also store **nothing**, but they obtain credentials differently: **Bedrock `sso`** delegates to Soto's credential chain, which reads the `~/.aws/config` profile and the SSO cache **directly** (no AWS-CLI process is invoked), with environment AWS credentials only as a last-resort fallback — see §4.2; **Vertex gcloud ADC** and **Azure Entra** shell out to the user's `gcloud` / `az` CLI for short-lived tokens.

**Resolution order.** Only Gemini has a key-bearing environment variable: `LLMClient.resolveAPIKey()` checks `GEMINI_API_KEY` first (CI / `swift run` / dotfiles), then the Keychain. Every other key-based provider — OpenAI, Azure, the Bedrock API key, the Vertex service-account JSON — resolves **only** from the Keychain; there is no env fallback for them. (Bedrock's `sso` mode is the exception to "Keychain only" — it delegates to Soto's AWS credential **chain**: the `~/.aws/config` profile and SSO session take precedence, with environment AWS credentials only as a last-resort fallback; see §4.2. Parleq still persists nothing in that mode. The AWS region comes from Parleq's configured region, not an env var.) There is **no plaintext-on-disk fallback** for any provider — if no secret resolves in a key-based mode, LLM cleanup is disabled and Parleq pastes the raw ASR transcript.

### 4.2 AWS / Bedrock credentials

Bedrock has three auth modes (`aws.auth_mode`); what Parleq stores depends on the mode:

- **`sso` (default):** Parleq stores **nothing** — it hands Soto a credential **chain** (the mode name is a slight misnomer; it is not SSO-only). With a profile set (the Settings field, or the `AWS_PROFILE` env var when the field is empty), Soto's selector tries, in order: the named `~/.aws/config` profile, then the SSO cache (`~/.aws/sso/cache/<sha1>.json`, refreshed against `oidc.<region>.amazonaws.com` / `portal.sso.<region>.amazonaws.com`), then **environment AWS credentials** (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`) as a last-resort fallback — so a valid SSO session takes precedence over a stray ambient access key. With **no** profile, Soto's **default credential chain** runs (which also includes environment, config, and SSO sources). Whatever the source, the credentials are user-/environment-provided and live only in Soto's in-memory rotating cache — never persisted by Parleq. A reviewer evaluating `sso` mode should still account for env credentials as a **fallback** — they authenticate only when no profile/SSO credential resolves.
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
| `~/.parleq/config.json` | Settings: hotkey, dictionary terms, AWS profile name, model selection, etc. `presets` (array of `{id, name, prompt}`) and `preset_app_defaults` (bundle-ID → preset-ID map) are user-authored configuration — preset names and instruction text only, no dictation-derived content. A per-app preset default folds into the existing cleanup call (no new LLM request, no new network boundary). Both keys are omitted when empty. | User-authored config. No transcripts, no audio, no API keys. |
| `~/.parleq/usage.jsonl` | One JSON line per LLM call: timestamp, kind (cleanup/refine), provider, model, input/output token counts, latency, target-app bundle ID. | **Metadata only.** No transcript or cleanup-output content. |
| `~/.parleq/preset-usage.jsonl` + `~/.parleq/preset-usage-declined.json` | One JSON line per transform-preset application (`PresetUsageEntry`): timestamp, preset ID, preset name (a user-authored config label), the paste-target app bundle ID, and a `source` of `manual`/`default`. The sibling declined file holds the set of (app, preset) pairs the user un-set or declined as a per-app-default suggestion. Feeds the preset-suggestion bridges (Presets v1.1). Self-compacting (newest 5 000 lines kept past a 10 000-line threshold). | **Metadata only — exactly the `usage.jsonl` class.** No transcript, refine instruction, or any user-spoken content — preset names are config labels, bundle IDs are app identifiers. A per-app preset default folds into the existing cleanup call (no new LLM request, no new network boundary). Implementation: `PresetUsageJournal.swift`. |
| `~/.parleq/metrics.jsonl` | One JSON line per dictation (`MetricsRecord`): id, timestamp, audio duration, ASR latency, LLM latency, `hadReference` boolean, `cleanupFailed` boolean. Feeds the cross-session Stats dashboard. | **Metadata only — no transcript text, no window labels, no app names.** The on-disk file is **hard-bounded to a fixed 30-day horizon regardless of config** (`persistedRetentionDays = 30`; the Stats view renders only 7 days). `transcriptHistoryRetentionHours` additionally age-prunes persisted records when set; `transcriptHistoryMaxEntries` caps only the in-memory *text* history, **not** these metrics. Setting **either** key to 0 disables history entirely — metrics are cleared and not persisted (the zero-retention lever for compliance fleets). Default: unlimited in memory, 30 days on disk. |
| `~/.parleq/pricing-cache.json` | LiteLLM JSON snapshot (public reference data). | Not user data. Disable-able via `PARLEQ_DISABLE_LIVE_PRICING=1`. |
| `~/.parleq/app.log` | Stderr-redirected diagnostics: phase transitions, ASR latency + length, LLM token counts, model-load progress, error stack traces. Capped at 10 MB; truncates to last 5 MB on launch when over the cap. | **No transcript content, no audio, no auth values.** Same redaction discipline as the rest of the codebase. Learning-analysis log output is count-only (records analyzed, proposals produced) — no correction snippet content. Skipped in dev mode (when stderr is a TTY). **Debug builds only:** development builds (never the released binaries — the gate is a compile-time `#if DEBUG` inside the FluidAudio dependency) emit verbose third-party ASR logs that can include transcript text. As of the 2026-06 audit (§8.1, finding #11), debug builds **no longer redirect stderr to `app.log`** unless `PARLEQ_DEBUG_LOG=1` is explicitly set, so that transcript-bearing debug output stays on the developer's terminal and off disk; a security review of a release build is unaffected either way. **Opt-in trace exception:** setting the `PARLEQ_VOCAB_TRACE=1` environment variable restores per-replacement vocabulary detail (`replaced 'X' → 'Y'`) in the log, which includes transcript-derived words — off by default, requires the user to deliberately set the variable on their own machine, and is intended for short-lived debugging only. `PARLEQ_HOTKEY_TRACE=1` emits keypress timing metadata only (gap/hold durations, classifier booleans — no content). `PARLEQ_BEDROCK_TRACE=1` enables Soto's debug logger, whose output CAN include request bodies (transcript text) and auth material — but it activates only when stderr is a TTY (a developer terminal session); in the bundled app, where stderr is redirected to `app.log`, the variable has no effect, so this content cannot reach the log file. |
| `~/Library/Application Support/FluidAudio/Models/` | Downloaded Parakeet TDT v3 + CTC vocab encoder model weights. | Public model artifacts, not user data. |
| `~/Library/Application Support/Parleq/models/` | On-device cleanup model weights (Gemma 4 E4B QAT 4-bit, `mlx-community/gemma-4-E4B-it-qat-4bit`). Present only when the user has downloaded the model. Not user data. Removed via Settings → Cleanup → Remove model. | Public model artifacts, not user data. |
| `~/.parleq/voiceprints.enc` | Per-term **voiceprints** for the opt-in voice-enrollment acoustic-disambiguation feature (**Concord / release builds only**; the public OSS build has no enrollment feature and never writes this file). Contents are **derived acoustic embeddings only** (`VoiceprintTemplate`: term ID, a pooled float centroid, per-confusable negative centroids, dimensionality, a quality flag, and the ASR model version) — **never audio, never transcript text**. | **Biometric data, encrypted at rest.** AES-256-GCM (CryptoKit) under a random 256-bit key held in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-only, **non-synchronizable**, never iCloud-routed). File written `0600` via a same-mode temp + atomic replace. Opt-in (gated on `voiceEnrollmentConsented`, off by default — recording never starts before explicit in-wizard consent), on-device, and deletable anytime (per-term **Remove voiceprint** or **Delete all voiceprints**; deleting the last one removes the file). See §5.4. |
| `~/.parleq/enrollment-audio.enc` | The user's short voice-**enrollment** carrier clips (positive + per-confusable negative), retained ONLY to **auto-re-derive** a voiceprint when the ASR encoder changes (durable-voiceprints; **Concord / release builds only**). Contains 16 kHz mono audio of the user speaking the enrollment carrier sentences — **biometric**. Never contains dictation audio. | **Biometric audio, encrypted at rest.** AES-256-GCM under the **same** device-only Keychain key + `0600` atomic-write as `voiceprints.enc`. **Doubly gated, fail-closed:** written only when `voiceClipStorageConsented` (a *fresh amended* consent — users who consented under the prior "clips discarded" copy stay unconsented) **AND** `voiceprintClipStorageEnabled` (user/MDM toggle; a malformed MDM value disables it; disabling at launch **erases** the file). Never network-transmitted. Deleted with the term's voiceprint / "Delete all voiceprints". See §5.4. |

**Explicitly NOT written to disk:**
- Audio bytes (WAV or PCM). `AudioRecorder.stop()` returns `Data` in memory; the bundled `LocalASR` decodes that buffer to Float samples in-process and hands them to FluidAudio without touching the filesystem. When the user has configured a custom `asr.endpoint`, `ASRClient` POSTs via `request.httpBody` (in-memory), not `httpBodyStream` (potentially file-backed). **As of 0.25.0, the bytes of the *most recent* fresh capture are retained in process memory** (a single `Data` buffer on `AppState`) to power the **Recover last dictation** feature (hold-hotkey + R, or the menu-bar item, re-runs ASR + cleanup on that buffer). This is a deliberate, disclosed extension of the audio retention profile: still **in-memory only — never written to disk**, overwritten by the next fresh capture, and wiped on app quit. Refine turns don't overwrite it; a dead/silent capture is never retained.
- Transcript text. `AppState`'s ASR diagnostic logs `(N chars / W words)` — length only.
- Cleanup output text **on disk**. Held in process memory only — first in the overlay during cleanup, then in the `TranscriptHistory` ring buffer (see § 5.1 below) for the rest of the session, then gone on app quit. Never serialized to a file.
- Reference-window captures. PNG screenshots + OCR'd text from Reference Windows (and any attached file/clipboard content) live in process memory for the duration of one dictation and are released on accept/cancel — never written to disk, never cached between sessions.
- Correction journal and learned-changes store (§5.2). Even when "learn from corrections" is enabled, the correction ring and the learned-changes store are held entirely in process memory — **never written to disk**. Cleared on app quit, like Recent Dictations text. The only durable output is the learned dictionary terms, which are written to the existing `~/.parleq/config.json` — the same file that holds hand-added dictionary terms.
- Learned **activity log** + **dismissed-preset hashes** (`LearnedStore.swift`). The unified Recent Activity ring (accept / dismiss / restore / revert entries) and the in-memory set of dismissed-preset-suggestion hashes that suppress re-proposing a rejected preset are **process-memory only** — never serialized, wiped on quit. (The separate `preset-usage.jsonl` + `preset-usage-declined.json` above are the only durable preset-related artifacts, and they are metadata-only.)
- **ASR encoder features.** The voice-enrollment gate is powered by **Parakeet encoder acoustic features** that the Concord build captures per utterance (`ASRDiagnostics.encoderFeatures`, ~0.8 MB, transient, freed at end of utterance); this field is **deliberately excluded from `Codable`** so it can never be serialized into the contribution-capture (flywheel) record or any other on-disk artifact. *(Note: the voice-**enrollment** carrier clips themselves are, as of the durable-voiceprints feature, optionally retained — but only **AES-GCM-encrypted** in `~/.parleq/enrollment-audio.enc`, only with consent + the storage toggle on; see the written-to-disk table above and §5.4. The dictation hot path still writes no audio.)*

This was explicitly verified after a full source sweep on 2026-05-06 (see git history for commits `631f6e0` and `6d64646`).

### 5.1 In-memory transcript history (Recent Dictations)

The Parleq window's **Recent Dictations** section surfaces recent dictations so the user can grab one back if a paste lands somewhere unexpected (focus changed mid-flight, target app rejected the paste, etc.). A dictation is recorded when the user **accepts** (pastes) it **or clicks Copy** in the overlay — so a result that was copied and then dismissed is still retrievable. Recording is **one entry per dictation session, updated in place** (`TranscriptHistory.upsert`, keyed by a per-session id): copying, refining, and accepting the same dictation update a single entry rather than appending duplicates. This adds no new data class — copied text is the same in-memory transcript text the user just dictated, under the identical retention controls (and `0` still disables the ring entirely). Implementation: `TranscriptHistory.swift`, an `@MainActor` ring of `TranscriptEntry` structs (UUID, timestamp, transcript text, original target-app name, reference labels, and a `wasCleanupSuccessful` boolean). Entries whose cleanup failed carry the raw ASR transcript that Parleq actually pasted — the same text the user accepted — with the boolean false so the list can mark them ` · raw`. Successful entries carry the cleaned text with the boolean true. From a compliance standpoint the data classification is identical either way (in-memory transcript text the user just dictated); the boolean is a display hint, not a security boundary.

**Compliance posture:**
- **Process memory only.** The buffer is held in a singleton `@MainActor` class; never serialized to disk, never sent over the network. Deleted when the process exits — a `Quit Parleq` from the menu bar wipes the entire history.
- **No new persistence surface.** The transcript text (cleaned or raw fallback) was already in process memory while the overlay was open during cleanup. We hold it for the remainder of the session (default unlimited; bounded or disabled via the retention keys below) instead of dropping it the moment the user pastes. From the policy's perspective, the data classification of "transcript the user just dictated" is unchanged — it's still in-memory state, just held longer.
- **Configurable retention; can be fully disabled.** The session text history is **unlimited by default** (the old hardcoded 20-entry cap was removed when Recent Dictations moved into the Parleq window). Two keys bound it — `transcriptHistoryMaxEntries` (count) and `transcriptHistoryRetentionHours` (age) — settable per-user or pinned fleet-wide via MDM. **Setting either to `0` disables history entirely** — both the text ring *and* the persisted metrics (§5) — the zero-retention lever for compliance fleets. The user can also wipe everything on demand via **Clear all dictation history** in the section, or quit to drop the in-memory state.
- **App/destination labels — sent only on reference-aware turns.** The destination app name (e.g. "iTerm2") is captured for display in the Recent Dictations list. It is **not** sent anywhere for ordinary (no-reference) dictations. On a *reference-aware* dictation, `PromptBuilder` does include it (a `Destination:` line) plus each attached reference's app name and sanitized window title in the LLM prompt, so cleanup can match tone/context (§6, §9.6). None of these labels are ever written to disk.

**Click-to-clipboard handler.** When the user clicks a recent entry, the full text is written to the system pasteboard via `NSPasteboard.general.setString(...)`. The pasteboard is a system-level shared resource — once a text value lands there, any process running as the same user can read it via the standard pasteboard APIs. This is the same posture as any user-initiated copy; nothing Parleq-specific. Users on shared machines or with paranoid threat models can avoid the click-to-copy path entirely (the entries remain visible in the menu without copying).

**Threat model.** Memory dumps of a running Parleq process would surface the buffer; this is the same exposure as any in-flight cleaned text (the overlay's `currentText`, the LLM's response stream buffer, etc.). Anyone with the privilege to dump Parleq's memory already has the privilege to dump any process running as the same user, so this is not a new attack surface — it's the existing one with a slightly larger value at risk (the session's retained dictations — default unlimited, bounded/disable-able via the retention keys — vs. just the current one).

**Verification:** `grep -rn "TranscriptHistory" parleq-app/Sources/` shows the singleton exists at `TranscriptHistory.swift`, is read by `RecentDictationsView.swift` (the Parleq window's Recent Dictations list — the old menu-bar submenu is gone), and is written once per accepted dictation via the shared `appendTranscriptHistory` helper — on both accept paths: `AppState.accept()` (normal review) and the quick-mode auto-paste path in `applyResult`. The text-bearing `TranscriptEntry` is **not** `Codable` and has no `write(to:)` path — the transcript text cannot reach disk through the type. The *only* persisted state is the separate, **text-free** `MetricsRecord` → `metrics.jsonl` (§5), which carries no transcript or labels. The `wasCleanupSuccessful` boolean is set from a `lastCleanupFailed` flag that AppState tracks across the `applyResult → accept` handoff, and is reset by `startFreshCapture` and `closeAndReset` so a prior dictation's failure never leaks into a later entry.

### 5.2 Opt-in correction journal (learn from corrections)

"Learn from corrections" is **off by default** (`learnFromCorrectionsEnabled = false`). Enabling it in Settings (or via MDM) consents to two things:

1. **In-memory correction ring** — `CorrectionJournal.swift` appends records to an in-memory ring buffer each time a correction signal is observed: a **voice-refine event** (the instruction the user spoke + the before/after text of the edit) or a **spell-out candidate** (the assembled term + the cleaned text it appeared in). The journal captures only **correction events the user explicitly triggered** — not a running log of every dictation — but a single refine record holds that edit's full before/after cleaned text, which for a long dictation can be that dictation's entire cleaned output (so these are not "snippets"). The text is the same class as cleaned-transcript text. Analysis always goes to the configured **cleanup** provider — no new provider, service, or network destination. Note one nuance: a dictation cleaned by a different tier (a context-model or picker-override turn) was processed by a different configured model, so for those dictations the cleanup provider receives the correction text during analysis without having originally cleaned it — but it remains a provider the user configured and authorized. The ring is **never written to disk** and is cleared when Parleq quits, exactly like Recent Dictations text (`TranscriptHistory`).
2. **Periodic off-hot-path analysis** — `LearningAnalyzer.swift` wakes on a threshold-plus-idle trigger, reads the in-memory ring, and calls the **already-configured cleanup LLM** to propose dictionary changes. This is **not a new network boundary**: the same provider that already receives cleanup payloads also receives these snippets during analysis. Analysis is always off the dictation hot path — it never delays a dictation or blocks the overlay.

**Durable output.** The only on-disk artifact produced by this feature is **learned dictionary terms**, written into the existing `~/.parleq/config.json` — the same file that holds hand-added dictionary terms. No raw correction snippet text ever reaches `config.json`; the file receives structured term entries (word + context + aliases), identical in format to user-authored terms. This is **enforced at the parse boundary**, not left to the model's good behavior: `LearningAnalyzer.validate` bounds every durable field to a short, word-level value (`maxDurableFieldChars`/`maxDurableFieldWords`) and **drops any proposal whose term — or any alias — reads like a sentence**, so a dictation-derived phrase can never survive into a dictionary entry. The freeform `context` label is additionally collapsed to a single short line (`maxDurableContextChars`), and **auto-applied (unreviewed) entries persist no context at all** (`LearnedStore.applyTermProposal` writes `context: nil`) — only the canonical term and its bounded aliases. A context label persists only when the user **explicitly accepts** a suggestion, having seen the operation and the exact fields in the Learned view first. The in-memory learned-changes store (pending suggestions + applied-changes log for revert) is likewise process-memory only and cleared on quit.

**Retention and compliance posture:**

- Count and age caps are configurable (`learnedCorrectionsMaxEntries` and `learnedCorrectionsRetentionHours`) and enforced as the ring fills. Either cap set to `0` disables the ring entirely — nothing is recorded, analysis never runs. Setting both to `null` (the default) means uncapped on count and age within the session: the in-memory ring grows with the number of corrections until Parleq quits (when it is dropped). Set a count or age cap to bound it. Since no data reaches disk, there is no file to purge.
- When the feature is disabled via Settings, Parleq **offers to clear** the in-memory ring immediately (a confirmation with Clear / Keep). Either way the ring is dropped when Parleq quits.

**MDM control.** Three MDM keys let a fleet administrator pin the feature off and set retention limits:

| MDM key | Type | Effect |
|---|---|---|
| `learnFromCorrectionsEnabled` | Bool | Set to `false` to force the feature off fleet-wide. When pinned, the Settings toggle is grayed out and the user cannot enable it. |
| `learnedCorrectionsMaxEntries` | Integer | Count cap on the in-memory ring. Set to `0` to disable entirely (nothing recorded, analysis never runs). |
| `learnedCorrectionsRetentionHours` | Integer | Age cap (hours) on ring records. Set to `0` to disable entirely. |

**Upheld invariants.** Enabling "learn from corrections" does not change any existing invariants:
- No audio is written to disk.
- No dictation-derived text is written to disk — the correction ring is process memory only, consistent with Parleq's hard invariant.
- Analysis log output is count-only (e.g. "analyzed N records, produced M proposals") — no correction snippet content in `app.log`.
- Analysis never runs on the dictation hot path.
- No new network boundary is introduced — snippets go to the already-configured cleanup LLM.

**Verification:** `grep -rn "CorrectionJournal\|LearnedStore\|LearningAnalyzer" parleq-app/Sources/` shows the journal's `record(_:enabled:)` gate checks `enabled` before any append to the in-memory ring; `LearningAnalyzer.runIfDue(...)` is invoked only from a detached `Task` in `AppState.finalizeCapture` (after the cleanup/refine result has been applied — off the dictation latency path) and from a low-frequency idle-flush timer; both call sites gate on `learnFromCorrectionsEnabled`, and `runIfDue` is rate-capped so analysis never runs on the hot path.

### 5.3 Contribution capture mode (opt-in, hidden, undocumented)

> **Reviewer note — this is the ONE feature that, when armed, durably writes dictation audio AND transcript content to disk.** It is a deliberate, documented carve-out to the otherwise-absolute invariants "audio is memory-only" (§5, hard invariant #1) and "no dictation-derived text to disk" (#2/#7). It exists so contributors who *choose* to share their dictation data can build a local research corpus for on-device ASR-correction modeling. It is **off by default, absent from the Settings UI, the Setup Wizard, the README, and the public docs**, and is intentionally **not** part of the documented `config.json` schema — disclosed here, and only here, by design.

**What arms it.** A single hidden, hand-edited key in its own top-level `config.json` block, whose value must **exactly equal** an acknowledgment phrase that names the consequence:

```json
"contribution": {
  "capture": "i-understand-this-writes-my-audio-and-transcripts-to-disk"
}
```

A bare `true`, any other string, an absent block, an MDM push, or a copied config template **do nothing** (`Config.contributionCaptureArmed` is the exact-string comparison; default `false`). The acknowledgment-string gate makes inadvertent enablement in a managed environment effectively impossible: nothing short of a human deliberately typing the phrase arms it. The block lives outside the `features` block specifically so a Settings save can never write or re-expose it; `Config.mergeForSave` preserves it verbatim and never emits it from the typed model.

**What it captures** (`ContributionRecorder.swift`, armed only). One record per dictation lifecycle into `~/.parleq/flywheel/`:

- `audio/<uuid>.wav` — the raw 16 kHz mono utterance audio (the carve-out to #1).
- `manifest.jsonl` — one JSON line per dictation: the raw ASR transcript, the LLM-cleaned text, the final accepted text, the full ASR diagnostics (per-token confidence/timing + the vocab-rescorer's original→replacement detail), the dictionary terms in play, provenance flags (reference-windows-attached / transform-applied / refined) and a derived `corrector_pair_eligible`, plus model/version stamps and the destination app bundle id.

Accepted **and** discarded dictations are captured (discarded carry audio + ASR but `final: null`). Storage is **unbounded**; the contributor prunes the directory by hand. `corpus_bytes` on each line tracks cumulative size.

**The app never transmits this data.** `ContributionRecorder` contains **no network code** — capture is purely local to `~/.parleq/flywheel/`. "Contributing" the corpus to the project is a separate, manual act the contributor performs (e.g. copying files); the running app neither uploads nor phones home with any of it. This is verifiable: the file imports only `Foundation` and performs only local filesystem writes.

**Upheld invariants (even when armed):**
- Capture is **off the dictation hot path** and **fail-silent** — a write error (disk full, permissions) is swallowed and logged count-only; it never blocks or breaks a paste.
- Logging remains **count-only** — `logStderr("[parleq] contribution captured (disposition=…)")`. No transcript, audio, or replacement content reaches `app.log`/stderr; the existing `[vocab]` count-only contract is unchanged.
- **Zero overhead when disarmed** (the default): no accumulator is built, no directory is created, nothing is written.

**Verification:** `grep -rn "ContributionRecorder\|contributionCaptureArmed\|contributionCaptureAck" parleq-app/Sources/` shows arming is the exact-string compare in `Config.load`, the recorder is invoked only via `flushContribution` (itself a no-op unless an armed fresh capture produced a record), and the recorder file imports `Foundation` only — no `URLSession`/`Network`/Soto. Confirm a disarmed run never creates `~/.parleq/flywheel/`.

### 5.4 Voice enrollment & acoustic disambiguation (biometric data, Concord builds)

The opt-in **voice-enrollment** feature (Settings → Dictionary; **release/Concord builds only** — fully `#if Concord`-gated out of the public OSS build) lets a user record a few short clips of themselves saying a dictionary term so Parleq can tell that term apart from acoustically similar words **in the user's own voice**, on-device, with no second model and no LLM. A derived per-user **voiceprint** is biometric data (BIPA / GDPR special-category implications) and is handled accordingly.

**Consent.** Enrollment is **off by default** and gated on a one-time consent flag (`voiceEnrollmentConsented`). The wizard's first screen is the biometric-consent step; recording cannot begin until the user grants it. Consent is never MDM-managed — it is always written through from the user's own action.

**On-device, no new network boundary.** Audio capture, the Parakeet encoder pass, embedding pooling, the leave-one-out quality gate, and the live acoustic gate all run **in-process** — no audio or embedding ever leaves the device, and **no listening socket is opened** (the §3.1 invariant is unchanged). The one optional egress is carrier-sentence generation: when the user has a generative LLM provider configured, the wizard may ask it to write example sentences, sending **only the term word itself** (a user-authored dictionary identifier — no dictation content) to the **already-configured** provider; with no generative provider it falls back to built-in templates, so the feature is fully functional offline.

**Always-on encoder-feature capture (Concord build).** So the gate can pool a word's embedding, the Concord build asks FluidAudio to export the Parakeet encoder's acoustic features on every transcribe call (`ASRDiagnostics.encoderFeatures`). This sequence is **transient (~0.8 MB), in process memory only, freed at end of utterance, and excluded from `Codable`** — it is never logged, never serialized to the flywheel record, and never written to disk (§5 "Explicitly NOT written to disk"). The gate itself is **self-gating**: with nothing enrolled it is a no-op with byte-identical baseline output.

**Persistence.** Enrolled voiceprints persist **encrypted at rest** to `~/.parleq/voiceprints.enc` (AES-256-GCM, device-only non-synchronizable Keychain key, `0600`; see the §5 table). The voiceprint file's stored content is derived embeddings only — never audio. On load, templates whose encoder stamp matches the current identity or a declared legacy-compatible stamp (including the grandfathered `0.15.4-encoder.1` stamp) are kept active and match normally. Only templates with an **unknown and incompatible non-empty stamp** are parked **inert** (kept on disk under their old stamp, never silently deleted) and handed to a non-destructive, quality-gated migration pass that re-derives them under the current encoder (see "Durable voiceprints" below); ones it cannot re-derive surface an in-app re-enroll prompt.

**Durable voiceprints — conditional enrollment-audio storage.** To let a voiceprint survive a future ASR-encoder change **without forcing the user to re-enroll**, the durable-voiceprints feature can additionally retain the user's short voice-**enrollment** carrier clips, encrypted at rest, in `~/.parleq/enrollment-audio.enc` (AES-256-GCM under the **same** device-only Keychain key + `0600` atomic write as `voiceprints.enc`). This is the one place enrollment **audio** touches disk, it is **biometric**, and it is **doubly gated and fail-closed**: written only when the user has accepted a **fresh amended consent** (`voiceClipStorageConsented` — users who consented under the prior "clips are discarded" copy stay unconsented until they re-accept) **AND** the storage toggle is on (`voiceprintClipStorageEnabled`, user- or MDM-controlled; a malformed MDM value disables it). The clips are **never network-transmitted**, never contain dictation audio (only the enrollment carrier sentences), and are deleted with the term's voiceprint / "Delete all voiceprints". When the storage toggle is **off**, the file is **erased at launch on every startup path** (bundled ASR, custom `asr.endpoint`, or an ASR load failure), so pushing the kill-switch after a user enrolled actually removes the stored clips. The dictation hot path still writes no audio. See the §5 written-to-disk table.

**Zero-harm posture.** The gate only ever **removes an over-fire it can acoustically confirm** — it never introduces a new substitution. A substitution **veto** (keep the heard word instead of swapping in the dictionary term) is strictly zero-harm. The one path that can change ASR output is **validation revert** (the recognizer emitted the term verbatim, likely a biasing over-fire, and the gate reverts to the confusable); it fires **only on a confident contrastive margin** (`margin < -revertMargin`, default 0.05) and a near-tie deliberately keeps the emitted term, bounding any false-revert. A poor, low-quality, mislocalized, or absent template simply leaves the gate quiet.

**Deletion.** Per-term **Remove voiceprint** (also removed when the dictionary term is deleted) and a global **Delete all voiceprints** clear the in-memory store and rewrite/remove the encrypted file. Everything is also wiped from memory on quit.

**Verification:** `grep -rn "encoderFeatures" parleq-app/Sources/` shows the field is omitted from `ASRDiagnostics`'s `CodingKeys`/`encode(to:)` (decodes to `nil`); `grep -rn "EncryptedVoiceprintStore\|voiceEnrollmentConsented" parleq-app/Sources/` shows the AES-GCM store and the consent gate; the `[voiceprint]` log lines are count/identifier-only (term name + counts, no embeddings, no transcript).

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
| Org-configured IdP issuer (e.g. `<tenant>.okta.com`, or a self-hosted Keycloak host) | Enterprise OIDC federation: discovery (`/.well-known/openid-configuration`), token endpoint (code→token exchange + refresh-token rotation), revocation endpoint (sign-out). **OIDC tokens only — never transcript content.** | At sign-in, then periodic near refresh-token expiry | Only reached when an OIDC auth mode is configured (`aws.auth_mode = "oidc"` and/or `vertex.auth_mode = "oidcFederation"`); the issuer is set by the org (`oidc.issuer`, MDM-pinnable). Don't configure OIDC to disable. |
| `sts.<region>.amazonaws.com` | AWS leg of OIDC federation: `AssumeRoleWithWebIdentity` — the OIDC **ID token** goes out, **temporary AWS credentials** come back. This is an **unauthenticated** STS call (no Parleq-held AWS secret; the role's trust policy is the gate). **No transcript content.** | Periodic, near the federated credential's expiry (refresh-ahead) | Only when `aws.auth_mode = "oidc"`. Use a key-based Bedrock auth mode instead. |
| `sts.googleapis.com` | GCP leg of OIDC federation: Workforce Identity Federation token exchange — the OIDC **ID token** goes out, a **federated access token** comes back (used directly as the Vertex bearer). **No transcript content.** | Periodic, near the federated token's expiry (refresh-ahead) | Only when `vertex.auth_mode = "oidcFederation"`. Use gcloud ADC or service-account auth instead. |
| `raw.githubusercontent.com/BerriAI/litellm/...` | LiteLLM pricing JSON | Once per 24 h, on launch | MDM `livePricingEnabled: false` (fleet) or `PARLEQ_DISABLE_LIVE_PRICING=1` (single user) |
| `huggingface.co` (FluidAudio's loader) | First-run ASR model download (Parakeet TDT v3 ≈ 150 MB; CTC encoder ≈ 97 MB if custom dictionary used) | Once per machine, then cached at `~/Library/Application Support/FluidAudio/Models/` | N/A — bundled ASR requires the models. Switch to a custom `asr.endpoint` to skip. |
| `huggingface.co` (Parleq's `LocalModelStore`) | On-device cleanup model download (Gemma 4 E4B QAT 4-bit, mlx-community checkpoint, **~4 GB**, TLS, anonymous, resume-capable). Carries **no transcript content** — only model weight files. | **Once, user-initiated** (via Settings or Setup Wizard, only when the user selects the on-device cleanup option); cached at `~/Library/Application Support/Parleq/models/`. Never triggered without explicit user action. | Pin `provider` away from `local` via MDM, or block `huggingface.co` at the network layer. Cloud providers and "none" remain fully functional without this download. |
| `parleq.app/appcast.xml` | Sparkle auto-update check | On app launch + every 24 h (default; configurable) | Settings → Updates → "Automatically check for updates" off. The menu-bar "Check for Updates…" item still hits the URL on demand. |
| `github.com/parleq/parleq-speech/releases/download/...` | Downloads the .dmg referenced by the appcast, when the user accepts an update prompt | Per update install (user-initiated) | Don't accept the prompt; the request never fires. |

**Outbound data classifications:**
- **When `provider=concord` (Lightweight, on-device):** transcript text **never leaves the device** for cleanup, and there is **nothing to download** — Concord is a bundled, in-process, deterministic text transform (no model weights, no network of any kind). It makes zero outbound connections. See §7 ("Lightweight (on-device) cleanup — Concord") and the §9.10 accepted-risk note.
- **When `provider=local`:** transcript text does **not** leave the device for cleanup. The only outbound activity of the local tier is the one-time user-initiated model download (above), which carries no user content.
- **When a cloud provider is configured:** Transcript text → the configured **Cleanup** provider for ordinary dictations. A reference-aware dictation's transcript + reference content goes to the **Context** provider/model instead when one is configured (otherwise it also uses the Cleanup provider) — so over time data can reach both configured providers (§3.2).
- Attached reference content (OCR'd window/file/clipboard text, or a PNG when a vision model is selected) → the **Context** provider when one is configured, else the Cleanup provider — **only** when the user used Reference Windows for that dictation (§9.6).
- Reference-aware prompts also carry lightweight **labels** built by `PromptBuilder`: a `Destination: <app>` line (the paste-target app name) and, per attached reference, a `Reference N — <app> — <sanitized window title>` line. So the target app name and the attached windows' app names + (sanitized) titles reach the LLM on reference-aware dictations. **Ordinary (no-reference) cleanup sends none of this** — just the transcript (+ dictionary hint).
- Request metadata (model ID, region/resource, token-shaped JSON body) → the provider. The request-shape parameters (request timeout, per-model thinking budget, max-output-tokens, sampling temperature, TTFT watchdog deadlines) are config-tunable via an advanced `llm.tuning` section (`LLMTuning.swift`; config-file only — no Settings UI, no MDM key). It has no security impact — the defaults preserve the documented behavior, and the only payload that egresses is unchanged (transcript text + the usual token-shaped body); these knobs only adjust timeouts/limits.
- Provider auth travels in headers, never in a URL: `x-goog-api-key` (Gemini), `Authorization: Bearer` (OpenAI; Bedrock `bedrockApiKey` mode), `api-key` (Azure `apiKey` mode), SigV4 signature (Bedrock `sso`/`static`), OAuth bearer (Vertex; Azure Entra).
- Sparkle's update check sends a User-Agent including the app version + macOS version; no other identifying information. The appcast response is a static XML file; Sparkle verifies each enclosure's Ed25519 signature against the `SUPublicEDKey` baked into Info.plist before installing.
- No telemetry, no analytics, no crash reporting to any Parleq-controlled server. Parleq itself has no backend.

---

## 7. Dependencies & supply chain

| Dependency | Use | Pin | Source |
|---|---|---|---|
| Soto (`SotoBedrockRuntime`) | AWS SigV4, ConverseStream, SSO credential resolution | `"7.14.0"..<"7.15.0"` | `soto-project/soto` |
| FluidAudio | In-process ASR (Parakeet TDT v3) + CTC custom-vocab boosting | `"0.14.5"..<"0.14.6"` | `FluidInference/FluidAudio` |
| Concord | In-process deterministic 2nd-pass cleanup ("Lightweight (on-device)" tier) | exact `0.1.4` | `keavi-app/concord` (private; trait-gated — see below) |
| Sparkle | Auto-update framework (Ed25519-signed appcast → download → relaunch). Open-source, the de-facto standard for third-party Mac auto-updates, widely deployed across the ecosystem. | `"2.9.0"..<"2.10.0"` | `sparkle-project/Sparkle` |
| mlx-swift | In-process MLX compute framework for the on-device cleanup tier | exact `0.31.4` | `ml-explore/mlx-swift` |
| mlx-swift-lm | LLM inference layer (MLXLLM, MLXLMCommon) for the on-device cleanup tier | commit `b95dc78` | `ml-explore/mlx-swift-lm` |
| swift-transformers | Tokeniser (AutoTokenizer, BPE/SentencePiece) for the on-device cleanup tier | exact `1.3.3` | `huggingface/swift-transformers` |
| swift-huggingface | Hub client (model download) for the on-device cleanup tier | exact `0.9.0` | `huggingface/swift-huggingface` |
| swift-nio, swift-crypto, swift-certificates | Transitive | (Soto / FluidAudio deps) | Apple |

**mlx.metallib (prebuilt Metal shader library).** MLX's Metal compute kernels cannot be compiled from source via SwiftPM (`swift build` does not run Xcode build phases). `parleq-app/scripts/fetch-metallib.sh` fetches the prebuilt `mlx.metallib` from the matching mlx-swift GitHub release asset at build time, verifies it against a hardcoded SHA-256, and places it in `Parleq.app/Contents/MacOS/` before codesign. The SHA-256 constant and the mlx-swift version must be updated together when the mlx-swift pin is bumped (the script enforces this with a cross-check against `Package.resolved`). This is a build-time supply-chain step: the metallib is signed inside the notarized bundle, and a version mismatch fails the build rather than silently using mismatched kernels.

**On-device cleanup model license.** The runtime checkpoint (`mlx-community/gemma-4-E4B-it-qat-4bit`) is a derivative of `google/gemma-4-e4b-it` and is licensed **Apache 2.0** per its Hugging Face model card and https://ai.google.dev/gemma/docs/gemma_4_license. This is a deliberate change from the custom Gemma Terms of Use that governed Gemma 1–3; Gemma 4 is ungated — anonymous download is permitted, and no model-access approval is required.

**Lightweight (on-device) cleanup — Concord (proprietary, first-party).** Concord is Keavi LLC's closed-source on-device second-pass corrector (the same vendor that publishes Parleq — not a third-party supply-chain dependency). It is the one non-open-source component, so it is called out here explicitly. What bounds its risk:
- **No I/O surface.** Concord is a pure, in-process, *deterministic* text→text transform over the transcript already in memory. It opens no socket, makes **no network call**, writes **nothing to disk**, and holds **no secret or credential**. It is structurally incapable of exfiltrating or persisting dictation data, and that is **verifiable** (§11, check 10: select Lightweight, dictate, observe zero outbound connections). Unlike a cloud provider it *removes* a network boundary rather than adding one; unlike the local Gemma tier it has nothing to download (it is bundled).
- **Deterministic, not ML.** Rule-based normalization (numbers/ITN, compound de-spacing) and Double-Metaphone dictionary matching with a per-word confidence veto — no model weights, no inference, no training corpus, no nondeterminism. Behavior is bounded and predictable.
- **Optional, off by default, absent from the open build.** Cloud cleanup is the default; Concord is an opt-in "Lightweight" tier. It is gated behind the `Concord` SwiftPM trait, so the **public open-source build does not include it at all** (the dependency is pruned from resolution — `parleq-app/Package.swift`, `THIRD_PARTY_LICENSES.md`). Fleets can pin `cleanupProvider` away from it via MDM (§9.7), or simply never select it.
- **Same pinning hygiene** as every other dependency: exact version (`0.1.4`), reviewed bumps.

See §9.10 for the accepted-risk framing and §6 for the egress classification.

**Vendored `VendoredGemma4Text.swift`.** A lightly modified copy of the Gemma 4 text-model graph from `ml-explore/mlx-swift-lm` is vendored in-tree under an MIT license (see `THIRD_PARTY_LICENSES.md` Embedded components). The vendored copy carries a KV-shared gating fix that has not yet landed upstream; it is a temporary measure pending resolution of `ml-explore/mlx-swift-lm#338`, at which point the vendored file will be removed and the upstream dependency used directly.

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

### 8.1 Audit findings & remediations (2026-06 OIDC-federation audit)

A three-dimension adversarial audit (disk persistence / logging / network + miscellaneous) of the enterprise OIDC federation branch (§3.4) was run in June 2026. It found and remediated the following:

| # | Item | Severity | Status |
|---|---|---|---|
| 7 | VertexProvider's auth-retry log line rendered `LLMError.description`, which for `.badStatus(401, body)` included up to 400 chars of raw server-response body, written to `~/.parleq/app.log` — bypassing the `logSafeDescription` redaction used elsewhere. **Pre-existing; predates this branch.** | HIGH | **FIXED** — the retry lines in `VertexProvider` and `BedrockProvider` now render `logSafeDescription` (which emits `<body redacted>` in place of any response body). |
| 8 | The OIDC silent-refresh failure path logged the IdP token endpoint's JSON `error` value unsanitized. The interactive callback path already gated it to the RFC 6749 error-code charset, but the refresh path did not — a nonconforming or hostile IdP could place arbitrary prose in the log. | MEDIUM | **FIXED** — the same charset gate now applies on the refresh path; values that don't conform log as `HTTP <status>` instead of the raw string. |
| 9 | OIDC/exchange HTTP used the shared `URLSession`. Nothing cacheable leaked in practice — all token calls are POSTs — but a future cacheable token response could have landed in `~/Library/Caches`. | LOW (defense-in-depth) | **FIXED** — OIDC/exchange traffic now runs on a dedicated ephemeral `URLSessionConfiguration` with `urlCache = nil`. |
| 10 | A managed (MDM) `oidcIssuer` with an `http://` scheme was accepted at config load and only failed closed later at discovery (and ATS would block the load regardless — never exploitable). | LOW (defense-in-depth) | **FIXED** — https-or-loopback is now validated at config load, with code-only rejection logging (no issuer string in the log). |
| 11 | FluidAudio's DEBUG-level `VocabularyRescorer` logging prints transcript text to stderr; in **debug builds** `LogFile`'s `dup2` persisted that to `app.log`. **Release builds were never affected** — the gate is a compile-time `#if DEBUG` on both the FluidAudio side and Parleq's. | LOW (debug builds only) | **FIXED** — debug builds no longer redirect stderr to `app.log` unless `PARLEQ_DEBUG_LOG=1` is set, so transcript-bearing third-party debug output stays on the terminal and off disk. |

**Areas verified clean in the same audit:**
- **Keychain footprint is bounded.** The OIDC accounts hold only the refresh token and a bounded identity struct (issuer / sub / email / name) — no access token, no ID token (§4.1).
- **No token can reach `config.json`.** The token-bearing types are structurally excluded from the config serializer; the file receives auth-mode and issuer/client-ID config only, never a token or credential.
- **No secret in any URL.** No token or credential appears in a URL query string anywhere on the OIDC path — all token calls carry secrets in POST bodies or `Authorization` headers only.
- **STS form body is injection-safe.** The GCP STS exchange percent-encodes its form body, so MDM-pinnable values (issuer, provider resource) cannot inject extra parameters.
- **No shell-outs in OIDC modes.** The federation paths invoke no CLI — unlike the gcloud-ADC / Azure-Entra modes, there is no spawned process to inherit a manipulated environment.
- **No side-channel egress.** No pasteboard write, no `NotificationCenter` post, and no telemetry carries any OIDC token or identity off the process.
- **Transport floor enforced.** HTTPS-or-loopback is enforced on the issuer and on every discovered endpoint (token, exchange, **revocation**); with no ATS exceptions, an `https → http` redirect dies at the transport layer.
- **Anti-replay primitives are fresh and single-use.** `state`, `nonce`, and the PKCE verifier are generated fresh per sign-in and consumed once; the callback validates `state` first, before any other field.

---

## 9. Known limitations & accepted risks

### 9.1 Cleanup payload sent to LLM provider

When LLM cleanup is enabled (default), the **raw transcript text** (plus any attached reference content — §9.6) is sent to a configured LLM provider as part of the cleanup request. This is intentional — it's the entire point of the cleanup pass — but it means transcript content crosses an organizational boundary. **Both tiers matter:** ordinary dictations go to the **Cleanup** provider, and reference-aware dictations go to the **Context** provider when one is configured (otherwise the Cleanup provider) — so **both configured providers must satisfy your data-residency policy**, not just one. Mitigation: choose providers that match it — Gemini = Google; OpenAI = OpenAI; Vertex AI = Google but in *your* GCP project (IAM + audit logs); Bedrock = your own AWS account; Azure OpenAI = your Microsoft tenant — and on managed Macs pin **both** tiers fleet-wide via MDM (§9.7).

If transcript content must never leave the device, there are two options:

1. **On-device cleanup (`provider=local`)** — selects `LocalLLMProvider` (in-process MLX inference). Transcript text is processed entirely in-process; **no cleanup payload egresses**. The only network activity of this tier is the one-time user-initiated model download from `huggingface.co` (~4 GB, carries no user content). Select in the **Setup Wizard** or Settings → Cleanup → provider picker. Requires a 12 GB+ Mac and the one-time model download before it can be used.
2. **No cleanup (`provider=none`)** — pastes the raw ASR transcript with no LLM pass at all. Choose **"None — skip cleanup, paste raw ASR"** in the **Setup wizard** (menu bar → **Run Setup…**, re-runnable any time), set `llm.provider = "none"` in `~/.parleq/config.json`, or pin `cleanupProvider` off via MDM. (The in-app **Settings** picker does *not* list None — it's a setup-wizard / config / MDM action.)

Either option ensures transcript content never leaves the device at the LLM step. `provider=local` requires that the model download has occurred and the Mac has sufficient RAM; `provider=none` has no prerequisites.

`provider = none` is a **global off switch**: `Config.modelForInvocation` short-circuits to the (nil) cleanup provider for *every* dictation — including reference-aware ones — when `llmProvider == "none"`, and `main.swift` does not build a Context provider in that case either. So both ordinary and reference-aware dictations paste the raw on-device ASR and make **no** LLM call; you do **not** need to separately clear `context_model`. One caveat: merely *not configuring an API key* is **not** sufficient — the federated auth modes (Bedrock SSO, Vertex ADC, Azure Entra) need no key yet still egress; you must explicitly select `none`.

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

Beyond enabling/disabling features, managed configuration can pin *where data goes* so a user can't redirect it to a personal account: cleanup/context provider, allowed providers + models (`cleanupProvider`, `cleanupAllowedProviders`, `cleanupModel`, `contextProvider`, …), auth mode (`bedrockAuthMode`, `azureAuthMode`, `staticApiKeysAllowed`), the Sparkle update feed URL, logging mode, transcript-history retention, the **ASR endpoint** (pinning it closes the "point dictation audio at an arbitrary server" gap within an otherwise-allowed config), and the **correction-journal feature + retention** (`learnFromCorrectionsEnabled`, `learnedCorrectionsMaxEntries`, `learnedCorrectionsRetentionHours` — see §5.2 and §9.8). The enterprise OIDC federation surface is pinnable the same way: `oidcIssuer`, `oidcClientID`, `oidcScopes`, `oidcEphemeralBrowserSession`, `oidcRedirectURI`, `oidcExtraAuthParams`, `awsRoleArn`, `awsSessionDurationSeconds`, and `vertexWorkforceProvider` (see §3.4). The authoritative key set lives in `ManagedConfig.swift`; the public reference is [parleq.app/docs/managed-configuration](https://parleq.app/docs/managed-configuration/).

`cleanupProvider` accepts `gemini`, `openai`, `vertex`, `bedrock`, `bedrock-bearer`, `azure`, `none`, and `local`. Orgs may pin `local` to enforce on-device-only cleanup for compliance — this ensures transcript text never crosses a network boundary at the LLM step. Note that `local` has no auth-mode sub-key and requires the model to be pre-downloaded (or the Setup Wizard run with network access to `huggingface.co`) before dictation cleanup will work; pinning it without pre-downloading leaves cleanup non-functional until the download completes.

### 9.8 Opt-in correction journal (learn from corrections)

When a user enables "Learn from corrections," correction snippets (refine instructions + before/after edits; assembled spell-out terms + cleaned lines) are held **in process memory only** and periodically sent to the **already-configured** cleanup LLM for analysis. They are **never written to disk** and are cleared when Parleq quits. This is not a new egress boundary — analysis always goes to the user's configured **cleanup** provider, the same one that receives cleanup payloads. (A dictation cleaned by a context-model or picker-override tier was processed by a different configured model; its correction text still reaches the cleanup provider during analysis — a provider the user configured and authorized, with no new destination introduced.) The data class is the same as cleaned-transcript text — a refine record's before/after can be a full cleaned dictation; the journal captures only correction *events*, not every dictation — and unlike a file-backed journal there is no on-device persistence of dictation-derived text.

**Risk and mitigation:**
- A user with `learnFromCorrectionsEnabled = true` accumulates correction snippets in memory for the session (bounded by the retention caps) and sends them to the cleanup LLM during periodic off-path analysis. Both actions are fully visible in Settings.
- For compliance fleets where no dictation-derived text should reach the cleanup LLM even via periodic analysis, pin `learnFromCorrectionsEnabled = false` (or `learnedCorrectionsMaxEntries = 0`) via MDM. The feature is off by default, so no action is required if the fleet is managed and the default config is deployed.
- For fleets where the feature is allowed but the in-session ring should be bounded, pin `learnedCorrectionsMaxEntries` and `learnedCorrectionsRetentionHours` via MDM (§5.2).
- The feature can be disabled at any time from Settings → Privacy & Features; disabling offers to clear the in-memory ring immediately (a Clear All / Keep Data confirmation), and it is cleared on quit either way. No restart required.

### 9.9 Custom URL-scheme callback hijack (OIDC)

The enterprise OIDC flow (§3.4) completes through a custom URL-scheme redirect (`parleq-auth://oidc/callback`, or an org-pinned `oidcRedirectURI`). On macOS, scheme registration is not exclusive — another locally-installed app could register the same scheme and attempt to intercept the authorization callback. This is a known platform limitation of native OAuth, not specific to Parleq.

**Mitigation:** the flow uses **PKCE** — the authorization code is cryptographically bound to a verifier this client holds in memory and never transmits in the authorization request, so an interceptor that captures the redirect cannot exchange the code without the verifier — and **`state`**, which binds the callback to the in-flight sign-in session (validated first in the callback, before any other field). An attacker who registers a colliding scheme therefore captures a code they cannot redeem. Residual risk is accepted as inherent to native OAuth on the platform.

The **loopback-redirect** sign-in (§3.4.1) does not register a URL scheme at all, so it is not exposed to scheme-collision interception; its callback is delivered over a 127.0.0.1-only loopback connection to a same-user listener. It carries the **same PKCE + state** protection, and a co-resident local process racing for the ephemeral port still cannot redeem a captured code without the in-memory verifier.

### 9.10 Closed-source on-device component (Concord)

The "Lightweight (on-device)" cleanup tier is powered by **Concord**, Keavi LLC's proprietary (closed-source) on-device corrector. It is the only non-open-source component in Parleq, so we call it out explicitly rather than let a reviewer discover it. The full technical detail is in §7 ("Lightweight (on-device) cleanup — Concord"); the security-relevant summary:

**Why the closed-source nature is contained:**
- **Zero egress, zero persistence, zero secrets.** Concord is an in-process, deterministic text→text transform over the in-memory transcript. It opens no socket, makes no network call, writes nothing to disk, and holds no credential — so it cannot transmit or store dictation data regardless of what its source contains. This is empirically verifiable (§11, check 10).
- **First-party, not an external supply-chain party.** Concord is published by Keavi LLC, the same vendor as Parleq itself; trusting it is trusting the app vendor you are already evaluating — no new third party is introduced.
- **Deterministic, not ML** — rule-based + Double-Metaphone with a confidence veto; bounded, predictable behavior (no model, no inference).

**Mitigations / how to avoid it entirely:**
- It is **opt-in and off by default** (cloud cleanup is the default).
- The **public open-source build excludes it** (trait-gated — §7); building from source without it is the default.
- Fleets can pin `cleanupProvider` to an open tier (`gemini`/`vertex`/`bedrock`/`azure`/`local`/`none`) via MDM (§9.7), guaranteeing Concord is never engaged.

Residual risk: organizations whose policy forbids *any* closed-source code in the dictation path should select an open cleanup tier (or `none`); doing so removes Concord from the data path entirely.

---

## 10. Where to look in source

For reviewers who want to verify the claims above against code:

| Concern | File(s) |
|---|---|
| Audio in memory only | `parleq-app/Sources/ParleqAppCore/AudioRecorder.swift`, `LocalASR.swift`, `ASRClient.swift` |
| No listening sockets on the default path | `parleq-app/Sources/ParleqAppCore/LocalASR.swift` (FluidAudio called as a Swift function, not over HTTP); confirm with `lsof -i -nP -a -p <pid>` on a running Parleq while idle (the `-a` flag is required — without it, lsof ORs the filters instead of ANDing). The **only** socket Parleq binds is the transient 127.0.0.1 OIDC loopback-redirect listener during an active sign-in (§3.4.1) — `LoopbackRedirectServer.swift`; it is absent when no sign-in browser flow is open. |
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
| Correction ring (opt-in; in-memory only; count + age caps) | `parleq-app/Sources/ParleqAppCore/CorrectionJournal.swift` |
| Learning analysis (off-hot-path; count-only logging) | `parleq-app/Sources/ParleqAppCore/LearningAnalyzer.swift` |
| Learned-changes store (auto-apply / suggest / revert; in-memory only) | `parleq-app/Sources/ParleqAppCore/LearnedStore.swift` |
| MDM keys for correction ring (3 keys) | `parleq-app/Sources/ParleqAppCore/ManagedConfig.swift` (search "learnFromCorrections") |
| OIDC loopback-redirect listener (127.0.0.1-only, ephemeral port, static response, defer teardown) | `parleq-app/Sources/ParleqAppCore/LoopbackRedirectServer.swift`; selection + browser open in `CompanyAccountView.swift` (`makeOIDCAuthenticator` / `loopbackRedirectAuthenticator`); validator in `ManagedConfig.swift` (`validateOIDCRedirectURI`) |
| On-device cleanup (in-process MLX inference, no network boundary on the cleanup path) | `parleq-app/Sources/ParleqAppCore/LocalLLMProvider.swift` (provider impl + enable_thinking:false invariant), `ResidencyManager.swift` (model load/unload lifecycle), `LocalModelStore.swift` (download + state machine), `LocalTokenizerBridge.swift` (tokenizer + chat-template formatting), `VendoredGemma4Text.swift` (temporary vendored Gemma 4 model graph) |
| On-device model download (user-initiated, huggingface.co, ~4 GB, no transcript content) | `parleq-app/Sources/ParleqAppCore/LocalModelStore.swift` (`download()` method, `HubClient` usage); `fetch-metallib.sh` (SHA-256-verified prebuilt Metal shader library) |

---

## 11. Reviewer cheat sheet

If you have 15 minutes, verify the high-impact claims by running these from a checkout of the repo:

```bash
# 1. Confirm there is no longer a sidecar package or supervisor.
test ! -d third_party/fluidaudio-sidecar && echo "OK: sidecar package removed"
test ! -f parleq-app/Sources/ParleqAppCore/SidecarSupervisor.swift && echo "OK: supervisor removed"

# 2. Confirm no listening sockets are bound by a running, IDLE Parleq.
#    (Launch /Applications/Parleq.app first; replace the pgrep target
#    with `pidof ParleqApp` if pgrep doesn't match. The -a flag ANDs
#    the -i and -p filters together — without it, lsof ORs them and
#    you'll see every listening socket on the machine, not just the
#    ones owned by Parleq. The ONE expected exception is a transient
#    127.0.0.1 listener that appears ONLY while an enterprise OIDC
#    loopback sign-in browser flow is open, and disappears the moment
#    it completes — see §3.4.1. Run this check when not signing in.)
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

# 9. Confirm on-device cleanup has no HTTP request path.
#    Expected: no matches (LocalLLMProvider runs in-process; the only
#    HF network call is the model download in LocalModelStore).
grep -rn "URLSession\|URLRequest\|http" parleq-app/Sources/ParleqAppCore/LocalLLMProvider.swift

# 10. Confirm the Lightweight (Concord) tier makes no network calls.
#     Static: the Parleq-side wrapper has no HTTP path (no matches expected).
grep -rn "URLSession\|URLRequest\|http" parleq-app/Sources/ParleqAppCore/ConcordCleanupProvider.swift
#     Runtime: with cleanupProvider=concord, dictate, and confirm no new
#     outbound connection is opened by Parleq (expected: none — Concord is a
#     bundled, in-process, deterministic transform; §7, §9.10).
lsof -nP -iTCP -a -p "$(pgrep -x ParleqApp)" | grep -v LISTEN
```

For the operational side (AWS account configuration, Identity Center, Bedrock model access), see [`docs/SETUP.md`](SETUP.md). For the public-facing architecture walkthrough, see [parleq.app/how-it-works](https://parleq.app/how-it-works/).

---

## Appendix: change log relevant to security posture

- **2026-06-10** (on-device cleanup tier): documented the new on-device cleanup option (`provider=local`, §1, §2, §9.1): in-process MLX inference where transcript text crosses no network boundary at all. The ONE new outbound flow: user-initiated Gemma 4 E4B model download from `huggingface.co` (~4 GB, TLS, anonymous, resume-capable, no user content; §6). Noted the eval/debug env vars `PARLEQ_LEARN_TRIGGER` / `PARLEQ_LEARN_MIN_INTERVAL` are credential-free debug-only tuning knobs. Noted the bundled `mlx.metallib` prebuilt Metal shader library fetched at build time from the pinned mlx-swift release asset, SHA-256-verified (§7). Added 4 MLX/HuggingFace dependencies to §7. No new on-disk transcript store; no new listening socket; no new Keychain item.
- **2026-06-08** (v0.22.0): the enterprise-federation fail-closed "signed out" notice in the dictation overlay is now clickable — tapping runs the **same** interactive OIDC sign-in as Settings → Company Account against the one shared session, then offers an opt-in re-clean of the retained raw transcript. Scoped to the federation case only (Bedrock `oidc`, Vertex `oidcFederation`/`googleOAuth`), keyed off a typed signal rather than the hint text. **No new trust boundary, listening socket, on-disk store, or token surface** — only sign-in *state* (not tokens or identity) crosses into the overlay layer; the loopback listener (§3.4.1), when that redirect is configured, can now be opened from the overlay but is otherwise unchanged (see §3.4 fail-closed bullet). Re-cleaning is never automatic.
- **2026-06-08** (v0.21.0): added a new **metadata-only** on-disk artifact pair — `~/.parleq/preset-usage.jsonl` + `~/.parleq/preset-usage-declined.json` (timestamps, preset IDs/names, app bundle IDs, `manual`/`default` source, declined (app, preset) pairs; **no transcript content**), same compliance class as `usage.jsonl`/`metrics.jsonl`/`pricing-cache.json` (§2, §5). Added the optional `oidc-client-secret` Keychain item — **client configuration, not a user credential**, survives sign-out, needed only for Google "Desktop app" OAuth clients (§4.1); owner-stamped with its client_id/issuer so a stale secret is never sent to a different reconfigured client. Documented the config-only `llm.tuning` request-shape knobs (timeout / thinking budget / max-output-tokens / temperature / TTFT deadlines — no Settings UI, no MDM key; **no security impact**, defaults preserve documented behavior) (§6). Enumerated the in-memory-only Learned **activity log** and **dismissed-preset hashes** in the "explicitly NOT written to disk" list (§5). No new egress boundary, no new transcript-bearing store, no new MDM surface.
- **2026-06-06** (OIDC loopback-redirect sign-in): added the Google "Desktop app" loopback-redirect authenticator (§3.4.1). This introduces the **one precisely-scoped exception** to the "no listening sockets" posture: a transient 127.0.0.1-only listener on an ephemeral port, bound only for the duration of an active interactive sign-in, single callback, static response, immediate defer-based teardown, no callback URL/query logged. Updated the no-listening-sockets language (§3, §3.1), the lsof verification claim + cheat-sheet command, the §9.9 callback-hijack note (loopback registers no scheme; same PKCE+state), and the §10 source map. Config validator relaxed to accept `http://` + loopback redirects (still rejects `https://` and non-loopback `http://`). No new on-disk store of any kind.
- **2026-06-05** (enterprise OIDC federation): documented the corporate OIDC sign-in path (§3.4) and its destination-pinning MDM surface (§9.7); added enterprise client-provisioning guidance for the `googleOAuth` Vertex mode (Internal-audience client vs. Workspace-Trusted client ID; cloud-platform-scope/IAM trust model) in §3.4; recorded the 2026-06 three-dimension OIDC-federation audit (§8.1, findings #7–#11: VertexProvider/BedrockProvider retry-log body-redaction, refresh-path IdP-error-code charset gate, ephemeral no-cache URLSession for token traffic, https-or-loopback validation of the MDM `oidcIssuer` at config load, and debug-build stderr→`app.log` opt-out); added the custom URL-scheme callback-hijack accepted-risk note (§9.9). No new on-disk store of tokens or transcript content; tokens are memory-only except the Keychain refresh token + bounded identity snapshot.
- **2026-06-02** (v0.18.0): documented the opt-in "learn from corrections" in-memory correction ring, the off-hot-path `LearningAnalyzer`, the in-memory `LearnedStore`, and the three new MDM keys. No new egress boundary (snippets go to the already-configured cleanup LLM); no audio on disk; no dictation-derived text on disk (ring is process-memory only, cleared on quit); analysis logging is count-only; feature is off by default. Compliance note updated: §5.2 clarifies that the only durable output is learned dictionary terms written to `config.json`.
- **2026-06-01** (v0.17.0): security-review refresh — documented all five LLM providers + their auth modes, Reference Windows screen capture, the text-free `metrics.jsonl`, and the expanded MDM surface. (0.17.0's own feature changes — dictation/review gestures, configurable sounds, self-correction/spelled-out-word cleanup rules — stay within existing trust boundaries.)
- **v0.10.0–v0.16.0** (rolled up): multi-provider LLM auth added — OpenAI direct, Vertex AI (gcloud ADC / service-account JSON), Azure OpenAI (resource key / Entra), and Bedrock `static` + scoped-`bedrockApiKey` modes — with all key-based secrets confined to the Keychain; **Reference Windows** (ScreenCaptureKit capture + Vision OCR; Screen Recording TCC; memory-only); persistent **text-free** `metrics.jsonl` (0.15.0; bounded retention, zero-retention-able); and a much larger **managed-configuration** surface (provider/model/auth pins, `asrEndpoint` pin, `staticApiKeysAllowed`, `livePricingEnabled`, transcript-history retention keys).
- **2026-05-06** (`6d64646`): bearer-token sidecar auth, Keychain Gemini key, Soto pin tightening, LiteLLM disable knob.
- **2026-05-05** (`631f6e0`): compliance pass — audio in memory only, transcript redaction from all logs.
- **2026-05-05** (`50d5905`): Bedrock auth — AWS_PROFILE env-var fallback, Soto INI parser bug documented.
- **2026-05-04** (`3afda0d`): Bedrock LLM provider initial wiring.
