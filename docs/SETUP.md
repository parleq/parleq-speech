# Parleq setup guide

End-to-end install and configuration. If you're already running and just want to swap LLM providers, skip to [LLM cleanup configuration](#llm-cleanup-configuration).

## Prerequisites

- macOS 14 (Sonoma) or newer.
- Xcode command line tools (`xcode-select --install`) for the SwiftPM toolchain.
- A signing identity, optionally — `make-app.sh` falls back to ad-hoc signing if no Developer ID is available, which is fine for local use. Ad-hoc-signed builds can't enroll as Login Items via the in-app menu but otherwise behave identically.

## Build and install

From the repo root:

```bash
make install
```

That runs `make-app.sh`, which builds the release binary, code-signs the bundle, and copies it to `/Applications/Parleq.app`. The script unlinks any prior install — macOS lets us replace a running .app's files; the running process keeps its mmap'd inode alive until quit. After install:

```bash
open /Applications/Parleq.app
```

Or launch from Finder / Spotlight as you would any Mac app. Parleq runs as a menubar app (no Dock icon) — look for the microphone glyph in the right-hand status area.

### First-launch permissions

macOS prompts twice on first launch:

1. **Microphone** — Parleq captures audio via AVAudioEngine. Required.
2. **Accessibility** — the global hotkey listener uses CGEventTap, which requires Accessibility permission. Required.

Both prompts are bundle-ID-keyed; subsequent rebuilds keep the grants as long as the bundle ID stays stable (it does across `make install` reinstalls).

If you grant both and then upgrade to a build signed with a different identity, macOS may treat it as a new app and re-prompt. Normal.

### Model downloads

On first launch, the in-process FluidAudio engine downloads Parakeet TDT v3 (~150 MB) into `~/Library/Application Support/FluidAudio/Models/`. One-time; the menu-bar icon shows the download glyph until ready. Subsequent launches reuse the cache. If you populate the custom dictionary feature, FluidAudio additionally fetches the CTC vocabulary encoder (~97 MB) — eagerly at startup when your dictionary is non-empty, or lazily on the first vocab-bearing dictation otherwise. Both are cached.

## LLM cleanup configuration

Parleq's cleanup pass runs against one of two providers. Default is **Google Gemini direct API**; **AWS Bedrock** is the configurable alternative for environments where Google API calls aren't allowed (compliance, network policy, etc.).

Switch in **Settings → Cleanup → Provider**. The Settings restart-required banner walks you through quitting and relaunching — required because the provider is read once at app launch.

### Gemini setup

1. Visit [Google AI Studio](https://aistudio.google.com/app/apikey) (sign in with a Google account).
2. **Create API key** → copy it. Free tier is sufficient for dictation use.
3. Make the key available to Parleq. Two options:
   - **Settings UI (recommended)**: open Parleq → Settings → Cleanup (with Provider = Gemini), click **Set Gemini API Key…**, paste the key, Save. Stored in the macOS Keychain — never written to plaintext config files. The Settings UI shows "•••• stored in Keychain" once a key is present.
   - **Environment variable**: add `export GEMINI_API_KEY=...` to your shell rc and launch Parleq from a terminal that has it set. Useful for CI / automated testing. Note that Finder-launched apps don't inherit shell env, so for everyday use the Keychain path is more robust.
4. Open Settings → Cleanup, set **Provider = Google Gemini (direct API)** and **Model = gemini-2.5-flash** (or another from the picker). Quit + relaunch.

Cleanup TTFT against `gemini-2.5-flash` typically lands at 500–700 ms.

### Bedrock setup

Bedrock requires an AWS account with Bedrock model access enabled, plus an authenticated AWS CLI session.

> **Current auth scope.** Parleq's Bedrock provider authenticates via Soto's `.sso()` credential provider, which requires AWS Identity Center (SSO) to be configured. **Static IAM access keys, environment-variable credentials, and the newer scoped Bedrock API keys are not yet wired up** — they're tracked for first-class support in [#21](https://github.com/parleq/parleq-speech/issues/21). If you only have static creds today, you'll need to either configure an SSO profile that wraps your access or wait for the multi-mode auth work.

If your organization already has an AWS account with Bedrock enabled and SSO configured, skip to [Configure Parleq for Bedrock](#configure-parleq-for-bedrock).

#### 1. Create or use an AWS account with Bedrock

If you don't have an AWS account: AWS's [account-creation walkthrough](https://aws.amazon.com/getting-started/). Bedrock is a paid service; pricing is per token (a typical Parleq cleanup is well under a cent per call against Haiku 4.5).

#### 2. Enable model access in Bedrock

This is the step most people miss and the one most likely to silently break Parleq.

1. Go to the Bedrock console → **Model access** in the region you want to use (e.g. us-east-1, us-east-2, us-west-2). **Bedrock model access is per-region** — enabling Anthropic Haiku in us-east-1 does not enable it in us-east-2.
2. Click **Manage model access**, check the box(es) for the models you want — at minimum:
   - **Anthropic Claude Haiku 4.5** (recommended for balanced quality/latency).
   - or **OpenAI GPT-OSS 120B** (faster, slightly weaker on edge cases).
3. Submit. Most models are auto-approved within minutes; Anthropic occasionally requires a brief use-case form.

If you're unsure which models your account already has, check from the command line:

```bash
aws bedrock list-foundation-models \
  --region <your-region> \
  --by-provider Anthropic \
  --query 'modelSummaries[?contains(modelId, `haiku`)].[modelId,inferenceTypesSupported]' \
  --output table
```

#### 3. Configure SSO via AWS Identity Center

Today this is the only Bedrock auth path Parleq's provider supports (see the auth-scope note at the top of this section). For org-managed AWS access this is the standard pattern anyway; for individual-account users without SSO already configured, the steps below set it up.

1. Install the AWS CLI v2: `brew install awscli`.
2. Configure an SSO profile: `aws configure sso`. The CLI prompts for your SSO start URL (looks like `https://d-XXXXXXXXX.awsapps.com/start/`), your SSO region, account, and role. Pick a profile name you'll remember (e.g. `work` or `parleq`).

   ⚠️ **If your SSO start URL ends with `/#`, drop the trailing `#`** when entering it. Soto (Parleq's AWS SDK) has an INI-parser bug that treats `#` as an inline-comment delimiter; AWS CLI itself handles it fine, but Parleq's SSO credential resolution will fail with `tokenCacheNotFound`. The URL works either way; just leave the `#` off in `~/.aws/config`.

3. Verify: `aws sts get-caller-identity --profile <profile-name>` should print your account ID and assumed-role ARN.
4. When the SSO session expires (typically 8h), re-run `aws sso login --profile <profile-name>`.

#### 4. Configure Parleq for Bedrock

In Parleq → Settings → Cleanup:

1. **Provider** = AWS Bedrock.
2. **Model** = pick from the dropdown:
   - `GPT-OSS 120B (no thinking) — fastest` for ~400 ms TTFT.
   - `Claude Haiku 4.5 — balanced` for stronger judgment, ~880 ms TTFT.
   - Or paste any other model ID your account has enabled into the **Custom** field.
3. **Region** = the region where you enabled model access (e.g. `us-east-1`).
4. **AWS profile** = the profile name from step 3 above (e.g. `work`, `personal`, etc.).

   ⚠️ **Always set the profile field explicitly.** The `AWS_PROFILE` env-var fallback only fires when the variable is in Parleq's process environment — which it is when you launch from a terminal but **isn't** when you launch from Finder / Spotlight (launchd gives apps a sparse env). Setting the profile in Settings pins it to `~/.parleq/config.json` and works regardless of launch method.

5. Click **Restart Now** (or Cmd-R) on the orange banner.

After relaunch, dictate once. The cleanup overlay should show streaming output within ~500 ms. If you instead see raw ASR pasted (no LLM cleanup), see [Troubleshooting](#troubleshooting) below.

## Custom dictionary

**Settings → Custom Dictionary** lets you list names and terms that ASR commonly mis-transcribes. Each entry is a term (e.g. `Parleq`, `FluidAudio`, project codenames) plus an optional context blurb that helps the LLM judge whether the surrounding speech actually meant the term. Terms with at least 3 characters bias both:

- **The STT pass**, via FluidAudio's CTC keyword-spotting + rescoring (handles obvious phonetic confusions like *parlay* → *Parleq*).
- **The LLM cleanup pass**, via a smart-vocabulary hint that tells the model to prefer the canonical spelling when context suggests a misrecognition, and to leave the speaker's word alone otherwise.

No restart required after editing the dictionary — the next dictation reads it fresh.

## Troubleshooting

### Where to find logs

Parleq redirects its stderr to `~/.parleq/app.log` automatically when launched from Finder / Spotlight. Tail it during a session to see what's happening:

```bash
tail -f ~/.parleq/app.log
```

The file is capped at 10 MB; on launch, if the log is over the cap, the oldest content is truncated to keep the file at ~5 MB. No transcript content lands in the log — only length-only diagnostics, phase transitions, latency stats, token counts, and error messages. (Full content profile in [`docs/SECURITY_REVIEW.md`](SECURITY_REVIEW.md).)

When running from a terminal (e.g. `swift run` for development), stderr stays on the terminal — the redirect only kicks in for launchd-spawned launches.

### Bedrock: dictation pastes raw ASR (no cleanup)

The most common cause is silent credential failure. Capture the actual error by relaunching from a terminal with the trace flag:

```bash
pkill -f /Applications/Parleq.app/Contents/MacOS/ParleqApp
PARLEQ_BEDROCK_TRACE=1 /Applications/Parleq.app/Contents/MacOS/ParleqApp &
```

Then dictate once and inspect:

```bash
grep -E 'parleq.bedrock|cleanup stream|credential|bedrock raw' ~/.parleq/app.log | tail -20
```

Three failure modes you may see:

| Error | Cause | Fix |
|---|---|---|
| `tokenCacheNotFound` | Soto's INI parser truncated your `sso_start_url` at a `#` | Remove trailing `#` from the URL in `~/.aws/config`, re-run `aws sso login` |
| `No credential provider found` | AWS_PROFILE not set in process env, no `[default]` profile in `~/.aws/config` | Type the profile name into Settings → AWS profile (don't rely on env vars) |
| `ValidationException: model ... is invalid` | Model not enabled in the configured region | Check Bedrock console → Model access in that region; or switch Settings → Region to one where it's enabled |
| `AccessDeniedException ... bedrock:InvokeModel` | IAM role lacks Bedrock permissions | Talk to your AWS admin; the role assumed via SSO needs `bedrock:InvokeModelWithResponseStream` on the model ARN |

When done debugging, kill the terminal-launched instance (`pkill -f ParleqApp`) and relaunch from Finder normally.

### Gemini: "LLM cleanup disabled: missing API key"

The key isn't reaching the launched process. Most likely you tried to set `GEMINI_API_KEY` in `~/.zshrc` and then launched from Finder — Finder-launched apps don't inherit shell env at all. Easiest fix:

- Open Parleq → Settings → Cleanup → **Set Gemini API Key…**, paste the key, Save. Stored in the macOS Keychain — works the same regardless of launch method.

If you really want the env-var path (e.g. for `swift run` development), use `launchctl setenv GEMINI_API_KEY '...'` to push it into launchd's environment for the current login session. The Keychain path is recommended for everyday use.

### First dictation captures only ~90 ms despite a longer press

Open observation, not yet diagnosed. If it recurs reliably, the trace log usually shows `captured 2 KB, 0.09s; utterance too short; skipping pipeline`. Try a second press. Filing detail at the project's issue tracker will help us reproduce.

## Where things live

```
parleq-speech/
├── docs/
│   ├── SETUP.md                 ← you are here
│   └── SECURITY_REVIEW.md       ← data flows, trust boundaries, secrets
├── parleq-app/
│   ├── Sources/ParleqApp/       ← the app itself (Swift, SwiftPM)
│   │                              FluidAudio runs in-process via LocalASR.swift
│   └── scripts/make-app.sh      ← build + sign + bundle
├── web/                         ← marketing site (Astro), deployed to parleq.app
└── Makefile                     ← `make install`, `make notarize`, etc.
```

Per-user state:

```
~/.parleq/
├── config.json                  ← settings (provider, model, AWS profile, dictionary, …)
└── usage.jsonl                  ← LLM call ledger (token counts only, no transcripts)

~/Library/Application Support/FluidAudio/Models/
└── …                            ← downloaded ASR + CTC weights
```
