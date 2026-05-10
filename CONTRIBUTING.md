# Contributing to Parleq

Thanks for considering a contribution. Parleq is a small, focused macOS app — issues, feature requests, and pull requests are all welcome.

## Reporting a bug

1. **Check the [open issues](https://github.com/parleq/parleq-speech/issues)** in case it's already filed.
2. Open a new issue using the **Bug report** template.
3. Include the Parleq version (`Settings → About Parleq` or `make show-version`), your macOS version, the cleanup provider you have configured, and a clear repro.

## Suggesting a feature

1. Open a new issue using the **Feature request** template.
2. Describe the use case first ("when I'm doing X, I want…") rather than the implementation. The more we know about the actual workflow, the better the design.
3. Be open to "we don't think we'll do that" as an answer. Parleq deliberately stays small — see [`docs/SECURITY_REVIEW.md`](docs/SECURITY_REVIEW.md) and the README for the design constraints we won't compromise on.

## Reporting a security issue

**Don't** file a public issue. See [`SECURITY.md`](SECURITY.md) for the disclosure process.

## Submitting a pull request

### Before you start

- For non-trivial changes, **open an issue first** to discuss the approach. Saves rework later.
- Read [`CLAUDE.md`](CLAUDE.md) — it's the codebase guide. Module map, hard invariants, build commands, gotchas.

### Building

```bash
git clone https://github.com/parleq/parleq-speech.git
cd parleq-speech
make install         # release build → /Applications/Parleq.app
```

For faster iteration during development:

```bash
cd parleq-app
swift build          # debug build at .build/debug/ParleqApp
swift run ParleqApp  # build + run; TCC permission prompts attribute to terminal
```

There is no formal test target. Verification is `swift build` + `make install` + manual end-to-end dictation.

### Hard invariants

These are documented in [`CLAUDE.md`](CLAUDE.md) and are load-bearing — please don't break them in a PR:

1. **Audio is memory-only end-to-end** — no `/tmp/parleq-*.wav`, no audio cache files.
2. **Transcript content never lands in stderr / log files** — only length-only diagnostics.
3. **`thinkingConfig.thinkingBudget = 0`** on every Gemini call.
4. **`reasoning_effort: "low"`** on every Bedrock `gpt-oss-*` call.
5. **Fresh stateless LLM call per refinement turn** — no server-side conversation history.
6. **Audio never leaves the device** — only post-ASR text crosses the network boundary.

### Style + commit messages

- Match the existing log style — `feat(scope): …`, `fix(scope): …`, `ui(scope): …`, `docs(scope): …`, `chore(scope): …`.
- Multi-paragraph body explaining the *why*. Reference issue numbers (`closes #N`).
- Avoid bundling unrelated changes. One concern per PR makes review faster.

### Code style

- Swift 6 strict concurrency. New code should compile cleanly.
- Comments explain the *why*, not the *what*. Identifier names already say what something is; comments should explain the non-obvious constraints, hidden invariants, or workarounds.
- No new dependencies without discussion. The current dependency tree is small and pinned (see `parleq-app/Package.swift`); adding a transitive dependency means rev'ing lock files and reviewing supply chain.

### What kind of PRs we'll review

- **Bug fixes** with a clear repro. Always welcome.
- **Small, focused features** that fit the existing model (e.g., a new auth mode for an existing provider, a new section in Settings, a new menu item).
- **Documentation improvements** — typos, clarifications, missing context.
- **Provider additions** — yes, in principle, if the provider has a streaming text-completion API and broad enough adoption to justify the maintenance cost.

### What we likely won't ship

- A Parleq-side cloud backend (collecting transcripts, account systems, telemetry).
- Major UI rewrites unless agreed in advance.
- New persistent storage of audio or transcripts on disk.
- Always-on background features that remove the explicit hotkey-press model.

These are scope decisions, not personal — they're the things that keep Parleq small and predictable.

## Questions?

Open a [GitHub Discussion](https://github.com/parleq/parleq-speech/discussions) (if enabled) or a low-priority issue. Or just send a PR with the change and a small description; that's a fine starting point too.
