# Changelog

All notable changes to Parleq are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.43.0] - Unreleased

Speak your punctuation, voiceprints that carry over on their own, and tighter enterprise controls.

### Added

- **Speak your punctuation.** Say "comma", "period", "question mark", "exclamation point", or "open/close quote" and Parleq writes the mark — the way phone keyboards do. It works in on-device **Instant** cleanup (a fast deterministic on-device stage) and in cloud **Polished** cleanup (prompt-guided); **Raw** paste is left exactly as transcribed. On by default.
- **A managed control for refinement.** IT admins can now pin the refinement mode (Raw / on-device Instant / cloud Polished) via a `refinementType` managed-configuration key. And pinning cleanup to "none" for a zero-cloud-egress lockdown now automatically forces refinement off the cloud too — since the 0.40.0 split made cleanup and refinement independent, "Raw cleanup" alone no longer guaranteed no transcript left the Mac; this closes that gap. See the [managed configuration guide](https://parleq.app/docs/managed-configuration/).

### Changed

- **Custom-dictionary corrections are more accurate.** The on-device dictionary stage now decides whether to correct a word by how closely it actually *sounds* like your dictionary term — a phonetic feature-distance gate over CMUdict pronunciations — instead of an ASR-confidence threshold. Fewer missed corrections, fewer wrong ones.
- On-device correction engine updated to Concord 0.6.0 (spoken punctuation + the phonetic dictionary gate).

### Fixed

- **Enrolled acronyms and initialisms carry over across speech-model updates.** When a speech-model change requires your voiceprints to be rebuilt, a term the model now spells out differently (e.g. "E2E" heard as "E to E") is re-derived correctly from your stored enrollment audio instead of being set aside for manual re-enrollment.
- **A clearer signal when a voice term does need re-enrolling.** If a term genuinely can't be carried over, the menu-bar icon's menu now shows a persistent "a voice term needs re-enrolling" item (click it to jump to the Dictionary), so you find out without having to open Settings.

## [0.42.0] - 2026-07-06

Choose your on-device model, and voiceprints that hold up in real sentences.

### Added

- **Choose your on-device cleanup model.** The on-device LLM tier now offers two models: **Gemma 4 E4B** (the default — best quality, ~4 GB download, 12 GB+ RAM) and the lighter **Qwen3-4B** (~2.4 GB download, 8 GB+ RAM), which brings full on-device LLM cleanup to 8 GB Macs. Pick one under Settings → Cleanup → Provider → On-device, or in the setup wizard. Both run entirely on your Mac — no API key, no cloud, no network boundary for your transcript.
- **Borderline voiceprint over-fires are flagged for a one-tap fix.** When the acoustic gate keeps an enrolled term with only low confidence, the review overlay marks it with a distinct dotted underline; pressing its number (⌥+N) opens edit-at-word so you can correct it — which also teaches that term's voiceprint from the correction.
- **Curated cleanup defaults are now visible and overridable.** The review overlay shows when an app's cleanup mode came from a built-in default rather than your global choice (terminals, code editors, and spreadsheets default to fast on-device cleanup so your commands and code aren't sent to an LLM). Settings → App behaviors labels each app's source ("Parleq default" vs "Your setting") and lists the recommended defaults with a one-click override.

### Fixed

- **Enrolled terms hold up in real sentences.** An enrolled term that sounds like an everyday word — e.g. "Keavi" vs "kiwi" — is no longer wrongly reverted when you say it in a sentence that also contains the similar word. The acoustic gate now judges each word from its own audio rather than the whole utterance, so a "kiwi" elsewhere in the sentence can't drag your "Keavi" the wrong way.
- **On-device model names display cleanly and correctly.** The overlay badge and model picker now show the clean model name (e.g. "Gemma 4 E4B") matching the model that's actually running — not a raw checkpoint id or a stale selection after you switch models. Cloud model versions keep their version dots ("2.5 Flash").
- **The on-device Polished provider setting now persists** across restart when the cleanup tier is on-device.
- **A post-pause punctuation quirk no longer inflates a word's audio span**, a cause of voiceprint false-reverts on longer dictations.

### Changed

- Concord correction engine updated to 0.5.1 (over-fire "considered" records + acoustic-gate time spans + gap-aware span alignment).

## [0.41.0] - 2026-07-03

Voiceprints that learn from your corrections.

### Added

- **Voice enrollment now improves itself from your corrections.** If an enrolled term occasionally fires by mistake on a similar-sounding everyday word, correcting it — either by undoing the correction or editing the word back by hand — teaches that term's voiceprint from the corrected word's sound, so the same over-fire stops happening. No re-enrollment needed, and fully on-device: only an encrypted voice embedding is stored (never audio), it never leaves your Mac, and it's deleted along with the voiceprint. On by default for enrolled terms, with a "Refine voiceprints from corrections" switch in Settings → Dictionary; undoing a wrong refinement backs it out automatically.

## [0.40.0] - 2026-07-03

Per-app cleanup, a clearer cleanup model, and more on-device corrections.

### Added

- **Per-app cleanup behavior.** Parleq now tailors how much cleanup each app gets: terminals, code editors, and spreadsheets default to fast on-device tidy-up (no rewriting), while chat and email get fuller polished cleanup. You can override any app and suggest a per-app tone, and a one-time notice explains the new defaults on upgrade so nothing changes silently.
- **A clearer cleanup model.** Cleanup and Refinement are now each a simple choice — Raw, Instant (on-device), or Polished (cloud/on-device model) — sharing one "Polished provider" picker. This makes combinations like "keep everyday cleanup fast and on-device, but use the cloud when I give a follow-up command" straightforward to set up. Switching these no longer requires a restart when the engine is already running.
- **More on-device ("Lightweight") corrections.** a/an agreement is now fixed automatically ("a issue" → "an issue", "a API" → "an API"), and accidental doubled words ("the the") are collapsed — both fully on-device with no rewriting, alongside the existing to/two/too homophone correction.

### Changed

- **Reorganized navigation.** Dictionary and Presets are now top-level items, the Usage screen is folded into Stats as an expandable "Usage & cost" detail, and the sidebar is grouped for easier navigation.

### Fixed

- Fixed a rare tail-drop where the last word or two of a dictation could be lost (on-device speech-model fix).

## [0.31.0] - 2026-07-03

Smarter on-device cleanup: homophone correction.

### Added

- The on-device ("Lightweight") cleanup tier now corrects function-word homophone errors in the to/two/too family — e.g. dictating "delegate to subagents", which the recognizer writes as "delegate two subagents", is fixed automatically. The correction is evidence-based (a bundled language-statistics table plus the recognizer's own per-word confidence) and deliberately conservative: it only fires when the surrounding words clearly support the fix, never on the word's frequency alone, and legitimate counts ("two researchers", "two questions") are left untouched. Validated end-to-end against real recorded dictations with zero false corrections.

## [0.30.1] - 2026-06-30

Fixes for spelled-out acronym correction and voice enrollment.

### Fixed

- Spelled-out digit acronyms — e.g. dictating "E2E", which the recognizer often hears as "E to E" — are now corrected to the acronym on the on-device ("Lightweight") cleanup tier, instead of being mangled (e.g. "E2E to E") or corrected inconsistently. Applies to terms you've enrolled a voiceprint for.
- Voice enrollment no longer learns noisy one- or two-character alternate spellings (e.g. "e", "et") that could trigger spurious corrections, and the post-enrollment summary now lists exactly the alternates that were saved.
- Fixed a crash that could occur when a dictation was started and then immediately cancelled (an empty capture).

## [0.30.0] - 2026-06-29

Voiceprints that survive app updates, broader phonetic correction, and cleaner numbers, percentages, and capitalization.

### Added

- **Your voiceprints now survive speech-model updates.** Updating Parleq's on-device speech model used to discard the voiceprints you'd enrolled, forcing you to re-record them. Parleq can now keep your short enrollment clips encrypted on your Mac and automatically re-derive each voiceprint after a model update — so your enrolled terms keep working without re-enrolling. It's opt-in with a clear consent step, stays entirely on your Mac, and can be turned off — by you, or fleet-wide via an admin/MDM setting that also gates voice enrollment itself (existing voiceprints remain viewable and deletable when enrollment is disabled).
- **Broader phonetic correction for enrolled terms.** On-device cleanup now recovers a dictionary term from a wider range of mishearings — including multi-word run-ons — while the acoustic voiceprint still vetoes an over-correction when what you actually said doesn't match the term.

### Changed

- **Cleaner numbers, percentages, and capitalization.** Large spoken numbers like "eight point nine million" now render as "8.9 million" (previously a run of zeros), spoken percentages like "forty five percent" become "45%", and a number that begins a sentence keeps its capital letter.

[0.30.1]: https://github.com/parleq/parleq-speech/releases/tag/v0.30.1
[0.30.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.30.0

## [0.29.0] - 2026-06-26

Voice enrollment — teach a dictionary term in your own voice so on-device speech recognition can tell two similar-sounding words apart (the fruit "kiwi" vs. the app "Keavi"), entirely on your Mac.

### Added

- **Voice enrollment for dictionary terms.** Some words sound almost identical to a dictionary entry, so speech recognition sometimes swaps the everyday word for your term. You can now enroll a term in your own voice: a short wizard in Settings → Dictionary walks you through reading a few carrier sentences, harvests pronunciation aliases automatically, and optionally records a contrasting word so Parleq can hear the difference. From then on, a per-term acoustic "voiceprint" vetoes and reverts an over-firing correction when what you actually said doesn't match the enrolled term — so the fruit "kiwi" stays "kiwi" and only the real app name becomes "Keavi".
- **Privacy-forward and on-device.** Enrollment derives a compact acoustic embedding, never a recording — your audio is not stored. The voiceprint is encrypted at rest (AES-GCM with a device-only key kept in the Keychain) and never leaves your Mac. Enrollment is opt-in per term and fully deletable from Settings → Dictionary at any time. The disambiguation runs only with the on-device "Lightweight" cleanup tier; it adds no network calls and no cloud dependency.

[0.29.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.29.0

## [0.28.0] - 2026-06-25

More precise dictionary biasing — everyday words are far less likely to be wrongly replaced by a similar-sounding dictionary term.

### Changed

- **Dictionary biasing over-corrects less.** On-device speech recognition is now more conservative about swapping a spoken word for an acoustically similar dictionary term, so common words ("cloud", "item", and the like) are much less likely to be turned into one of your dictionary entries. Tuned against a corpus of real recordings — it cuts these over-corrections by roughly 3× with little effect on genuine recoveries.
- **"Parleq" recognized from one more mishearing.** The built-in "Parleq" dictionary term picks up an additional common way speech recognition mishears the app's name.

[0.28.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.28.0

## [0.27.0] - 2026-06-24

A fast on-device cleanup option, see-and-undo corrections in the overlay, a clearer Cleanup settings layout, and a fix for a corporate sign-in dead-end.

### Added

- **"Lightweight (on-device)" cleanup — instant, private, no cloud.** A new cleanup option that fixes the common things — spoken numbers ("twenty twenty-five" → "2025"), run-together words, and your dictionary terms — entirely on your Mac, in-process, with no network call and effectively zero latency. It's deterministic (rule-based, not an LLM), so it never rewrites or invents text. Choose it under Settings → Cleanup → Provider; cloud cleanup remains the default.
- **See what the on-device corrector changed — and undo any of it.** When Lightweight cleanup makes a correction, the overlay highlights each change with a small number; press ⌥ (Option) + that number to revert just that one back to exactly what you said.
- **Dictionary "spoken forms".** Map a distinctive spoken phrase to a specific term — say "open item terminal" and have it become "open iTerm" — so a reliably-misheard run is corrected as a whole. Add them per term in Settings → Dictionary.
- **Separate Refinement and Context providers.** Voice-refine, the quick-refinement chips, and per-app styling can now run on a different provider than your first-pass cleanup (Settings → Cleanup → Refinement), and reference-window dictations on a Context provider. Both default to following your cleanup provider, so nothing changes unless you set them.

### Changed

- **Clearer Cleanup settings.** The Cleanup pane now reads in order (Cleanup → Refinement → Context), drops the vague "(Advanced)" labels for plain descriptions, and lists cloud providers first so the on-device options read as deliberate opt-ins. Picking Lightweight cleanup explains that refinement needs its own provider (Lightweight can't rewrite text) and helps you set one.
- **Safer learned dictionary terms.** Auto-learned terms must now clear a distinctiveness check before they're allowed to bias speech recognition, fixing a case where everyday words could get over-corrected — making "Learn from corrections" safe to leave on.

### Fixed

- **Corporate sign-in no longer dead-ends.** If corporate (OIDC) sign-in was used only by a refine or context provider — or you switched your cleanup provider around — the Company Account page could appear with no Sign-In button and a misleading "set it up first" notice, with no way forward. The sign-in session is now created whenever corporate sign-in is configured, whichever tier uses it.
- **Accepting a dictation mid-edit keeps your edit.** Clicking Accept while editing the text in place now commits your edit (like pressing Return) instead of pasting the version from before the edit.
- **Per-correction undo always targets the right word.** Fixed a case where undoing one correction after another edit could revert the wrong occurrence when the same word appeared more than once.

[0.27.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.27.0

## [0.26.0] - 2026-06-23

A stability fix for a rare overlay hang, plus advanced opt-in research/contributor tooling that's off by default and invisible unless you deliberately turn it on.

### Fixed

- **Fixed a rare hang where the overlay could get stuck and lock up the app.** After accepting a dictation you'd edited in place, the overlay could enter an internal resize loop — the on-screen window vanished, the app pegged a CPU core and ballooned its memory, and neither the overlay nor the menu bar would respond, forcing a Force Quit. The overlay now refuses to resize once it's been dismissed and detects-and-stops the resize loop if it ever starts, so the hang can't happen.

### Added

- **Opt-in dictation contribution capture (off by default).** A local-only mode for contributors who want to help improve Parleq's on-device transcription correction. When explicitly armed via a manual edit to `~/.parleq/config.json`, it records your own dictations — audio plus transcripts and recognition diagnostics — to `~/.parleq/flywheel/`. It is **off by default**, is not exposed in Settings or the setup wizard, requires a deliberate, self-documenting acknowledgment to enable, and **never sends anything off your device** — the data stays local, and contributing it is a separate manual step you take yourself. Fully disclosed in `docs/SECURITY_REVIEW.md` §5.3.

[0.26.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.26.0

## [0.25.2] - 2026-06-15

A follow-up hotfix: 0.25.1 reverted the speech engine to the wrong version and didn't fully fix the dictionary regression.

### Fixed

- **Custom dictionary over-insertion is now actually fixed.** 0.25.1 reverted the on-device speech engine to FluidAudio 0.14.8, believing the over-aggressive dictionary biasing was introduced in 0.15.x. It wasn't — the regression was introduced in FluidAudio 0.14.8 itself (an upstream rework of the vocabulary-rescoring pipeline, tuned only against long, distinctive terms), so reverting to 0.14.8 still over-fired (ordinary words replaced by your dictionary terms, even with cleanup turned off). Pinned the engine to exactly **0.14.5**, the version 0.24.1 shipped, so transcription and dictionary biasing behave as they did then. The 0.25.1 pin also used a version *range* that silently resolved to the newest 0.14.x; the engine is now pinned to an exact version.

[0.25.2]: https://github.com/parleq/parleq-speech/releases/tag/v0.25.2

## [0.25.1] - 2026-06-15

A hotfix for a speech-recognition regression introduced in 0.25.0.

### Fixed

- **Custom dictionary terms no longer over-insert into transcripts.** 0.25.0 updated the on-device speech engine (FluidAudio 0.15.3), whose reworked transcription pipeline made custom-dictionary biasing far too aggressive — ordinary words could be replaced by your dictionary terms (e.g. "grab the key signals" coming out as "CRAN the key bindex"), most noticeably with several short terms. Reverted the engine to the previous version (0.14.8), so transcription and dictionary biasing behave exactly as they did in 0.24.1. (If you saw this on 0.25.0, marking your dictionary terms "LLM-only" was the interim workaround.)

[0.25.1]: https://github.com/parleq/parleq-speech/releases/tag/v0.25.1

## [0.25.0] - 2026-06-15

A release focused on never losing a dictation — recover one you lost, plus fixes that stop dictations from being lost in the first place — alongside hands-free recording, in-place editing, configurable gestures, a gentler first run, and a rebuilt on-device model downloader.

### Added

- **Recover your last dictation.** If a dictation gets lost — you pressed Esc by mistake, double-tapped Enter too fast, or focus jumped to the wrong app — you can bring it back. Hold your dictation hotkey and tap **R**, or choose **Recover last dictation** from the menu bar, and Parleq re-runs your most recent recording through cleanup and drops it back into the review overlay. The audio is kept in memory only, never written to disk, and is cleared when you quit.
- **Hands-free (continuous) recording.** Double-tap your hotkey and release to keep recording without holding the key down — handy for longer dictations. Tap once to stop. You can change what the double-tap-and-release does in Settings → Hotkey.
- **Edit the transcript in place.** Press **E** in the review overlay to fix a word or two directly, instead of re-dictating or refining. ⌘↵ accepts the edit, Esc discards it.
- **Configurable hotkey gestures.** Settings → Hotkey now lets you choose what a double-tap-and-release does — continuous recording, quick mode, plain dictation, or nothing — so the gesture fits how you work.
- **A live "not hearing your mic" warning.** If your microphone stops delivering audio mid-dictation, the listening view now tells you — instead of you finding out only when nothing pastes.

### Changed

- **A hasty Enter during cleanup now waits for the full result.** Pressing Enter while cleanup was still streaming used to paste a half-finished fragment (or nothing) and cancel the rest. Now it shows a brief "Finishing…" cue and pastes the complete cleaned text the moment it's ready. Pressing Enter on the raw transcript before cleanup has started still accepts the raw text as-is, and Esc still cancels.
- **A smoother first run.** Parleq no longer prompts for Accessibility access at launch before explaining why it's needed. The setup wizard now introduces the permission in context, and the app stays running and usable while you grant it.
- **Rebuilt on-device model download.** Downloading the on-device cleanup model now shows real, byte-accurate progress and resumes where it left off if it's interrupted (even after a force-quit), instead of starting over.

### Fixed

- **Dictations no longer come back silent when another app changes your audio setup.** If another app — a video call, say — switched your microphone to a multi-channel format, Parleq could capture pure silence and discard the whole dictation ("as if I never spoke"). Capture now handles multi-channel input correctly, and rebuilds itself if your input device or format changes mid-dictation, keeping the audio you spoke after the change.
- **A dead microphone is now reported, not hidden.** When a capture genuinely picks up no audio, Parleq shows "Didn't catch any audio — check your microphone" instead of silently closing, so you know to retry.
- **The keyboard can no longer get stuck** if you revoke Accessibility access while Parleq is running.
- **Fast double-taps are recognized again.** A timing floor added in 0.19.0 could reject quick double-taps (especially with Karabiner-Elements installed), silently degrading quick mode and continuous recording. Restored.

[0.25.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.25.0

## [0.24.2] - 2026-06-15

Maintenance release: updates the on-device speech recognition engine to its latest version, with no change to dictation behavior.

### Changed

- **Updated the on-device speech recognition engine (FluidAudio) to 0.15.3.** A routine dependency update. Transcription accuracy and latency are unchanged — verified equivalent to the previous version before shipping.

[0.24.2]: https://github.com/parleq/parleq-speech/releases/tag/v0.24.2

## [0.24.1] - 2026-06-13

On-device cleanup polish: a restart prompt that actually appears when the model is ready, a clearer (and cancellable) download experience, and Parleq's own name recognized out of the box.

### Fixed

- **A clear "Restart" prompt after the on-device model downloads.** Enabling on-device cleanup takes effect after a restart, but the prompt didn't always appear — especially when you enabled it from the Setup Wizard. Now, once the model is ready, Parleq shows a "Restart Now" prompt both in Settings → Cleanup and in the menu bar, so on-device cleanup is one click away from working regardless of where you turned it on.

### Changed

- **Clearer on-device download.** While the model downloads, Parleq now shows an activity indicator (instead of a percentage that could appear stuck) and a **Cancel** button to stop the download.

### Added

- **"Parleq" is recognized out of the box.** New installs ship with the app's own name (and its common mis-hearings) as a built-in dictionary term, so dictating "Parleq" no longer comes out as "Parlek." You can edit or remove it in Settings → Dictionary like any term.

[0.24.1]: https://github.com/parleq/parleq-speech/releases/tag/v0.24.1

## [0.24.0] - 2026-06-12

Two improvements: apply a styling preset to your dictation with a single number key, and on-device cleanup now holds less memory while the model is loaded.

### Added

- **Apply a transform preset by number.** In the review overlay, each of your transform presets now shows a small number, and pressing that number key (1–9) applies it instantly — no need to reach for the mouse. Presets tucked into the "⋯" overflow keep their number too, so the key works whether or not the chip is on screen. Press ? in the overlay to see the shortcut alongside the others.

### Changed

- **On-device cleanup holds less memory while loaded.** The on-device model now caps the pool of reusable GPU scratch buffers it keeps around, so the memory it occupies while loaded stays close to the model's own size instead of climbing several gigabytes higher after a longer cleanup. Idle release is unchanged — the model still frees its memory after a few minutes of not being used — and cloud cleanup is unaffected.

[0.24.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.24.0

## [0.23.0] - 2026-06-10

Parleq can now clean up your dictations entirely on your device — no account, no API key, and no network connection required. If you'd rather keep everything local, this is the option for you.

### Added

- **On-device cleanup — no account or network required.** A new cleanup option runs entirely on your Mac using Apple's Neural Engine. There's nothing to sign up for, no API key to manage, and your transcript text never leaves your device during cleanup. The model downloads once (about 4 GB) and is yours to keep. Available on Macs with 12 GB or more of unified memory; recommended for 24 GB and up.
- **Download in the background, start dictating immediately.** The setup wizard now asks you to choose a cleanup option up front; if you pick on-device, the model starts downloading straight from the wizard. You can dictate with any other configured provider while it downloads, and the switch to on-device happens automatically once the download completes. A progress line in the menu bar keeps you informed.
- **Settings card for the on-device model.** A new card in Settings → Cleanup shows the model's download state and size. Download or remove the model with one button; use it or free the space whenever you like. You can also control how long the model stays in memory between dictations — keep it loaded for instant response, or let Parleq release it when you're not dictating.
- **$0 usage tracking.** On-device runs appear in the usage ledger alongside cloud runs, with token counts and zero cost — so your Usage view stays complete and accurate regardless of which cleanup option you're using.

[0.23.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.23.0

## [0.22.0] - 2026-06-08

When your organization sign-in expires mid-session, Parleq falls back to pasting the raw transcript. Until now, getting cleanup working again meant digging through Settings to sign back in. This release lets you do it right from the overlay.

### Added

- **Sign back in without leaving the overlay.** When cleanup falls back to the raw transcript because your company sign-in expired, the notice in the overlay is now tappable: tap it to sign in with your organization right there, in your browser. Once you're back in, the notice becomes "Signed in — clean up this dictation" — tap it to re-run cleanup on what you just said, so you don't have to re-dictate or hunt through Settings. This appears only for the corporate-federation sign-in case (AWS Bedrock and Google Vertex via your organization); every other cleanup message is unchanged, and re-cleaning is always your choice — nothing runs automatically.

## [0.21.0] - 2026-06-08

This release is about the moment right after you stop talking. The overlay now shows your words the instant they're transcribed and holds rock-steady while the AI cleans them up — no more jumpy panel, no waiting on a blank box. You can accept what you see at any time, talk to it again before it's even finished, and watch a calm "thinking" animation while it works.

### Added

- **Your words appear immediately, and you can accept them any time.** The raw transcript now shows in the overlay the moment speech recognition finishes, dimmed, and is replaced in place by the cleaned version as it streams. Press Enter whenever you like — if cleanup hasn't finished, Parleq pastes what's on screen and stops the cleanup. A distinct multi-color "thinking" animation (vs. the orange listening bars) shows when the AI is working, so you always know which phase you're in.
- **Refine before cleanup even finishes.** Press the hotkey to give a follow-up instruction while the first cleanup is still running, and Parleq now queues it: the cleanup completes, then your refinement applies to the finished text — instead of starting over.
- **Switch models from the overlay.** The model badge during review now lists your provider's model catalog, not just your two configured models, so you can re-run a dictation on a different model with one tap (a per-dictation choice; your configuration is untouched). Switching after a refine correctly re-runs the refinement, not the original cleanup.
- **Preset suggestions and a Learned activity log.** When you keep refining things the same way, Parleq can suggest turning it into a one-tap preset; when you keep using a preset in one app, it can suggest making it that app's default. Every suggestion is yours to accept or dismiss — nothing is applied automatically. The Learned section now keeps a tidy activity log so you can restore a dismissed suggestion or revert an accepted one. (Usage patterns are stored as metadata only — counts and app names, never your dictation text.)
- **Sign in with a browser-based loopback redirect.** Corporate sign-in now supports the loopback redirect that desktop OAuth clients use (Google "Desktop app" clients, and **Microsoft Entra ID**, which requires it) — Parleq opens your real browser and listens on a local-only port just for the few seconds of sign-in. New playbooks for Entra ID (live-validated against AWS Bedrock) join the existing Okta and Cognito guides. An optional client-secret field covers IdPs that require one.
- **Tune request parameters from the config file.** A new `llm.tuning` section lets advanced users set the thinking budget, max output tokens, temperature, request timeout, and the time-to-first-token watchdog deadlines. Sensible defaults are unchanged; long dictations get more headroom (the default output cap was raised so lengthy text no longer truncates).

### Fixed

- **Tapping the hotkey to paste no longer occasionally drops the paste.** When you tapped your modifier hotkey to accept (instead of pressing Enter), the synthesized paste could inherit the still-held modifier and be ignored by the target app — the overlay would close with nothing pasted. Parleq now sends a clean paste and waits for the modifier to release.
- **The overlay holds its size through the whole dictation.** Capture, cleanup, result, and refinement no longer make the panel jump, dip, or drift up the screen; it changes height only when your text genuinely needs more room, and settles once at the end.
- **Cleanup that stalls now recovers gracefully.** A time-to-first-token watchdog retries (or, for slow "thinking" models like Gemini Pro, waits a single generous beat) instead of leaving you staring at a spinner — and the raw text is acceptable the whole time. Gemini Pro is also markedly faster now (its thinking budget is capped instead of running unbounded).
- **Security and privacy hardening.** A reconfigured OIDC client can no longer send a previous client's secret to a different identity provider (the secret is stamped with its owning client). The new usage journal and activity log store metadata only — never transcript text. The loopback sign-in listener is bound to localhost only, exists only during sign-in, and is fully suppressible by pinning the redirect URI via managed configuration. An inert, unused `telemetry` config key was removed.

## [0.20.0] - 2026-06-05

This release brings corporate sign-in to Parleq. One "Sign in with your company account" button connects every employee — not just the ones with cloud CLIs — to your organization's AWS Bedrock or Google Vertex AI, with no per-user API keys to distribute or rotate. Offboarding flows from your identity provider: disable the user there and their next credential refresh fails closed (already-issued cloud sessions expire on their own — keep session durations short). Personal users get something too: sign in with your Google account and dictate straight into Gemini.

### Added

- **Enterprise OIDC sign-in.** A new **Company Account** section in Settings (and the setup wizard) signs you into your organization's identity provider — Okta, Microsoft Entra ID, Amazon Cognito, or any standards-compliant OIDC IdP — through the system browser sheet, with PKCE and your org's own session policies (passkeys and MFA flow straight through; device-based conditional access works wherever your IdP supports it in a browser session). That one sign-in then mints short-lived cloud credentials for **AWS Bedrock** (via IAM role federation, with per-user CloudTrail attribution) or **Google Vertex AI** (via Workforce Identity Federation). The Keychain holds only a refresh token and a sign-in identity snapshot — never a cloud credential; short-lived cloud credentials live in memory and expire on their own. Sign out — or get offboarded at your IdP — and dictation **fails closed** to on-device-only transcription at the next credential refresh (already-issued short-lived sessions run out on their own) rather than falling back to any personal credential.
- **Sign in with Google → Gemini, no broker.** A new Vertex auth mode uses your Google account's sign-in directly as the Vertex credential — no workforce pool, no Cloud organization, no service-account JSON. The simplest path from "I have a Google account and a GCP project" to dictating with Gemini. If your account doesn't grant all the access Parleq asked for (those easy-to-miss consent checkboxes), sign-in now says so immediately instead of failing mysteriously later.
- **Connection doctor.** A **Test connection** button in Company Account walks the three hops — your IdP, the cloud token exchange, and the AI provider — and shows exactly which one failed and what the server said, so the fix (or the screenshot for IT) is obvious.
- **Re-auth that never interrupts.** When your org session eventually expires mid-day, Parleq finishes the dictation it's on, shows a quiet notice, and waits — it never pops a browser in the middle of your sentence.
- **Nine new managed-configuration keys** so IT can pin the whole flow: the OIDC issuer, client ID, scopes, browser-session mode, redirect URI, extra auth parameters, the AWS role and session duration, and the GCP workforce provider. Users sign in; they can't re-point the app at a personal tenant.
- **New documentation**: enterprise SSO setup playbooks for IT admins, a DIY guide for setting up these flows at home (free-tier IdPs, the gotchas that burn hours, and how to drive it with an AI assistant), and a dedicated enterprise page on parleq.app.

### Fixed

- **Security-audit hardening across the new auth engine.** A three-way audit (disk persistence, logging, network) confirmed the core promises — tokens never touch disk outside the Keychain, never appear in URLs, never reach logs — and fixed what it found: server error bodies are now redacted from retry log lines (a pre-existing leak), IdP-supplied error codes are sanitized before logging, the OIDC HTTP stack uses an ephemeral session that can never write a response to the disk cache, and a managed `oidcIssuer` must be HTTPS to be accepted at all.
- **Debug builds no longer write a log file.** Development builds previously mirrored their verbose stderr (which can include transcript text from the speech engine's own debug output) into `~/.parleq/app.log`. Release builds were never affected; debug builds now keep stderr ephemeral unless explicitly opted in.

## [0.19.0] - 2026-06-04

This release puts your favorite rewrites one tap away. Define your own transform presets — Concise, Formal, Bulletize, anything you can phrase — and they appear as chips on the review overlay, restyle a dictation before it's pasted, and can even run automatically for chosen apps.

### Added

- **Transform presets — your own one-tap rewrites.** In the new **Presets** section of Settings, define any number of named transforms, each a short instruction in your own words ("Rewrite as a tight bulleted list", "Make this formal", "Translate to Spanish"). While reviewing a dictation, your presets appear as a quiet row of chips — tap one and the text is restyled in place before anything is pasted; tap another to chain transforms. Hover a chip to see its full instruction; as many chips as fit are shown inline and the rest tuck into a ⋯ menu. A preset runs as one extra request to the cleanup model you already use — no new service, nothing stored beyond the presets you wrote.
- **Per-app default presets.** Assign a preset to an app and dictations into that app arrive already styled — the preset folds into the normal cleanup pass, so there's no extra request and no flash of un-styled text. The overlay shows *Styled with \<name\>* and a one-tap **Undo** that re-runs plain cleanup if this particular dictation shouldn't have been transformed. IT admins can pin the whole feature off via managed configuration (`transformPresetsEnabled`).
- **The overlay tells you where it's listening.** During capture the header now reads *Listening on \<your microphone\>*, and the capture state is more compact — just the animated Parleq mark, no redundant label.

### Fixed

- **Phantom double-tap no longer triggers quick mode.** Some keyboards emit a near-instant phantom press-release ("chatter") when a modifier hotkey is released, which Parleq could read as a double-tap — auto-pasting your next dictation without review. Releases shorter than a human tap, and release-to-press gaps shorter than a human can produce, are now ignored when detecting double-taps.
- **A content-full overlay no longer balloons after a focus round-trip.** Switching screens or clicking away from a long, scrolling dictation and back could resize the overlay to the transcript's full unscrolled height — a giant panel with no scrolling. The overlay now snaps back to its proper capped size the moment anything oversizes it, regardless of what triggered the resize.
- **Editing a dictionary term no longer scatters junk entries into your config.** Renaming an existing term in Settings — for example a learned term, or any hand-added one — could quietly leave behind a separate dictionary entry for each intermediate spelling the field passed through while you typed (so editing "SNYK" → "Snyk" might add stray "Sny", "Sn", "S" entries). Edits now update the single entry in place.

## [0.18.0] - 2026-06-02

This release teaches Parleq to learn from the way you correct it, and makes the Copy button remember your dictations.

### Added

- **Learn from your corrections (opt-in, off by default).** When you fix the same things repeatedly — spelling a name out loud, or refining cleaned text by voice — Parleq can notice the pattern and, occasionally and entirely off the dictation path, ask your cleanup model to suggest improvements to your custom dictionary. High-confidence spelling fixes apply automatically and are always revertible; anything less certain is offered as a suggestion you can Accept or Dismiss in a new **Learned** section of the Parleq window. Turning it on keeps your recent corrections in memory only — never written to disk, cleared when you quit Parleq — and includes them in the occasional analysis request to the cleanup model you already use (no new service and no new network destination). It captures only your corrections, not a log of everything you dictate. The only thing that persists is the learned dictionary terms, stored in your config alongside any hand-added terms. You can cap how much is kept in the session, clear it any time, and disabling the feature offers to clear it immediately. A one-time nudge — in the Parleq window and on the review overlay — introduces the feature with a one-click toggle to turn it on. IT admins can pin it off via managed configuration.

### Changed

- **Copy now remembers your dictation.** Clicking **Copy** in the overlay records the dictation in Recent Dictations, so a result you copied and then dismissed is no longer lost. Copying, refining, and accepting the same dictation update a single history entry instead of creating duplicates.

## [0.17.1] - 2026-06-02

A small follow-up to 0.17.0 with two privacy/security fixes surfaced during a security-review pass.

### Fixed

- **"Skip cleanup" now reliably keeps your dictation on-device.** Choosing the **None** cleanup provider (skip cleanup, paste raw ASR) now disables the optional Context tier too — so even *reference-aware* dictations (where you've attached a window, file, or the clipboard) paste the raw on-device transcript and make **no** network call. Previously, a still-configured context model could keep sending reference-aware turns to the cloud even when cleanup was off, which was a surprising privacy gap. (You no longer need to separately clear the context model.)
- **AWS Bedrock SSO uses your SSO session, not stray environment credentials.** In the Bedrock SSO auth mode, your configured profile / SSO session now takes precedence over any ambient `AWS_ACCESS_KEY_ID` environment variables, which previously could silently override it. Environment credentials still authenticate as a last-resort fallback when no profile/SSO credential is present.

## [0.17.0] - 2026-06-01

This release makes the moment of dictation richer and far more discoverable. Quick keyboard gestures let you pull a window in as context or send your cleaned text to a different app without leaving the overlay; a built-in help card lists every gesture so you don't have to remember them; the start and end sounds are now yours to pick or silence individually; and cleanup got smarter about two very human things — correcting yourself mid-sentence and spelling a word out loud.

### Added

- **Self-correction and spelled-out-word cleanup.** Cleanup now follows two natural speech habits. When you audibly correct yourself mid-dictation — "scratch that", "no wait", "I mean Rob", "make that Thursday" — Parleq drops the retracted words and keeps your final intent, conservatively (when it's genuinely ambiguous whether you're correcting or listing both, it keeps your words). And when you spell a word out letter by letter — "K A R E N", "K-A-R-E-N", or phonetically — it assembles the letters into the single intended word and capitalizes it correctly: a proper noun gets an initial capital, a known acronym stays all-caps (URL, JWT), an ordinary word is lowercased — no more accidental ALL-CAPS just because you spelled it aloud. Spelling is most often used to fix a misheard name, so a spelled-out word right after a similar-sounding one replaces it.

- **Attach a window as context with a keystroke.** While holding the hotkey, press **C** to attach the window you're looking at as a reference, or **Space** to pick any on-screen window — its content becomes context for cleanup. Both gestures now also work *while you're reviewing* the result, so you can pull in context after seeing the draft and then refine with it. (Honors the Privacy & Features / MDM reference-windows switch, like every other window-capture path.)

- **Send your cleaned text to a different window.** During review, press **V** to choose a destination window and route the cleaned text straight there instead of the app you started in — handy for dictating into one place while reading from another.

- **A built-in help card.** Press **?** (or **/**) any time during dictation or review to bring up a card listing every gesture, with a short glossary of the concepts (dictate, review, refine, reference window) and your actual hotkey shown up top. It pauses the dictation while it's open and resumes the moment you dismiss it (Esc, ?, or press the hotkey to pick up where you left off).

- **Show the Parleq window during review.** The hold-hotkey + **P** "Show Parleq" gesture now also works while reviewing a result (press **P** in the overlay), not just during a hold.

- **Configurable start and end sounds.** The acoustic-feedback cues are now two independent choices — pick any macOS system sound for the start cue and the end cue separately, or set either to **Off**. Both are still gated by the master Acoustic feedback toggle. Configure them in **Settings → Audio**. Defaults: Tink (start) and Bottle (end).

### Changed

- **Hotkey hints adapt to your binding.** The dictation overlay's footer hints and the menu-bar status label now show your actual configured hotkey instead of a hardcoded "⌥", so they read correctly if you've rebound the dictation hotkey. The help card states your binding once at the top and refers to "the hotkey" throughout.

## [0.16.0] - 2026-05-29

A small but lovely bit of feedback for quick dictation. Quick mode — double-tap-and-hold to fire off a dictation without the preview overlay — used to give you nothing visual: just the start sound, and nothing at all if you run with acoustic feedback off. Now Parleq's brand mark appears as a near-transparent floating indicator near the bottom of the screen while you speak, so you always know you're being recorded.

### Added

- **Recording pulse for quick dictation.** During a quick (double-tap-hold) dictation — which shows no overlay — Parleq's five-bar brand mark floats near the bottom-center of the screen: the static Parleq logo at rest, a level-reactive waveform that dances with your voice as you speak. It's the visual analog of the start sound, so it's especially useful with acoustic feedback turned off. The indicator is informational only — near-transparent, never takes keyboard focus, and never intercepts clicks. It reuses the same listening indicator the full overlay shows, so quick-mode feedback matches normal capture. Toggle it off in **Settings → Behavior** (or via `ui.recording_pulse` in `~/.parleq/config.json`); on by default.

### Fixed

- **Settings controls on scrollable panes respond on the first click again.** A regression from 0.15.0: switching the Settings detail panes (and the Stats dashboard) to a both-axes scrolling view added a horizontal scroll gesture that competed with embedded controls for clicks — so on scrollable panes (Privacy & Features, Permissions, Behavior) toggles and buttons stopped responding and others needed a double-click, and tall panes mis-anchored so the intro paragraph clipped at the top with no way to scroll up to it. Reverted to a plain vertical scroll, which restores reliable single-click interaction and keeps the top of every pane reachable. This drops the 0.15.0 horizontal-scroll fallback; the auto-hiding sidebar and the window's minimum width keep the detail pane wide enough in practice.

## [0.15.0] - 2026-05-28

Window and navigation polish for the app shell that landed in 0.14.0. The Settings panes fold into the primary sidebar (one column instead of two), so the whole app is navigable from a single list — and that single sidebar auto-hides on a narrow window, handing the full width to whatever you're reading. The window no longer resizes itself to fit content (which used to push it off small or low-resolution displays), it clamps itself onto the visible screen, and every section now enforces the same minimum size so the resize floor stops shifting as you navigate. Plus a couple of smaller quality-of-life wins promoted out of the menu bar: a user-configurable dictation-overlay delay and Stats that persist across launches.

### Added

- **Unified collapsible sidebar.** The Settings sub-sections (Hotkey, Audio, Behavior, Paste, Cleanup, Dictionary, Usage, Permissions, Privacy & Features, Updates, Advanced) now live as expandable children directly under **Settings** in the app's one primary sidebar, replacing the old two-sidebar Settings layout (primary sidebar + a second Settings-only sidebar + detail). Clicking anywhere on the **Settings** row expands/collapses the group — you don't have to hit the small disclosure chevron. The result is a single navigable list for the entire app: Recent / Stats / Settings ▸ panes / About.

- **Auto-hiding sidebar with an explicit toggle.** On a narrow window the sidebar tucks away automatically and gives its width to the detail pane; widen the window and it returns. A sidebar toggle in the title bar brings it back (or dismisses it) at any size — a deliberate, deterministic control rather than a hover zone, so it stays usable for low-vision and motor-impaired users. The hide/show points use a hysteresis band so a resize that lingers near the threshold can't make the sidebar flicker.

- **User-configurable dictation-overlay delay.** A new Settings → Behavior control sets how long Parleq waits before showing the dictation overlay after you start a hold, so quick taps don't flash the overlay. The same value drives the audio cue and the hold-to-summon ("+ P") gesture threshold, keeping all three cues in sync.

- **Persistent Stats across sessions.** The text-free per-dictation metrics that feed the Stats dashboard now persist to disk (bounded to the last 30 days), so your dictation counts, speaking time, latencies, and token/cost trends span multiple launches instead of resetting every time you quit Parleq. The visible Recent Dictations history remains memory-only — only the anonymous metrics are persisted.

- **MDM key `livePricingEnabled`.** A new managed-configuration key (Boolean, default `true`) lets IT pin off the once-per-launch background fetch of the community LiteLLM pricing table from `raw.githubusercontent.com` (used only to keep Usage/Stats cost figures current). Set `false` for locked-down or air-gapped fleets; the bundled price table then serves and no such request is made. Mirrors the existing `PARLEQ_DISABLE_LIVE_PRICING=1` env var for single users.

- **Usage is a top-level section.** The token + cost ledger moved out of the Settings sub-sections into the primary sidebar — now Recent / Stats / Usage / Settings / About.

- **Check for updates from About.** The in-app About section has a **Check for updates** button (a manual Sparkle check, the same one Settings → Updates and the menu bar offer — it works even when automatic checks are turned off or MDM-managed).

### Changed

- **Window sizing is now pinned, not content-driven.** The app window no longer auto-grows to fit tall content (which could push it partly off a small or low-resolution display) and no longer derives its minimum size from whichever pane happens to be showing. It clamps its frame onto the active screen's visible area on open, enforces one consistent minimum size for every section, and keeps top-aligned content anchored at the top instead of floating to the vertical center. ([#61](https://github.com/parleq/parleq-speech/issues/61))

- **Horizontal-scroll fallback for narrow viewports.** Settings panes and the Stats dashboard now scroll horizontally as well as vertically when the window is narrower than their readable content width — so on a small screen or at a high display-scaling setting, content scrolls into view instead of being cramped or clipped. ([#62](https://github.com/parleq/parleq-speech/issues/62))

- **Removed the `⌘,` shortcut from "Show Parleq".** `⌘,` conventionally means "Open Settings" and was misleading now that the menu item opens the whole app shell rather than a settings dialog. The discoverable way to summon the window — hold your dictation hotkey and tap **P** — is now hinted in the menu-item tooltip and the dictation overlay ("Press P to open Parleq").

### Fixed

- **Reopening the app window preserves its state.** After closing the window (Cmd-W), re-summoning it now reuses the same window instead of rebuilding a fresh one — so sidebar expand/collapse, column visibility, and the restored frame survive a close/reopen.

- **Restored window stays on its own display.** A window validly saved on a connected secondary display is no longer pulled back onto the primary screen on reopen; it's clamped into whichever screen it most overlaps (and only falls back to the main screen if that display is gone).

- **Stats auto-refresh timer no longer restarts on every render.**

### Security

- **Logs never persist transcripts or secrets, even in trace/error paths.** `PARLEQ_BEDROCK_TRACE` (which raises Soto to trace level, logging request bodies + auth headers) is now honored only when stderr is a live terminal, never when it's been redirected to `~/.parleq/app.log` in a bundled app. The ASR pipeline's error path now drops a failed `asr.endpoint`'s HTTP response body from the log (keeping the status code), matching the existing LLM-error redaction.

## [0.14.0] - 2026-05-27

The Parleq app shell — Parleq is no longer "a hotkey with a Settings dialog." Press your hotkey + **P** (or click "Show Parleq…" in the menu bar) and a real macOS app window opens with four sections: **Recent Dictations** (full-text history with per-card Copy / Paste here / delete), **Stats** (dictation counts, speaking time + ASR/LLM latencies, token usage + cost, ref-attached + cleanup-failed rates, all on a 7-day rolling window), **Settings** (the same panes, reorganized into a sidebar), and **About** (the brand mark, version, links to source + licenses). Same LSUIElement footprint, same global hotkey, same paste pipeline — but now there's a home you can browse and configure from. Plus a full reference-capture overhaul so attaching windows from full-screen Spaces actually works, MDM-configurable transcript-history retention, and a stack of polish for the Reference Windows v2 latched-compose flow shipped in 0.13.0.

### Added

- **Parleq app shell.** A NavigationSplitView-based macOS window with sidebar (Recent / Stats / Settings / About) replacing the prior settings-dialog-as-the-only-window model. Opens via `Cmd-,` from the menu bar (renamed to "Show Parleq…") or by holding the dictation hotkey and tapping `P` from anywhere on the system. The "hold-hotkey + P" gesture has a 200ms hold threshold so casual `Option-P` keystrokes still type `π` — only deliberate hotkey holds engage the Parleq summon. `Cmd-W` closes the window. Window size and position persist across launches; closing the window and reopening lands you on **Recent** unless you came from the post-restart-from-Settings path (where it returns to Settings).

- **Recent Dictations.** Replaces the menu-bar's "Recent Dictations ▶" submenu with a scrollable card-based history browser. Each card shows the full cleaned text + timestamp + target app icon + reference count + a raw-fallback badge when cleanup failed. Per-card actions: **Copy** (with a "Copied ✓" flash), **Paste here** (routes the text into whatever app you were in when you opened Parleq, then dismisses the window so the target comes forward), and **×** to delete a single entry. Section header has a **Clear all** button for bulk wipe. Memory-only: history vanishes on Parleq quit (no disk persistence) — matches the existing privacy invariant.

- **Stats dashboard.** Four metric cards in a fixed 2×2 grid: **Dictations** (today's count + this-week + 7-day sparkline), **Speaking time** (today's seconds + this-week's total + ASR avg ms + LLM avg ms over last 7 days), **LLM usage** (today's token total + cost in USD, this-week's totals, top-3 all-time models breakdown), and **Quality & references** (ref-attached % and cleanup-failed % over last 7 days). Metrics are recorded text-free in a separate ring from the visible history so they survive even when retention caps prune the text — your Stats stay accurate even on a tight retention policy.

- **Per-dictation timing capture.** Each dictation now records audio duration + ASR latency + LLM latency to the Recent Dictations history record and the metrics ring. Drives the Stats card averages without bolting telemetry onto the hot path.

- **MDM-configurable transcript-history retention.** Two new managed-eligible keys: `transcriptHistoryMaxEntries` (Int — max cards in Recent at any time) and `transcriptHistoryRetentionHours` (Int — sweep entries older than this). Setting either to `0` is the "history disabled" sentinel — Parleq returns immediately from the history-append path and BOTH the text ring AND the text-free metrics ring stay empty. This is intentional: in regulated/compliance contexts, even aggregate per-dictation counts can be a privacy signal, so disabling history disables the counts that fed Stats too. User-configurable too (via Settings → Privacy & Features) when no MDM policy is in effect.

- **Reference Windows capture across full-screen Spaces.** The "Switch to that Space first" error message from 0.13.0 is largely gone. When you pick a window whose owning app is on a full-screen Space — whether dedicated or split-view — Parleq now reliably activates the source via the AppleScript bundle-id `activate` AppleEvent (the only programmatic mechanism that crosses macOS's full-screen-Space guardrail), waits for the WindowServer to compose the target Space, captures, and then animates back to your origin Space. Works for cross-monitor configurations (iTerm on secondary, target full-screen on primary), full-screen-to-full-screen transitions (iTerm full-screen, target full-screen elsewhere), and split full-screen targets like the iOS Simulator. The overlay panel temporarily strips its `.canJoinAllSpaces` collection-behavior during the focus restoration so macOS doesn't suppress the switchback animation, then reattaches on the new Space. After the Space settles, the overlay reclaims OS-level key-window status so `Enter` (accept) and `Escape` (cancel) keep working without an extra click.

- **Reference Windows v2 latched-compose during refines.** Press `Space` during a refine hold to attach another window — the latched-compose machinery now activates during the `.refining` phase, not only during the first-hold `.capturing` phase. The "Press Space to attach a window" teaching hint shows during refines, and the armed-variant ("Picker opens on release · Esc to cancel") swaps in correctly across every hold of a latched session. The flag's lifetime is now scoped strictly to a single hold; previously a stale armed state could leak into the next hold's overlay render.

- **Brand-coherent accent throughout the new app shell.** The sidebar selection, prominent buttons (Copy, Paste here, Send), the "raw" badge, sparklines, and upgrade banner now all read in Parleq's brand amber instead of macOS system blue. Driven by a single `.tint(brandAccent)` at the app-shell root; no Asset-catalog dependency required.

### Changed

- **Menu bar — final form.** Two-item-shorter status menu now that the app shell carries the heavy navigation. "About Parleq" routes to the in-app About section (richer than the system about panel: brand mark + version + links + copyright + licenses). "Open Source Licenses…" was removed entirely — the in-app About surfaces the same link more prominently. Order: status info → "Show Parleq…" / Microphone → Check for Updates / Run Setup → About / Quit. Cmd-, still opens Show Parleq, and the standard `About Parleq` item in the application main menu (visible only when the Parleq window is frontmost) was also repointed to the in-app About so both routes hit a single canonical surface.

- **Recent Dictations: bulk "Clear all" lives in the section header.** Previously buried at the bottom of the scroll content; now a small trailing button next to the "Recent" title so it's always reachable without scrolling through your entire session.

- **Restart-speech-model returns to Settings.** When you change the cleanup model in Settings → Cleanup and click the restart banner, the relaunched Parleq lands back on the Settings section (not the default Recent landing) so you can immediately verify the change. Other reopen paths still land on Recent.

### Fixed

- **`Cmd+,` from outside Parleq's window** no longer dead-keys. Previously the standard "Open Settings" shortcut routed only when the Parleq window was already key. The `Show Parleq…` menu item handles the routing now, and `Cmd-W` is also wired to close the app window from inside.

- **iOS-Simulator + other full-screen-Space references** no longer fail with the "Switch to that Space first" message in the common case. The retry path inside `ReferenceCapture.captureWithRetry` was using `NSRunningApplication.activate(options:)` for the source-app activation, which macOS refuses for cross-full-screen-Space targets; now routed through `Paster.activate` (AppleScript bundle-id activate). 700ms post-activation wait covers Space-switch animation + Metal-compositor readiness for the Simulator's special compositing.

- **`asrEndpoint` no longer leaks path / query / fragment to `~/.parleq/app.log`.** The startup-summary URL sanitizer was wired for `sparkleUpdateFeedURL` only; it now also strips path + query from a managed `asrEndpoint`, preserving scheme + host + optional port so operators can still verify the managed value at a glance without exposing tokenized paths.

### Security

- **MDM `loggingMode` accessor.** A typed `ManagedConfig.LoggingMode` enum + `loggingMode()` accessor land now even though no verbose-logging mode exists yet — future logging code paths are structurally drawn to consult the accessor, and bypassing it becomes grep-discoverable. Trap for a future PR that adds verbose logging to honor the MDM-pinned `lengthOnly` policy.

- **Appcast XML release-notes residual risk — documented.** EdDSA-signature gating means a hostile mirror at a managed `sparkleUpdateFeedURL` cannot ship an arbitrary binary. It CAN display arbitrary release-notes content as HTML inside Sparkle's update dialog. Risk is social-engineering only (Parleq does not auto-act on release-notes content); operator mitigation: vet the managed feed URL host. Documented in the managed-configuration security invariant section.

- **`customDictionary` entry content — documented limitation.** MDM can suppress the entire custom-dictionary feature via `customDictionaryEnabled=false`, but cannot constrain individual entry text (which is injected verbatim into the cleanup LLM prompt). In compliance-sensitive deployments where prompt content must be controlled, disable the whole feature. Documented in the admin guide.

## [0.13.0] - 2026-05-26

Reference Windows v2 — the headline change since 0.12.0. Attaching a window mid-dictation went from "stop, click 'Pick a window…', start over" to a fluid one-handed gesture: hold the hotkey, tap **Space**, the picker opens with audio paused, pick a window, hold the hotkey again to keep dictating or tap-release to send. The picker itself is substantially larger now, remembers your size + position across launches, and is fully keyboard-navigable (arrow keys + Enter). Also includes ASR + focus polish from the foundation pass that landed alongside the gesture work.

### Added

- **Reference Windows v2 — latched-compose gesture.** A new way to attach references mid-dictation without abandoning the composition. Hold your dictation hotkey, speak, and tap **Space** while still holding — audio pauses, the window picker opens, you pick a reference, and the overlay enters a "latched" state. Hold the hotkey again to keep dictating (the composition continues across the attachment), or tap-and-release to send. Repeat with Space mid-dictation to attach a second, third, … reference into the same composition. **Esc cancels** the whole composition; **tap-and-release without further speech** sends immediately. The overlay's hint strip teaches the gesture on first encounter ("Press Space to attach a window"), confirms when Space lands ("Picker opens on release · Esc to cancel"), and switches to "Tap ⌥-Right to send · Hold for more · Esc cancel" once you're latched with a reference attached. The whole feature is gated by the existing **Settings → Privacy & Features → Reference Windows** toggle — disabled users keep the v1 click-the-button flow with no gesture changes.

- **Larger, screen-relative window picker.** The picker now defaults to ~70% of your active screen's usable area (clamped to a reasonable 1400×950 ceiling), centered on the screen you're working on rather than always the primary display. Picker size and position are persisted across launches via NSPanel frame autosave, so power users who size it once don't have to re-fiddle every session. Thumbnail card bounds bumped (280→420pt vs the prior 240→360pt) so wider pickers give each card real visual weight instead of just adding columns. Falls back to a centered default on first launch or when the saved frame ends up on a disconnected external display.

- **Keyboard navigation in the picker.** Arrow keys move selection through the grid — Left/Right by one card, Up/Down by the current column count (computed deterministically from grid width using the same formula SwiftUI's `.adaptive` GridItem uses internally, so it stays correct as you resize). The selected card shows a stronger accent ring than the hover state. **Enter** picks the selected window; **Enter with no selection** picks the first entry as a one-handed "give me the first thing offered" shortcut. **Cmd-W** also closes the picker now (previously dead since Parleq is LSUIElement and has no File menu to route the shortcut through). Selection clears on every refresh / show / permission transition so a stale highlight never points at a removed card.

### Changed

- **ASR silence detection.** Recordings with no detectable voice activity (whispered, microphone muted, room-tone-only) no longer get sent to ASR — closes a class of hallucinated short transcripts ("yeah", "okay", "thank you") that the upstream STT would emit on near-silent input. Threshold tuned to 0.002 RMS-over-20ms-frames after testing against both quiet-but-real speech and various microphone idle profiles. ([#210](https://github.com/parleq/parleq-speech/issues/210))

- **Reference Windows focus restore.** Capturing a window no longer leaves keyboard focus on the source app — Parleq snapshots the frontmost app at capture time and restores it after SCK finishes, so your "Pasting to" target stays consistent across attachments. Full-screen Space windows still can't be captured without you switching Spaces manually (a documented limitation tracked in [#212](https://github.com/parleq/parleq-speech/issues/212)) — those now surface a clear error message ("Simulator is in a full-screen Space. Switch to that Space first, then try attaching it again.") instead of the raw SCK -3811 blob. ([#211](https://github.com/parleq/parleq-speech/issues/211))

- **Overlay polish.** The "PASTING TO &lt;app&gt;" chip is now visible during active dictation states (capturing, cleaning, refining), not only on the awaitingAccept overlay. Surfaced during latched-compose testing when clicking picker buttons inadvertently shifted focus and the previously-text-gated chip didn't update fast enough to warn the user before the eventual paste. Same visual treatment in both placements (extracted to a shared `PastingToLabel` view) so the chip doesn't jump or restyle when the overlay transitions to awaitingAccept.

- **Menu-bar declutter (in progress).** Two items moved out of the menu bar into Settings as a step toward a tighter top-level menu: **View Managed Configuration…** is now a "View managed configuration…" button at the bottom of **Settings → Privacy & Features** (#213), and **Reset ASR** is now a "Reset speech model" button in **Settings → Advanced** (#214). The Compliance Audit dialog and the underlying reset call are unchanged — same window controller and same `LocalASRClient.reset()` action — just relocated. Subsequent releases will continue shrinking the menu bar; long-term direction is a proper "Parleq app" with Settings as one of several sections.

### Fixed

- **Esc during LLM cleanup no longer leaves the overlay stuck.** The streaming cleanup path's empty-result and catch branches would re-show the overlay after `cancel()`'s `closeAndReset` hid it, racing the user-cancel signal and leaving the overlay in a fake "processing" state that only a fresh hotkey press could dismiss. Both paths now skip the re-show when `Task.isCancelled` is set or the caught error is a `CancellationError`. Pre-existing intermittent bug, surfaced during PR B testing.

- **Error banners no longer persist across dictation sessions.** A failed reference capture (full-screen Space, etc.) used to leave its banner visible on every subsequent overlay show until the user manually clicked the X. `resetPerDictationOverlayState()` now clears `errorMessage` + `permissionPrompt` on every exit to `.idle`, so a successful next dictation implicitly dismisses any stale banner.

### Security

- **Sparkle managed-feed-URL state hygiene.** `setFeedURL` persists the URL to user defaults, so a previously-set managed value would linger across launches even after the MDM profile was removed (defeating policy removal — an admin who briefly pushed a corp-mirror URL would have it stick on every fleet machine forever). Parleq now calls `clearFeedURLFromUserDefaults` on every launch where there isn't a successfully-validated managed `sparkleUpdateFeedURL`, so removing the MDM profile (or rejecting an invalid managed value) reliably restores Sparkle's Info.plist `SUFeedURL` default.

## [0.12.0] - 2026-05-22

Two major features and a security hardening pass — the biggest release since v0.7. **Reference Windows** ([#46](https://github.com/parleq/parleq-speech/pull/46)) lets you attach screenshots, files, and clipboard content to a dictation so the LLM sees what you're talking about, not just hears what you said. **Managed Configuration** ([#47](https://github.com/parleq/parleq-speech/pull/47)) makes Parleq deployable as a governed fleet app via macOS MDM — twenty-nine managed keys for pinning provider, model, auth mode, destination endpoints, and feature toggles. **MDM Hardening** ([#48](https://github.com/parleq/parleq-speech/pull/48)) closes the bypasses surfaced during a post-shipping security hackathon: destination pins (no exfiltration via personal cloud accounts), Sparkle skip-version clearing, and a Reference Windows symlink-target re-check.

### Added

- **Reference Windows.** Press Shift while holding the dictation hotkey to bring up a window picker; pick one or more open windows, then dictate normally. The LLM sees the window's on-screen content (text mode) or a vision capture (image mode) alongside your dictation, so prompts like "summarize what's on this page" or "rewrite this email more concisely" just work. Three additional attach paths: clipboard (text or image), drag-drop a file (text / source / PDF / image), or the "+ Add file…" picker in the overlay. Image-mode references require a vision-capable model — the in-overlay picker auto-flags conflicts and offers a one-click "downgrade to text" fallback. Per-reference mode toggle (T / 👁) on each chip so you can mix text and image refs in one prompt. All reference paths can be individually disabled in **Settings → Privacy & Features**.

- **Managed Configuration (MDM).** Deploy Parleq via your MDM (Jamf Pro, Kandji, Mosyle, Intune, Workspace ONE, Addigy, JumpCloud, etc.) and govern it like any other managed app. Twenty-nine managed-eligible keys covering: provider + model pin/allowlist (8 keys), auth-mode restrictions (4 keys including the new `vertexAuthMode`), destination endpoint pins (8 keys — GCP project/region, AWS region/profile, Azure resource/deployment, ASR endpoint), feature toggles (6 keys), and operational policy (3 keys including the Sparkle appcast URL override). All MDM reads use Apple's standard `CFPreferencesAppValueIsForced` API against `/Library/Managed Preferences/com.parleq.app.plist`. A new **Compliance Audit dialog** (Menu Bar → "View Managed Configuration…") shows every managed-eligible key with its effective value and source (Managed / User / Default); a "Copy snapshot" button puts a JSON dump on the clipboard so IT can verify policy state without screen-sharing. Sample `.mobileconfig` ships at [`config/parleq-managed-example.mobileconfig`](https://github.com/parleq/parleq-speech/blob/main/config/parleq-managed-example.mobileconfig). Full schema reference: [parleq.app/docs/managed-configuration](https://parleq.app/docs/managed-configuration/). Deployment guide for IT admins: [parleq.app/docs/admin-guide](https://parleq.app/docs/admin-guide/).

- **`Settings → Privacy & Features` pane.** Six user-facing toggles independent of any MDM deployment: Reference Windows master switch, Clipboard reference, Image reference, File reference, Custom dictionary, Custom model entry. Each toggle's effective policy state is also exposed in the Compliance Audit dialog. Defense-in-depth: when `customModelEntryEnabled` is off, a non-canonical model name (whether MDM-pushed, manually edited into `~/.parleq/config.json`, or left over from before the toggle flipped) is reset at runtime to the provider's curated default — the toggle is not just a UI gate.

### Security

- **MDM destination-pin enforcement.** Eight new managed keys close the "use the allowed provider but route the data at my personal tenant" exfiltration class: `vertexProject`, `vertexRegion`, `vertexAnthropicRegion`, `awsRegion`, `awsProfile`, `azureResource`, `azureDeployment`, and `asrEndpoint`. The ASR endpoint pin is particularly load-bearing — without it, an MDM-locked Parleq with provider+model+auth-mode pinned could still POST every dictation's raw audio at `asr.endpoint=http://attacker.example/inference` *before* LLM cleanup ran. `ManagedConfig.validateASREndpoint` requires `https://` with a non-empty host, no embedded userinfo, no query parameters, no fragment — plain `http://` is rejected when pushed via MDM (the unmanaged local-dev affordance for `127.0.0.1` Sherpa / faster-whisper setups doesn't extend to MDM pushes).

- **Auth-mode runtime enforcement.** When `staticApiKeysAllowed=false` is managed, every static-key auth path is blocked at runtime via a `BlockedProvider` sentinel that throws `.authPathBlocked` before any network call. Mixed-auth providers (Azure, Bedrock IAM, Vertex) retain their federated alternative; providers with no federated fallback (Gemini direct, OpenAI direct, Bedrock bearer) become entirely unavailable and the provider picker annotates them with "(disabled by your organization)". Already-stored Keychain credentials are NOT deleted — removing the MDM profile restores prior functionality on the next launch. When the stored Vertex auth mode is `serviceAccount` and the master switch blocks the SA path, Parleq auto-coerces `vertexAuthMode` to `adc` in memory so the runtime matches the UI's "use gcloud ADC" message; the on-disk value is preserved by `save()` so removing the MDM profile restores the user's stored choice.

- **Sparkle `SUSkippedVersion` clearing.** When `autoUpdateEnabled=true` is pushed by MDM, Parleq clears all three Sparkle 2.x skip-version user defaults (`SUSkippedVersion`, `SUSkippedMajorVersion`, `SUSkippedMajorSubreleaseVersion`) on launch — same set Sparkle's own `[SPUSkippedUpdate clearSkippedUpdateForHost:]` clears together. Closes the "user writes `SUSkippedMajorVersion=99` to their own defaults and silently defeats forced auto-update across any major release" bypass.

- **Reference Windows symlink-target re-check** hoisted above the image/PDF dispatch in `ReferenceCapture.reference(forFileAt:)` and tightened to require the symlink's claimed family and the resolved target's family to MATCH and both be a recognized family (image / pdf / text). Closes the `screenshot.png → ~/.ssh/id_rsa` attack where a symlink with a benign image extension routed sensitive bytes into the image branch — `URL.contentTypeKey` reads the symlink's filename, not the target's, so `Data(contentsOf: url)` would silently follow the symlink and ship target bytes to the LLM as a binary image attachment. Also catches the cross-family variant (`screenshot.png → secret.pdf`).

- **SetupWizard credential gates.** First-run wizard hides Gemini / Vertex-SA / Azure-apiKey credential entry fields when `staticApiKeysAllowed=false` is managed, routing the user to the federated alternative ("Choose a federated-auth provider in the previous step", "Switch this picker to gcloud (ADC)", "Switch this picker to Microsoft Entra ID") instead of soliciting keys that won't be usable at runtime.

### Changed

- **Settings credential cards now use explicit field labels.** Each TextField in the Azure / Bedrock / Vertex credential cards has a small caption-style label above it ("Resource", "Deployment", "Region", "Project", "Anthropic region", "AWS profile (optional)", etc.) so populated / disabled / MDM-managed values stay interpretable instead of becoming anonymous strings. A new `labeledField` helper in `SettingsWindow.swift` handles the layout uniformly across cards. Surfaced during MDM-hardening testing when a `corp-openai`-filled disabled field gave no indication of what the field was.

- **`THIRD_PARTY_LICENSES.md` updated for v0.12.0 dependency footprint.** No new heavyweight dependencies; the file's audit-trail footer is dated to 0.12.0 for clarity.

## [0.11.1] - 2026-05-16

Open-source attribution polish. v0.11.0 shipped on top of a `THIRD_PARTY_LICENSES.md` that was last regenerated at v0.9.0 and had drifted — most notably, Sparkle (added in v0.10.0 for auto-updates) was missing from both `THIRD_PARTY_LICENSES.md` and `NOTICE`. This release closes the gap. No code changes to dictation, ASR, cleanup, or any user-visible workflow.

### Added

- **"Open Source Licenses…" item in the menu-bar dropdown.** Placed right after "About Parleq". Opens the canonical [`THIRD_PARTY_LICENSES.md`](https://github.com/parleq/parleq-speech/blob/main/THIRD_PARTY_LICENSES.md) on GitHub in your default browser — Markdown renders natively, and every upstream source repo is one click away. An offline copy is also bundled inside `Parleq.app/Contents/Resources/` (see below).

- **LICENSE, NOTICE, and THIRD_PARTY_LICENSES.md now ship inside the .app bundle.** `make-app.sh` copies the three files into `Parleq.app/Contents/Resources/` at build time. Discharges Apache-2.0 §4 (which wants notices to travel with binary redistributions) and the MIT/BSD attribution clauses for Sparkle and its vendored components, without relying on downstream redistributors to also ship a separate notice file alongside the .dmg. Anyone with the .app can right-click → Show Package Contents and find the credits directly.

### Changed

- **`THIRD_PARTY_LICENSES.md` and `NOTICE` refreshed for v0.11.x.** Sparkle 2.9.1 (MIT) is now credited as a direct dependency, along with its two vendored components — ed25519-sparkle (Orson Peters 2015, zlib-style) and bsdiff (Colin Percival 2003-2005, 2-clause BSD) — that ship inside `Sparkle.framework`. The obsolete Hummingbird section was removed (it was retired in v0.9.0 when the FluidAudio sidecar was folded into the main target). FluidAudio version refreshed 0.14.3 → 0.14.5 (still within the pinned range). At-a-glance counts updated; audit-trail footer dated to v0.11.0. The external-services list was extended to include Vertex AI, Azure OpenAI, and the Sparkle appcast as runtime egress destinations alongside the previously-listed Gemini, Bedrock, Hugging Face, and GitHub.

- **The About page on parleq.app now includes a body link** to `THIRD_PARTY_LICENSES.md` in addition to the existing footer link, naming the heavyweight deps by category for quick orientation.

## [0.11.0] - 2026-05-15

Cleanup-failure recovery across all three cloud providers — when a cloud sign-in expires mid-session (`aws sso login` token, `gcloud` ADC, Azure Entra ID), Parleq now picks up the refreshed credentials on the next dictation without a restart. Same dictation also keeps working: cleanup falls back to raw ASR transcript when it can't reach the cloud, and three new surfaces (overlay hint, menu-bar badge, Recent Dictations annotation) tell you exactly what happened and how to fix it.

### Added

- **Auto-refresh credentials on auth failure for AWS Bedrock SSO, Vertex AI ADC, and Azure Entra ID.** Previously, if the user launched Parleq while their cloud sign-in was expired or missing, Parleq would paste raw ASR for every dictation until the user manually quit and relaunched the app — even after running `aws sso login` / `gcloud auth application-default login` / `az login` in another terminal. The in-memory token cache held a stale token and never re-minted. Each provider's `generateStreaming` is now a retry-once wrapper: on `.missingCredentials` or HTTP 401, the token cache is invalidated and the call replays once, picking up the freshly-refreshed credentials from the CLI's own cache (`~/.aws/sso/cache/`, `~/.config/gcloud/application_default_credentials.json`, the `az` token cache). 403s deliberately excluded from retry — those are IAM-level denials that re-minting won't fix, so we don't waste a second round-trip. Azure API-key mode also skips the retry path since re-reading the Keychain on each call already picks up Settings edits. Closes [#26](https://github.com/parleq/parleq-speech/issues/26) (Bedrock — landed in #29), [#30](https://github.com/parleq/parleq-speech/issues/30) (Vertex + Azure parity).

- **Cleanup-failure hint in the accept overlay.** When the LLM cleanup call fails and Parleq falls back to the raw ASR transcript, the awaiting-accept overlay now decorates the footer with a provider-specific recovery hint — for Bedrock that's "Run `aws sso login --profile <name>`, then dictate again"; for Vertex ADC, "Run `gcloud auth application-default login`"; for Azure Entra ID, "Run `az login`". You see the exact one-liner you need to type, not a generic error. Closes [#27](https://github.com/parleq/parleq-speech/issues/27) (landed in #29 + completed in #31).

- **Menu-bar badge for cleanup failures (the quick-mode-friendly surface).** Quick mode has no overlay to surface the failure inline, so a new amber-bars status icon + dismissable "⚠ Cleanup failed — <hint>" menu row carry the same provider-specific recovery message. Fires for every dictation in either mode (so a successful subsequent cleanup auto-clears the badge even if the user never dismissed it manually). The amber icon is non-template so the warning color sticks regardless of light/dark menu-bar appearance. Click the row to dismiss; click any dictation to recover. Closes [#28](https://github.com/parleq/parleq-speech/issues/28).

- **Recent Dictations marks raw-fallback entries.** `TranscriptEntry` gained a `wasCleanupSuccessful` flag; the Recent Dictations submenu appends ` · raw` to the title of any entry whose cleanup failed, and the tooltip spells it out ("raw transcript — LLM cleanup failed for this dictation"). Useful when scanning history after a stretch of auth failures to spot which dictations are worth re-running with cleanup working. Closes [#27](https://github.com/parleq/parleq-speech/issues/27).

## [0.10.1] - 2026-05-15

Small polish release. Also the first real test of v0.10.0's Sparkle auto-update path — installed 0.10.0 builds should detect this release in the appcast, verify the Ed25519 signature, and prompt to install.

### Added

- **Active microphone visible in three more places.** The Microphone submenu's "System Default" entry now renders as `System Default · <resolved name>` so the fallback isn't anonymous. During dictation, the overlay's `listening…` line becomes `listening on <Mic Name>…` (and `listening for refinement on <Mic Name>…` in the refinement branch) so you can confirm at a glance which device is being captured from. Hovering the menu-bar status icon when idle now surfaces `Microphone: <full name>` as a tooltip. All three surfaces read from a single resolver in `AudioRecorder.swift`, so the displayed name is always consistent. Tail-truncated in the overlay's fixed-width layout for the rare 40+ char USB-hub device names; the tooltip carries the full name. Closes [#24](https://github.com/parleq/parleq-speech/issues/24).

## [0.10.0] - 2026-05-15

First release with built-in auto-updates. Going forward, you'll be prompted to install new versions instead of needing to check GitHub Releases manually. Note this release is also the first one whose .dmg is signed with the Sparkle Ed25519 key, so installs of 0.10.0 are what will detect (and verify the integrity of) every future release.

### Added

- **Auto-updates via Sparkle.** Parleq now checks `parleq.app/appcast.xml` on launch + every 24 hours and prompts you when a newer release is available — the standard "an update is available" dialog familiar from most Mac apps. Each release is signed with an Ed25519 key whose public half ships inside every build; Sparkle refuses any update whose enclosure signature doesn't verify, so a downstream attacker who tampered with the appcast or the .dmg can't push an arbitrary binary to existing installs. Two user-facing controls: a new **Settings → Updates** pane with an "Automatically check for updates" toggle + a "Check for Updates Now" button, and a **"Check for Updates…"** item in the menu-bar dropdown. See `docs/SECURITY_REVIEW.md` §7a for the full posture (private-key custody, what gets sent on update checks, failure modes).

## [0.9.1] - 2026-05-14

Polish release on top of v0.9.0's in-process consolidation. Two visible improvements; no behavior change to dictation.

### Added

- **Real progress bar in the initialization overlay.** When the user presses the dictation hotkey before the speech model has finished loading, the overlay now shows a linear progress bar with a phase label ("Listing model files…", "Downloading speech model (N of M)…", "Compiling joint-decoder.mlmodelc…") instead of a generic indeterminate spinner. Most users only ever see this on first launch, when the ~150 MB Parakeet TDT v3 download is in flight; on a slow connection the old spinner read as "the app is frozen." The progress bar isn't auto-popped — if the user doesn't try to dictate during init, they don't see this UI at all. Closes [#15](https://github.com/parleq/parleq-speech/issues/15).

### Changed

- **DMG mounts with the Parleq icon.** Passing `--volicon` to `create-dmg` so the mounted volume on the desktop / in the Finder sidebar renders with the five-bar Parleq mark instead of the generic disk-image glyph. Reuses the same `AppIcon.icns` the bundle already ships — no second asset to maintain.

## [0.9.0] - 2026-05-14

Architectural simplification: FluidAudio now runs in-process, retiring the bundled HTTP sidecar that earlier builds spawned alongside the main app. No user-visible behavior change to dictation; visible UI change is the menu item formerly called "Restart Sidecar" is now "Reset ASR" and gains a clearer load-failure tooltip with a retry hint.

### Changed

- **FluidAudio runs in-process; the bundled HTTP sidecar is gone.** Earlier builds (≤ v0.8.x) hosted the speech recognizer in a separate `fluidaudio-sidecar` Swift package, supervised as a child process and reached over `127.0.0.1:8767` with bearer-token auth. v0.9.0 folds that pipeline into the main app target via a new `LocalASR` module. Wins: no listening sockets on the default ASR path (stronger compliance posture — "no local server" beats "local server with bearer auth"), single signed binary in the bundle, Hummingbird is dropped as a dependency, the app and the speech engine share fate (an ASR crash takes the app down loudly instead of leaving the menu bar alive but black-holed). The menu's **Restart Sidecar** item is now **Reset ASR** — same recovery affordance, but it unloads + reloads the FluidAudio model in-process instead of cycling a child process.
- **`asr.endpoint`'s default value is now a sentinel, not a URL.** The string `http://127.0.0.1:8767/inference` is kept verbatim for back-compat with config files written by 0.7.x / 0.8.x builds — but in 0.9.0+ matching it triggers the in-process `LocalASR` path. Any other value continues to route through `ASRClient`'s HTTP code so existing Sherpa-ONNX / faster-whisper / custom-server users keep working without a config change.
- **Model load failures are now recoverable from the menu.** If the first-run download fails (network blip, disk full, sandbox denial), `LocalASR` auto-retries once after ~10 s; if that also fails, the menu bar surfaces "Speech model failed to load" with a tooltip pointing the user at "Reset ASR" to retry. The retired sidecar's exponential-backoff restarts didn't surface this clearly.

### Removed

- `SidecarSupervisor.swift`, `SidecarHealth.swift`, and the entire `third_party/fluidaudio-sidecar/` Swift package.
- The `PARLEQ_SIDECAR_TOKEN`, `PARLEQ_SUPERVISOR_PID`, `PARLEQ_VOCAB_PRELOAD`, and `FLUIDAUDIO_PORT` environment variables. `PARLEQ_VOCAB_TRACE=1` still works against `LocalASR`'s in-process vocab log lines.
- The `/tmp/parleq-sidecar.log` file. Diagnostics now go to the main app log at `~/.parleq/app.log` like everything else.
- Hummingbird dependency. FluidAudio is now a direct dependency of the main app target.
- The second codesigning pass in `scripts/make-app.sh` — the bundle is now a single signed binary.

## [0.8.1] - 2026-05-11

Two follow-on fixes to v0.8.0's Permissions work, plus a more atomic release flow internally.

### Fixed

- **Open at Login now actually registers.** The v0.8.0 bundle was missing the LaunchAgent plist that macOS's `SMAppService.mainApp` API looks for at `Contents/Library/LaunchAgents/<bundle-id>.plist`; without it, `SMAppService.mainApp.status` reported `.notFound` forever and `register()` had no service description to register. The plist now ships inside the bundle, so the toggle transitions through "Off → On" cleanly with macOS's standard "Parleq added items that can run in the background" approval prompt the first time.
- **`CADeviceDefaultAggregate` no longer leaks into the Microphone submenu** on macOS Sequoia. The discriminator is a UID-prefix filter for Apple's Core Audio system-aggregate naming conventions (`CADefaultDevice`, `CADeviceDefault`, `AppleAggregateDevice`), applied only to transport-Aggregate devices so user-created aggregates from Audio MIDI Setup are unaffected. Closes [#9](https://github.com/parleq/parleq-speech/issues/9).

### Internal

- New input-device diagnostic in `~/.parleq/app.log` at launch. One line per input device, recording transport type fourcc, IsHidden flag, IsPrivate flag, UID, name, and which filter (if any) excluded it from the Microphone submenu. Cheap (a handful of HAL queries), runs once per launch, gives us forensic data the next time a system-internal device leaks through without needing a debug build.
- `make release` is now atomic: validates `RELEASE_NOTES.txt`'s first line references the current version, builds the DMG, creates the GitHub release with assets attached, and dispatches the website redeploy in a single command. Requires the local branch to be pushed first. Companion `RELEASE_NOTES.txt` now lives at the repo root and is updated as part of the version-bump PR.

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

[Unreleased]: https://github.com/parleq/parleq-speech/compare/v0.14.0...HEAD
[0.14.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.14.0
[0.13.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.13.0
[0.12.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.12.0
[0.11.1]: https://github.com/parleq/parleq-speech/releases/tag/v0.11.1
[0.11.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.11.0
[0.10.1]: https://github.com/parleq/parleq-speech/releases/tag/v0.10.1
[0.10.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.10.0
[0.9.1]: https://github.com/parleq/parleq-speech/releases/tag/v0.9.1
[0.9.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.9.0
[0.8.1]: https://github.com/parleq/parleq-speech/releases/tag/v0.8.1
[0.8.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.8.0
[0.7.0]: https://github.com/parleq/parleq-speech/releases/tag/v0.7.0
