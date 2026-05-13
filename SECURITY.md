# Security policy

Parleq is a local-first macOS dictation app. The threat model is documented in [`docs/SECURITY_REVIEW.md`](docs/SECURITY_REVIEW.md) — data flows, trust boundaries, secrets management, and known limitations.

## Reporting a vulnerability

**Please don't open a public GitHub issue for security reports.**

Instead, use one of:

- **GitHub Security Advisories** — go to the repository's [Security tab](https://github.com/parleq/parleq-speech/security/advisories/new) and click "Report a vulnerability." This creates a private advisory only the maintainer can see.
- **Email** — send a description of the issue to the address listed on [the maintainer's GitHub profile](https://github.com/jonyoder). Use a subject line that starts with `[Parleq security]` so it routes correctly.

In your report, please include:

1. The version of Parleq you tested against (`make show-version` or check `Settings → About Parleq`).
2. A description of the issue and why it matters (what an attacker could do).
3. Reproduction steps. A minimal proof-of-concept is appreciated but not required.
4. Any suggested fix or mitigation.

## What to expect

- **Acknowledgment** within 5 business days.
- **Initial assessment** (severity rating + decision on whether to fix) within 14 business days for confirmed vulnerabilities.
- **Fix timeline** scaled to severity: critical issues prioritized; lower-severity issues batched into the next scheduled release.
- **Disclosure**: I'd rather coordinate. If you have a publication deadline, tell me up front and we'll work backwards.

## Scope

In scope for this policy:

- The Parleq macOS app (`parleq-app/`) — single signed binary with FluidAudio running in-process (see `parleq-app/Sources/ParleqApp/LocalASR.swift`).
- Build / signing / notarization scripts (`Makefile`, `parleq-app/scripts/`).
- The website at [parleq.app](https://parleq.app) (`web/`).

Out of scope:

- Bugs in upstream dependencies (Soto, FluidAudio, Apple Swift libraries) — please report those to their respective projects directly. If a Parleq-specific use of an upstream library introduces a vulnerability, that is in scope.
- Issues that require already having full local access to the user's Mac (e.g., "if I have your unlocked machine, I can read your Keychain"). The threat model doesn't claim to defend against local-attacker scenarios.
- Vulnerabilities in cloud LLM provider APIs (Google Gemini, Vertex AI, AWS Bedrock, Azure OpenAI) — report those to the respective vendor.

## Hall of fame

Security reporters who find substantive issues will be credited (with their permission) in the release notes that ship the fix.
