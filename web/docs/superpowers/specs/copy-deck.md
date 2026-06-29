# Parleq Homepage Copy Deck (authoritative)

This is the single source of truth for every user-facing string on the redesigned homepage.
Later tasks copy from here. Never pull strings from the codex pack — it contains forbidden overclaims.

---

## FORBIDDEN strings (must never appear in built HTML — Task 2 asserts absence)

- "Nothing leaves your Mac"           (blanket; cleanup can be cloud)
- "Nothing leaves your device"
- "100% on-device"                    (blanket)
- "On-device Concord"                 (wordmark)
- "Everything runs on your Mac"
- voiceprints "learn"/"rhythm"/"filler"/"hesitations"/"sounds like you"

---

## REQUIRED strings (Task 2 asserts presence)

- "Your voice never leaves your Mac"      (audio privacy line)
- "built on Concord"                       (attribution credit)

---

## Beat 1 — Hero

- **Eyebrow / privacy pill:** "Your voice never leaves your Mac"
- **H1:** "Speak freely." / "Paste clean."
- **Subhead:** "Parleq /PAR-lek/ is a local-first AI dictation app for macOS. Hold a hotkey and talk; the cleaned-up result pastes into whatever app was focused — speech recognition and cleanup can both run on your Mac, or use the cloud you bring."
- **Primary CTA:** "Download for macOS"
- **Secondary CTA:** "See it in action"
- **Transform cards:**
  - Input (raw dictation): "we cut latency by forty five percent last quarter"
  - Engine label: "On-device cleanup"
  - Output (cleaned text): "We cut latency by 45% last quarter."

---

## Beat 2 — Refinement loop

- **Heading:** "Not quite right? Just say so."
- **Body:** "Most dictation apps stop at paste. Parleq lets you refine by voice — 'make it more concise,' 'more formal,' a numbered preset — without touching the keyboard."
- *(Uses the existing OverlayMockup with its real before / refine-instruction / after text.)*

---

## Beat 3 — On-device + cloud, configurable split

- **Heading:** "Instant on your Mac. Powerful in your cloud. Your call."
- **Body:** "Keep first-pass cleanup on the on-device tier, and send refinement to the cloud provider you bring — Gemini, Bedrock, Vertex, or Azure. You decide the split."
- **Engine credit:** "built on Concord (by Keavi)"
- **Cluster node labels:** Voiceprints · Punctuation · Numbers · Dictionary · Compound

---

## Beat 4 — Per-app engine defaults

*(Present tense — release-gated; the site release is gated on this app feature shipping. No "preview" label.)*

- **Heading:** "The right cleanup for every app."
- **Body:** "Set which cleanup each app uses — cloud-grade for Slack and email, instant on-device for a terminal chat. Parleq remembers, per app."
- **Table rows:**
  - Slack → Cloud · polished
  - Mail → Cloud · polished
  - Terminal → On-device · instant
  - Notes → On-device · instant

---

## Beat 5 — Accuracy band + capability index

- **Heading:** "Names, numbers, the works."
- **Cards** (each led by a real before → after):

  ### Voiceprints
  - Before/after examples: "parlay → Parleq" ; "kiwi → Keavi"
  - Copy: "Tell sound-alike names apart by voice. On-device, opt-in per term; what's kept is an encrypted voiceprint, never a recording."

  ### Custom dictionary
  - Before/after example: "Q2RFC → Q2 RFC"
  - Copy: "Teach Parleq your names, acronyms, and jargon so it gets them right."

  ### Numbers & punctuation
  - Before/after examples: "eight point nine million → 8.9 million" ; "forty five percent → 45%"
  - Copy: "Spoken numbers become digits; punctuation and casing land where they belong."

  ### Private by design
  - Copy: "Your voice never leaves your Mac. Cleanup runs on-device, or on the cloud account you bring — your choice, per provider."

---

## Beat 6 — Enterprise/trust strip

- **Heading:** "Built for teams who need control."
- **Columns:**
  - SSO & directory
  - Bring your cloud
  - No API keys on devices
  - Auditable by design

---

## Beat 7 — Get Parleq

- **Preserve the existing tester-readable install walkthrough verbatim:**
  1. Download
  2. Drag to Applications
  3. Permissions in context (microphone, accessibility — prompted at first use)
  4. Pick a provider (on-device, Gemini, Bedrock, Vertex, Azure)
  5. Set your hotkey and go
- **Reserved (empty) social-proof slot** for post-Posit rollout announcement.

---

*End of copy deck. All implementations must draw user-facing strings from this file, not from the codex pack.*
