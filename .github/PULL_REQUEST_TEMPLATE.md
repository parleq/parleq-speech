<!--
Thanks for opening a PR! A few notes to make review smooth:

- For non-trivial changes, an issue first helps avoid rework.
- Read CONTRIBUTING.md and CLAUDE.md if you haven't yet — the latter
  documents the load-bearing invariants this codebase preserves.
- Match the existing commit-message style (feat/fix/ui/docs/chore).
-->

## What this PR does

<!-- Short summary of the change. -->

## Why

<!-- The motivation. Reference an issue if applicable: closes #N, refs #N. -->

## How to verify

<!--
What did you do to convince yourself this works?
- `swift build` clean
- `make install` + manual dictation flow
- Tested with provider X / auth mode Y
- Screenshot of the new UI (if applicable)
-->

## Hard invariants preserved

<!--
Tick whichever apply, or strike-through the ones that don't apply to this PR.
See CLAUDE.md → "Hard invariants" for the full list.
-->

- [ ] Audio is still memory-only end-to-end (no new disk writes).
- [ ] No transcript content lands in stderr / log files.
- [ ] Gemini calls still set `thinkingConfig.thinkingBudget = 0`.
- [ ] Bedrock `gpt-oss-*` calls still set `reasoning_effort: "low"`.
- [ ] No server-side conversation history added.
- [ ] Audio still never leaves the device.

## Notes for the reviewer

<!-- Anything weird, anything you're unsure about, follow-ups deferred to later PRs. -->
