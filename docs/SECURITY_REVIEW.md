# Parleq security review packet

This document is the starting point for an enterprise security / cloudops review of Parleq. It describes what Parleq is, what data it handles, where that data flows, what controls are in place, and what trade-offs were made deliberately.

The intended audience is a security reviewer who needs to decide whether deploying Parleq on a managed workstation meets the organization's policy. We've tried to make every claim grep-able to a specific file in the source tree, so anything here can be verified independently.

**Last reviewed:** 2026-05-07
**Source:** [github.com/parleq/parleq-speech](https://github.com/parleq/parleq-speech) at commit `6d64646` or later
**Review trigger / context:** [docs/SETUP.md](SETUP.md) covers end-user installation; this document covers the security model.

---

## 1. What Parleq is

Parleq is an open-source macOS dictation utility. The user holds a global hotkey (right Option), speaks, and a cleaned-up transcript appears in a floating overlay; on accept, the cleaned text pastes into whatever app was focused. Two passes:

1. **Speech-to-text (ASR):** local FluidAudio Parakeet TDT v3 inference on the Apple Neural Engine via a bundled HTTP sidecar. Audio never leaves the device.
2. **LLM cleanup:** the raw transcript goes to a configurable LLM provider (Google Gemini direct API, or AWS Bedrock — `ConverseStream` against Anthropic Claude or OpenAI GPT-OSS). Cleanup output streams into the overlay; on accept it pastes and is forgotten.

There is no server-side storage of audio or transcripts. Parleq's only persistent state is local user configuration (settings, the user's custom dictionary, a metadata-only LLM-call ledger) under `~/.parleq/`.

---

## 2. Data flow & trust boundaries

```
                          (user speech)
                                │
                                ▼
   ┌──────────────────────────────────────────────┐
   │              macOS user device               │
   │                                              │
   │   ParleqApp ──── audio in memory ────► FluidAudio sidecar
   │       │              (POST /inference,           │
   │       │               localhost-only,            │
   │       │               bearer-token authed)       │
   │       │                                          │
   │       │ ◄──── transcript text ───────────────────┘
   │       │
   │       │
   │       ▼ transcript text only
   └─────────┬─────────────────────────────────────┘
             │
             │  (HTTPS, bearer/SigV4 authed)
             │
             ▼
   ┌──────────────────────┐         ┌──────────────────────┐
   │   Gemini API         │   OR    │   AWS Bedrock        │
   │   generativelanguage │         │   bedrock-runtime    │
   │   .googleapis.com    │         │   .<region>.amazon-  │
   │   ?key=<api-key>     │         │   aws.com            │
   └──────────────────────┘         └──────────────────────┘
                                              │
                                              ▼ (cleaned text)
   ┌──────────────────────────────────────────────────────┐
   │  ParleqApp overlay → user accept → paste to focused  │
   │  app (Cmd-V simulation), pasteboard restored after.  │
   └──────────────────────────────────────────────────────┘
```

### Data classifications

| Data | Where it exists | When |
|---|---|---|
| Raw audio (16 kHz mono WAV) | Process memory only | During a single dictation; freed at end of `AppState.finalizeCapture` |
| Raw ASR transcript | Process memory only | From sidecar response until paste; never written to disk |
| Cleaned transcript | Process memory + paste destination app | In overlay during accept; held in `TranscriptHistory` ring buffer (cap 20, in memory only) for the rest of the session; pasted into target app |
| AWS credentials | macOS-managed AWS CLI cache (`~/.aws/sso/cache/`) | Per the user's existing AWS CLI setup — Parleq does not store these |
| Gemini API key | macOS Keychain (Parleq-managed) | Persistent until user removes |
| User dictionary | `~/.parleq/config.json` | User-authored, local-only |
| LLM-call ledger | `~/.parleq/usage.jsonl` | Token counts + provider/model + target-app bundle ID. **No transcript content.** |

### Trust boundaries

Parleq trusts:
- The user's macOS user account (process isolation, Keychain ACLs, AWS CLI session cache integrity).
- The configured LLM provider's HTTPS endpoint (Google Gemini or AWS Bedrock).
- LiteLLM's community pricing JSON (`raw.githubusercontent.com/BerriAI/litellm/...`) — used for cost reporting only; not load-bearing for any user-facing functionality. **Disable-able via env var.**
- The bundled FluidAudio sidecar process (signed with the same Developer ID as the main app; runs in a localhost-only HTTP server with bearer-token auth).

Parleq does **not** trust:
- Other processes on the user's device (sidecar requires bearer token; Keychain is per-app via service identifier).
- Network attackers between the user and AWS / Google (HTTPS via the system trust store; no certificate pinning, but no plaintext fallback either).
- The user's own custom `asr.endpoint` setting (no shared secret with external servers; user manages their own server's auth).

---

## 3. Authentication & authorization

### 3.1 Sidecar bearer token

`SidecarSupervisor.swift` generates a 256-bit random token (`SecRandomCopyBytes`, fallback to UUIDs) at app launch and passes it to the spawned sidecar via the `PARLEQ_SIDECAR_TOKEN` env var. The sidecar (`FluidAudioSidecar.swift`) requires `Authorization: Bearer <token>` on every `POST /inference`; missing or wrong → HTTP 401.

- Token is freshly generated per app launch — never persisted to disk.
- `/health` (readiness probe) is intentionally unauthenticated: it returns no sensitive state and is needed before token negotiation.
- ASRClient sends the header for the bundled-sidecar path only. External `asr.endpoint` configurations get no token — the user manages their external server's auth themselves.
- The supervisor's warmup probe also sends the header, so it exercises the same auth path as real dictations.

If the env var is unset (e.g., `swift run fluidaudio-sidecar` for local development), auth is disabled with a clear stderr log line. **Production builds always set the env, so production sidecars always require auth.**

### 3.2 LLM provider authentication

- **Gemini direct API:** API key sent as the `x-goog-api-key` HTTP header on every request (Google supports both header and `?key=…` query param; we use the header so the key never appears in any URL string that framework logging could capture). Resolved per-request from env → Keychain (see §4.1) — no plaintext-on-disk fallback.
- **Bedrock:** AWS SigV4 via Soto SDK. Today's `BedrockProvider` calls Soto's `.sso()` credential provider specifically, which resolves credentials through AWS Identity Center cached tokens at `~/.aws/sso/cache/`. Static IAM access keys (`~/.aws/credentials`) and the newer scoped Bedrock API keys are not currently consumed by Parleq — first-class support is tracked in #21. Either way, Parleq never stores AWS credentials directly; refresh is delegated entirely to the user's existing AWS CLI session.

### 3.3 Macros / Login Items

The user's hotkey requires the **Accessibility** TCC grant (CGEventTap-based listener). Microphone TCC is required for AVAudioEngine input. No app-sandbox; Hardened Runtime entitlements are minimal: `audio-input`, `network.client`, `network.server`, `cs.allow-jit` (for CoreML JIT). See `parleq-app/Resources/Parleq.entitlements`.

**Implication:** the Accessibility grant gives Parleq the technical ability to read all keystrokes globally. The actual code uses CGEventTap only for the right-Option press-and-hold detection, but a reviewer should treat this as "Parleq is a privileged process on this machine" and weigh the source code accordingly. Mitigation: open-source code audit, Apple notarization, stable bundle-ID + signature so TCC grants don't silently transfer to a tampered build.

---

## 4. Secrets management

### 4.1 Gemini API key resolution chain

`LLMClient.resolveAPIKey()` checks in order:

1. **Environment variable** `GEMINI_API_KEY` — useful for CI, `swift run` development, dotfile-driven setups. Highest precedence.
2. **macOS Keychain** — Parleq-managed item under service `com.parleq.app`, account `gemini-api-key`, class `kSecClassGenericPassword`, accessibility `kSecAttrAccessibleAfterFirstUnlock`. The Settings UI is the canonical writer (`KeychainStore.setGeminiAPIKey`); never displayed in plaintext after save.

There is **no plaintext-on-disk fallback**. If neither resolution path returns a key, LLM cleanup is disabled and the runtime falls through to pasting the raw ASR transcript (existing best-effort fallback behavior).

### 4.2 AWS credentials

Parleq does **not** store AWS credentials of any kind. All AWS-credential material is read from AWS-CLI-managed locations:
- `~/.aws/config` for SSO profile metadata (start URL, account, role) — the only path consumed today.
- `~/.aws/sso/cache/<sha1>.json` for the OAuth refresh-capable session token.
- `~/.aws/credentials` for static keys (recognized by AWS CLI / Soto in general, but **not currently consumed by Parleq's `BedrockProvider`** — see roadmap note in §3.2).

Today, Soto's SSO credential provider invokes the standard AWS Identity Center token-refresh flow against `oidc.<region>.amazonaws.com` to exchange the cached SSO token for short-lived `AccessKeyId`/`SecretAccessKey`/`SessionToken` triples for each Bedrock call. These short-lived credentials live in the Soto client's in-memory rotating cache and are never persisted by Parleq. When multi-mode auth lands (#21) the same in-memory pattern applies: any pasted Bedrock API keys or static IAM credentials would live in the macOS Keychain (alongside the existing Gemini key) rather than on disk in a Parleq-owned file.

### 4.3 Sidecar bearer token

Generated fresh per app launch, passed to the sidecar via env, never written to disk by Parleq. Lifetime is bounded by the supervisor process; on app quit the token is gone.

---

## 5. Local persistence

Parleq writes the following files. Audited against the enterprise rule "no input data on local computer":

| Path | Content | Compliance note |
|---|---|---|
| `~/.parleq/config.json` | Settings: hotkey, dictionary terms, AWS profile name, model selection, etc. | User-authored config. No transcripts, no audio, no API keys. |
| `~/.parleq/usage.jsonl` | One JSON line per LLM call: timestamp, kind (cleanup/refine), provider, model, input/output token counts, latency, target-app bundle ID. | **Metadata only.** No transcript or cleanup-output content. |
| `~/.parleq/pricing-cache.json` | LiteLLM JSON snapshot (public reference data). | Not user data. Disable-able via `PARLEQ_DISABLE_LIVE_PRICING=1`. |
| `~/.parleq/app.log` | Stderr-redirected diagnostics: phase transitions, ASR latency + length, LLM token counts, supervisor lifecycle messages, error stack traces. Capped at 10 MB; truncates to last 5 MB on launch when over the cap. | **No transcript content, no audio, no auth values.** Same redaction discipline as the rest of the codebase. Skipped in dev mode (when stderr is a TTY). |
| `~/Library/Application Support/FluidAudio/Models/` | Downloaded Parakeet TDT v3 + CTC vocab encoder model weights. | Public model artifacts, not user data. |
| `/tmp/parleq-sidecar.log` | Sidecar startup messages, occasional errors, count-only `[vocab] applied N replacement(s)` lines. | **No transcript content by default.** Per-replacement detail is opt-in via `PARLEQ_VOCAB_TRACE=1`. |

**Explicitly NOT written to disk:**
- Audio bytes (WAV or PCM). `AudioRecorder.stop()` returns `Data` in memory; `ASRClient` POSTs via `request.httpBody` (in-memory), not `httpBodyStream` (potentially file-backed). Hummingbird in the sidecar collects request bodies in memory (`request.body.collect(upTo:)`).
- Transcript text. `AppState`'s ASR diagnostic logs `(N chars / W words)` — length only.
- Cleanup output text **on disk**. Held in process memory only — first in the overlay during cleanup, then in the `TranscriptHistory` ring buffer (see § 5.1 below) for the rest of the session, then gone on app quit. Never serialized to a file.

This was explicitly verified after a full source sweep on 2026-05-06 (see git history for commits `631f6e0` and `6d64646`).

### 5.1 In-memory transcript history (Recent Dictations)

The menu bar's **Recent Dictations** submenu surfaces the last 20 cleaned transcripts so the user can grab one back if a paste lands somewhere unexpected (focus changed mid-flight, target app rejected the paste, etc.). Implementation: `TranscriptHistory.swift`, an `@MainActor` ring buffer of `TranscriptEntry` structs (UUID, timestamp, cleaned text, original target-app name).

**Compliance posture:**
- **Process memory only.** The buffer is held in a singleton `@MainActor` class; never serialized to disk, never sent over the network. Deleted when the process exits — a `Quit Parleq` from the menu bar wipes the entire history.
- **No new persistence surface.** The cleaned text was already in process memory while the overlay was open during cleanup. We hold it for the remainder of the session (capped at 20 entries) instead of dropping it the moment the user pastes. From the policy's perspective, the data classification of "cleaned transcript" is unchanged — it's still in-memory state, just held longer.
- **Cap is hardcoded at 20 entries.** When the 21st dictation is appended, the oldest is dropped. There is no configuration knob to disable history entirely; if a user needs zero history they can either click **Clear Recent** in the submenu after each dictation, or quit + relaunch.
- **No metadata leakage.** The original target-app name (e.g. "iTerm2") is captured for the menu's tooltip and never sent anywhere.

**Click-to-clipboard handler.** When the user clicks a recent entry, the full text is written to the system pasteboard via `NSPasteboard.general.setString(...)`. The pasteboard is a system-level shared resource — once a text value lands there, any process running as the same user can read it via the standard pasteboard APIs. This is the same posture as any user-initiated copy; nothing Parleq-specific. Users on shared machines or with paranoid threat models can avoid the click-to-copy path entirely (the entries remain visible in the menu without copying).

**Threat model.** Memory dumps of a running Parleq process would surface the buffer; this is the same exposure as any in-flight cleaned text (the overlay's `currentText`, the LLM's response stream buffer, etc.). Anyone with the privilege to dump Parleq's memory already has the privilege to dump any process running as the same user, so this is not a new attack surface — it's the existing one with a slightly larger value at risk (last 20 dictations vs. just the current one).

**Verification:** `grep -rn "TranscriptHistory" parleq-app/Sources/` shows the singleton exists at `TranscriptHistory.swift`, is read by `MenuBar.swift` for menu rebuilds, and is written by `AppState.accept()` once per accepted dictation. No `Codable` conformance, no `Data(...)`, no `try ... write(to:)` calls — entries cannot reach disk through the type itself.

---

## 6. Network egress

All network calls are HTTPS via URLSession or Soto, both using the system trust store. No HTTP fallbacks anywhere in the codebase.

| Destination | Purpose | Frequency | Disable? |
|---|---|---|---|
| `generativelanguage.googleapis.com` | Gemini cleanup (provider=gemini) | Per dictation | Switch provider to bedrock |
| `bedrock-runtime.<region>.amazonaws.com` | Bedrock cleanup (provider=bedrock) | Per dictation | Switch provider to gemini |
| `oidc.<region>.amazonaws.com` | SSO token refresh (Bedrock path) | Periodic, when token nears expiry | N/A (managed by Soto) |
| `portal.sso.<region>.amazonaws.com` | SSO GetRoleCredentials (Bedrock path) | Periodic | N/A (managed by Soto) |
| `raw.githubusercontent.com/BerriAI/litellm/...` | LiteLLM pricing JSON | Once per 24 h, on launch | `PARLEQ_DISABLE_LIVE_PRICING=1` |
| `127.0.0.1:8767` | Local sidecar HTTP | Per dictation | N/A (loopback only) |

**Outbound data classifications:**
- Transcript text → LLM provider on cleanup (intentional, the entire point).
- AWS request metadata (model ID, region, request body of token-shaped JSON) → Bedrock.
- API key in Gemini URL query parameter → Gemini.
- No telemetry, no analytics, no crash reporting to any Parleq-controlled server. Parleq itself has no backend.

---

## 7. Dependencies & supply chain

| Dependency | Use | Pin | Source |
|---|---|---|---|
| Soto (`SotoBedrockRuntime`) | AWS SigV4, ConverseStream, SSO credential resolution | `"7.14.0"..<"7.15.0"` | `soto-project/soto` |
| FluidAudio | ASR + custom-vocab boosting | `from: "0.12.4"` (sidecar package) | `FluidInference/FluidAudio` |
| Hummingbird | Sidecar HTTP server | `from: "2.0.0"` | `hummingbird-project/hummingbird` |
| swift-nio, swift-crypto, swift-certificates | Transitive | (Soto deps) | Apple |

`Package.resolved` is **committed** to the repository — fresh clones build against the exact dependency graph we tested. Bumping a dependency requires an explicit `swift package update` + reviewable commit diff. See [CLAUDE.md § Dependency upgrade policy](../CLAUDE.md) for the periodic-upgrade ritual.

The sidecar's `Package.swift` is separate and uses looser pins; it pulls only Hummingbird + FluidAudio.

---

## 8. Audit findings & remediations (2026-05-06 internal audit)

The following items were identified during an internal security audit and have been addressed in commit `6d64646`:

| # | Item | Severity | Status |
|---|---|---|---|
| 1 | Sidecar `/inference` had no authentication; any local process could submit audio. | HIGH | **FIXED** — bearer token auth (§3.1). |
| 2 | Gemini API key resolved from a plaintext-on-disk fallback path. | HIGH | **FIXED** — Keychain is the only on-disk store; the plaintext fallback was removed entirely (§4.1). Closes [#18](https://github.com/parleq/parleq-speech/issues/18). |
| 3 | Soto package pinned `from: "7.0.0"` allowed any 7.x at resolve time. | MEDIUM | **FIXED** — pinned to `"7.14.0"..<"7.15.0"`, `Package.resolved` committed (§7). |
| 4 | LiteLLM JSON download was not user-controllable. | MEDIUM | **FIXED** — `PARLEQ_DISABLE_LIVE_PRICING=1` env var (§6). |
| 5 | Accessibility entitlement = full keystroke read capability. | MEDIUM | **DOCUMENTED** (§3.3). No technical fix possible without losing the global hotkey feature. Mitigated by code transparency, notarization, and stable bundle ID. |
| 6 | `usage.jsonl` records target-app bundle IDs (user behavior metadata). | LOW | **DOCUMENTED** (§5). Not transcript content. Optional config knob to suppress can be added on request. |

---

## 9. Known limitations & accepted risks

### 9.1 Cleanup payload sent to LLM provider

When LLM cleanup is enabled (default), the **raw transcript text** is sent to Google Gemini or AWS Bedrock as part of the cleanup request. This is intentional — it's the entire point of the cleanup pass — but it means transcript content crosses an organizational boundary. Mitigation: pick the provider that matches your data-residency policy (Gemini = Google; Bedrock = your own AWS account).

If transcript content must never leave the device, the user can disable LLM cleanup by simply not configuring an API key. Dictation still works; the overlay shows the raw ASR transcript and the user can edit before pasting. This isn't a documented "feature flag" per se, just a side effect of the existing best-effort fallback path.

### 9.2 Accessibility permission scope

CGEventTap requires the broadest macOS keystroke-monitoring permission. Parleq uses it only for hotkey detection, but the operating system can't enforce that scope. A compromised Parleq build would have the technical ability to log all keystrokes. Mitigations: open-source code, Apple notarization, stable Developer ID, and (for managed environments) MDM policies that track which apps have Accessibility granted.

### 9.3 LiteLLM pricing JSON as third-party trust boundary

We trust an external GitHub-hosted JSON file for accurate model pricing. The worst case if the upstream is compromised is incorrect cost reporting in the Settings UI; we don't enforce any spending limits, so cost lies don't translate to real harm. Disable via `PARLEQ_DISABLE_LIVE_PRICING=1` if even this trust is too much.

### 9.4 No audit trail of dictations

Parleq does not log a per-dictation audit record beyond token counts. Organizations that need a per-dictation log for compliance review would need to build that themselves, or do it at the LLM-provider boundary (e.g., AWS CloudTrail records every Bedrock invocation; Google Cloud's API logs do similarly for Gemini).

### 9.5 No certificate pinning

We rely on the system trust store for TLS validation. If your security policy requires pinned certificates for outbound connections, that's a feature request — not currently implemented.

---

## 10. Where to look in source

For reviewers who want to verify the claims above against code:

| Concern | File(s) |
|---|---|
| Audio in memory only | `parleq-app/Sources/ParleqApp/AudioRecorder.swift`, `ASRClient.swift` |
| Sidecar bearer token | `parleq-app/Sources/ParleqApp/SidecarSupervisor.swift`, `third_party/fluidaudio-sidecar/Sources/FluidAudioSidecar.swift` |
| Sidecar binds 127.0.0.1 only | `third_party/fluidaudio-sidecar/Sources/FluidAudioSidecar.swift` (search "hostname") |
| Keychain for Gemini key | `parleq-app/Sources/ParleqApp/KeychainStore.swift`, `LLMClient.swift:resolveAPIKey()` |
| AWS SSO via Soto | `parleq-app/Sources/ParleqApp/BedrockProvider.swift` |
| Length-only ASR diagnostic | `parleq-app/Sources/ParleqApp/AppState.swift` (search "ASR batch") |
| Count-only sidecar vocab log | `third_party/fluidaudio-sidecar/Sources/FluidAudioSidecar.swift` (search "[vocab]") |
| Usage ledger schema (metadata-only) | `parleq-app/Sources/ParleqApp/UsageLedger.swift` |
| Hardened Runtime entitlements | `parleq-app/Resources/Parleq.entitlements` |
| Recent Dictations in-memory history | `parleq-app/Sources/ParleqApp/TranscriptHistory.swift`, `MenuBar.swift` (`menuNeedsUpdate` rebuild) |
| `Package.resolved` (pinned versions) | `parleq-app/Package.resolved` |
| LiteLLM disable knob | `parleq-app/Sources/ParleqApp/PricingCache.swift` (search "PARLEQ_DISABLE_LIVE_PRICING") |
| Code-signing flow | `parleq-app/scripts/make-app.sh` |

---

## 11. Reviewer cheat sheet

If you have 15 minutes, verify the high-impact claims by running these from a checkout of the repo:

```bash
# 1. Confirm sidecar binds localhost-only (not 0.0.0.0).
grep "hostname" third_party/fluidaudio-sidecar/Sources/FluidAudioSidecar.swift

# 2. Confirm /inference requires Authorization.
grep -n "expectedAuth\|PARLEQ_SIDECAR_TOKEN" third_party/fluidaudio-sidecar/Sources/FluidAudioSidecar.swift

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

- **2026-05-06** (`6d64646`): bearer-token sidecar auth, Keychain Gemini key, Soto pin tightening, LiteLLM disable knob.
- **2026-05-05** (`631f6e0`): compliance pass — audio in memory only, transcript redaction from all logs.
- **2026-05-05** (`50d5905`): Bedrock auth — AWS_PROFILE env-var fallback, Soto INI parser bug documented.
- **2026-05-04** (`3afda0d`): Bedrock LLM provider initial wiring.
