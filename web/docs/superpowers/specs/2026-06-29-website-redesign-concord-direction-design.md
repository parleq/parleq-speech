# Parleq Website Redesign — "Concord Direction" Design

**Date:** 2026-06-29
**Status:** Design — revised after adversarial + balanced review; awaiting maintainer sign-off before implementation planning
**Scope:** Homepage first (`web/src/pages/index.astro`), as the proving ground for a visual language we later propagate to the rest of the site.

> **Revision note (post-review).** This spec was reviewed by two independent subagents (one adversarial, one balanced) and reconciled. The §13 reconciliation log records what changed and why, including one place where a CRITICAL adversarial finding was corrected against shipped code.

> ⚠️ **RELEASE GATE.** The redesigned site markets **per-app cleanup-engine selection** (beat 4) in present tense. That capability is in active development in a parallel effort. **The site must NOT go live until that feature ships — first or simultaneously.** Coordinate the site PR deploy with that app release so the page is correct at launch. See §9.

---

## 1. Goal

A sweeping redesign of the Parleq homepage that is **revolutionary and compelling**, not a generic AI-SaaS page. It should feel like a premium, Mac-native tool with a powerful, private intelligence engine inside it — and it should tell Parleq's *actual* differentiated story, not just the "private/on-device" slice.

The redesign builds on a visual language developed in a ChatGPT session (the "Concord Direction" pack: framed dark grape hero panel, card-and-flow-line transformation, editorial serif, compact dark trust strip). **That session was about getting the visual components right. Its copy is placeholder-grade and in several places inaccurate (see §3), and is explicitly NOT a build input — see the scrubbed copy-deck rule in §3.**

We are not in a hurry. We aim for the north-star concept over time, while shipping a great static baseline at every step and fencing a concrete v1 (see §9).

## 2. Positioning — what Parleq actually is

Privacy/on-device is **one pillar, not the whole pitch.** Parleq is genuinely valuable even for cloud-first users. Differentiators, ranked by ownability:

1. **The voice refinement loop.** Dictate → see the cleaned result → *talk back to it* ("make it more concise," "more formal," a numbered preset) → refined — all without the keyboard. Most dictation apps are one-shot (speak → paste). This is the soul of Parleq and is under-shown today.
2. **On-device and cloud are complementary, and the split is configurable.** You can keep **first-pass cleanup on the on-device tier** and route **refinement / quick-chips / per-app styled cleanup to a cloud provider** — set explicitly in Settings (verified: `Config.swift:559`, `SettingsWindow.swift:1954`). So a single dictation can use both. **This is a user-configured split, NOT an automatic confidence-gated handoff** (that remains an unshipped idea — do not depict auto-escalation).
3. **Per-app cleanup, per engine.** Choose which cleanup each app uses — cloud-grade for Slack/email, instant on-device for a terminal chat. Per-app *preset/styling* defaults ship today (`preset_app_defaults`); per-app *engine/provider* selection is **in active development in a parallel effort, and the website release is coupled to it shipping** (§9 release gate) — so it is presented **present-tense, no preview label**. The user-chosen-destination boundary still holds (independent rows, never a routing fan-out; §3).
4. **Gets your words right** — voiceprints, custom dictionary, numbers/punctuation/ITN. The accuracy substrate.
5. **Privacy architecture** — your *voice* never leaves your Mac (audio is always local); transcript text crosses only the one boundary *you* choose, and on the on-device cleanup path it crosses none.

## 3. Copy / accuracy guardrails (hard constraints)

- **Scrubbed copy deck is the only build input.** The ChatGPT/codex pack is **reference for visuals only**. Before build, produce a `web/docs/superpowers/specs/copy-deck.md` with final, accuracy-checked strings per beat; the builder works from *that*. Do **not** import strings from the pack — it contains four forbidden lines and a wordmark chip (verbatim: "Nothing leaves your Mac", "100% on-device", "Everything runs on your Mac… Nothing leaves your device", "On-device Concord"). Physically avoid re-pasting them.
- **No blanket "Nothing leaves your Mac."** True only for audio (always) and for cleanup *when the on-device tier is selected*. Cloud cleanup (Gemini / Vertex / Bedrock / Azure) is first-class. The always-true privacy line is **"Your voice never leaves your Mac"** (audio). For cleanup: **"on-device, or the cloud you bring — your call."**
- **"On-device cleanup" is the protagonist; "Concord" is attribution, not a wordmark.** The engine node is labeled by **function** ("On-device cleanup") with a small **"built on Concord (by Keavi)"** credit. Note two on-device cleanup paths exist: **Concord's deterministic lightweight tier** (the grape cluster honestly depicts *this*) and **Gemma 4 MLX**, a neural on-device LLM (*not* a cluster of discrete helpers). The cluster is therefore an **illustrative device for the Concord tier**, never the definition of all on-device cleanup (§4a). Concord ships in the downloaded release build (trait-on) but is excluded from the default OSS source build (trait-gated) — fine to feature the product's behavior; don't imply the cluster *is* the engine.
- **voiceprints — accurate description only.** voiceprints **acoustically disambiguate sound-alike words/names**; they do **NOT** "learn your filler words, rhythm, or speaking style so the output sounds like you" (the pack's seductive-but-wrong copy). Lowercase, never camelCase, never ™, never a wordmark-y badge.
- **Keep the voice-routing vision private.** The per-app section is strictly about *which cleanup each app uses*, and must be drawn as **independent per-app rows** (a dictation already in each app, each with its own configured cleanup) — **never** a single voice fanning out to multiple destination apps, which *is* the private routing diagram. No "speak → Parleq decides where to send it," in copy or picture or motion.
- **No invented pricing or sales copy.** Preserve product truth and existing routing/IA.
- Entity for copyright/attribution: **Keavi LLC**.

## 4. Core concept — the flow grammar as the spine of beats 1–4

The ChatGPT design uses the "input card → engine node → output card, wired by flow lines" once, in the hero. **We make that grammar a recurring motif across beats 1–4** — the same visual language re-staged to teach each differentiator — and the grammar must **frame real product artifacts (overlay mockups, real before→after tokens), not replace them with abstraction** (the showcase pass proved show-don't-tell with *concrete* renders is what converts). Beats 5 (accuracy band) and 6 (enterprise) are deliberately *not* flow-grammar staged; the motif is a spine, not a universal template. **Each staging must be structurally distinct** (single-pass / loop / engine-reveal / per-app rows) to avoid template monotony.

This replaces the flat 12-card capability grid — but its long tail must not be silently dropped (§5.5).

### 4a. The grape cluster (the Concord tier made tangible — and honest)
Concord is literally a grape variety (hence the grape color); the metaphor is *latent in the name*. Concord's lightweight tier genuinely **is** one fast unit made of many small, distinct, deterministic correction helpers (voiceprints, punctuation, number/ITN cleanup, dictionary, compound). The cluster **demystifies** that tier into understandable parts and gives a built-in roadmap visual ("the cluster grows").

- **Scope:** the cluster is the **beat-3 reveal device for the Concord deterministic tier only** — not the whole-page mascot, and not a depiction of Gemma on-device cleanup.
- **Seed:** the engine node opens into a refined cluster of component nodes, each with a tiny functional glyph (waveform = voiceprints, `#` = numbers, etc.).
- **Hard rule:** geometric and refined, **never cartoon/photoreal 3D grapes.**

### 4b. Choreographed flow motion (information you can watch move)
Flow lines are pure SVG/CSS (no raster), built on the pack's static Bézier path data. **The pack ships only path data + one dash animation — the pulse/glow/loop/branch choreography is net-new and must be scoped as its own work item (§8), prototyped on ONE beat before committing to all four.** The win is **choreography, not more motion**: a pulse leaves "You speak" → travels the line → the engine **glows on receive (event-driven, decays — never an idle shimmer)** → a pulse emerges → arrives at "Parleq pastes." Restraint is the whole game (§7).

### 4c. The synthesis (north star) — grapes light up for the work they did
The traveling pulses are tiny grapes, and the **right grape lights up for the correction it handled** (Concord tier). This is the **north-star fast-follow, NOT a v1 gate** (§9): its entire value is motion, so it degrades to nothing for reduced-motion users and is the hardest to make jank-free. **Its static baseline must still convey the idea without motion** — e.g. each before→after example *statically labeled* with the helper that handled it — and it must read as a *scripted illustration*, never imply live runtime processing. Carries a non-color cue (glyph/label), since it is inherently color-coded.

## 5. The narrative arc (homepage beats)

Each beat 1–4 re-stages the flow grammar around **real artifacts**. Copy below is directional; final strings live in the scrubbed copy deck (§3). Every beat states its conversion intent; GoatCounter click hooks are preserved/extended (§8).

1. **Hero — headline + single-pass transform.**
   Framed dark grape panel. Left: privacy pill *"Your voice never leaves your Mac"*, serif headline **"Speak freely. Paste clean."** ("Speak freely." near-white / "Paste clean." lavender), concise subhead, **primary CTA *Download for macOS* (GoatCounter `download-hero`)**, secondary *See it in action*, feature chips. Right: `You speak → [On-device cleanup] → Parleq pastes` with engine node + flow lines, wrapping a **real before→after payload**. A semantic text `<h1>` carries the message for SEO/screen readers even though the demo art is `aria-hidden` (§8). The hero demo on a dark panel is a **new light-on-dark component**, not a reuse of the warm-white `#hero-demo` (§M-notes); contrast ratios specified before build.

2. **"Not quite right? Just say so." — the refinement loop.**
   The flow grammar **frames the existing concrete `OverlayMockup` carousel** (real before / spoken-instruction / after text, model chip, destination) — the loop motion wraps the real text; it does **not** replace it with an abstract swoosh. Copy angle: most dictation apps stop at paste; Parleq lets you refine by voice, no keyboard.

3. **"Instant on your Mac. Powerful in your cloud. Your call." — the configurable split + engine reveal.**
   Shows the **user-configured** split: first-pass on the on-device tier ⇄ refinement routed to your cloud provider (§2.2). **No automatic handoff is depicted.** The on-device node opens into the **grape cluster** (4a, Concord tier). Privacy/accuracy framing per §3. *(Evolves the existing `#on-device` grape zone — treated as a contract change to dark-panel, not a drop-in reuse.)*

4. **"The right cleanup for every app." — per-app engine defaults.**
   **Independent per-app rows** (Slack, Mail, Terminal, Notes), each a dictation *already in that app* with its own configured cleanup engine (e.g. Slack → cloud, Terminal → on-device) — never a single source fanning out (§3). Presented **present-tense, no preview label**, because the site release is **gated on the per-app engine feature shipping first or simultaneously** (§9). The destination is always the app the user is already typing in — Parleq selects the *cleanup*, not the destination.

5. **"Names, numbers, the works." — accuracy band + capability index.**
   Four cards (voiceprints, custom dictionary, numbers & punctuation, private-by-design), each **led by its real before→after micro-example** (`parlay → Parleq`, `eight point nine million → 8.9 million`); icons are quiet supporting marks. **A condensed capability index preserves the 12-card long tail** (never-lose-a-dictation, reference windows, paste-where-you-started, MDM, learns-from-corrections, etc.) and its **inbound `how-it-works` deep links** — no silent deletion. Add a **mid-page CTA** here.

6. **"Built for teams who need control." — enterprise/trust strip.**
   Compact dark band, secondary, not salesy: SSO & directory, bring-your-cloud, no API keys on devices, auditable by design. *(Evolves `#enterprise`.)*

7. **Get Parleq — install walkthrough + final CTA.**
   **Preserve the tester-readable install walkthrough** (download → drag → in-context permissions → provider pick → hotkey) and the final CTA (GoatCounter `download-get-parleq`). Reserve a **structural social-proof slot** for post-Posit (rendered empty for now).

## 6. Visual system

Reuse/extend existing tokens in `web/src/styles/global.css`; do **not** ship a parallel `--color-concord-*` namespace (token sprawl + internal-wordmark smell).

- **Kept:** warm-white `--color-bg #fafaf7`, amber `--color-accent #d97706` (voice/action spark only, never a wash), `--color-grape #5b2a86` / `--color-grape-strong #43205f`, Fraunces display, Inter body, `.zone-grape`/`.accent-grape`/`.chip`/`.chip-grape`, `.reveal` observer, and the `prefers-reduced-motion` patterns.
- **New: a controlled grape RAMP derived from `#5b2a86`** with explicit hex (dark steps ~950→700 for the hero panel/trust strip; light steps ~300/200/100 for flow gradients + cluster nodes). The pack's `--color-concord-*` (e.g. `#8b4dcc`) and `--color-voice-*` (`#e87900`) are **off-brand** and must be reconciled to Parleq's grape/amber — the SVG gradient stops are rewritten to the new ramp (the pack's hardcoded fallbacks are removed). Actual hex values written here before build.
- **Contrast is specified, not asserted:** text-on-panel, amber-on-panel (small text/links risk failing AA on dark purple — verify ≥4.5:1 or restrict amber to large/non-text), lavender-headline-on-panel — all as pass/fail numbers in §6 before build.
- **Typography:** Fraunces for hero + section headlines (near-white + lavender highlight); Inter elsewhere.

## 7. Motion & accessibility — enhancement tiers

**Principle:** the page is complete and great with **zero** motion; the reduced-motion experience *is* the static baseline, built first. No device may depend on motion to convey its meaning (north-star included — §4c).

- **Tier 0 — static baseline / `prefers-reduced-motion`:** all beats fully render; flow lines as elegant static strokes; cluster static; before→after in resolved state; north-star idea conveyed via static helper labels. Fully usable with no JS.
- **Tier 1 — choreographed pulses:** one bright traveling pulse per active path; **event-driven** engine glow (fires on arrival, decays, stops — never idle shimmer); the rest static.
- **Tier 2 — cluster reveal (beat 3 only):** engine opens into the component cluster.
- **Tier 3 — north star (fast-follow):** per-correction grape lighting, behind a go/no-go gate after Tier 1 proves out.

**Cross-cutting rules:**
- Gate all motion behind `prefers-reduced-motion: no-preference`.
- **Pause offscreen** via a **re-firing** IntersectionObserver — distinct from the existing once-only `.reveal` observer — coordinated by a **single rAF loop**, not N independent loops (battery).
- Prefer cheap CSS `box-shadow`/opacity over animated SVG Gaussian-blur filters (the pack's `softGlow`/`wideGlow` on a `preserveAspectRatio="none"` SVG are a known scroll-jank/battery cost). **State a performance budget**: max concurrent animations, target frame cost, and a Lighthouse/CWV gate; test on a non-Pro Mac.
- Decorative SVG `aria-hidden="true"`; never color alone for corrections; visible focus rings; AA contrast on the dark panel (§6).

## 8. Technical approach & continuity

- **Stack:** Astro 5 + Tailwind v4 (`@theme` tokens) + vanilla JS. **No React** — port the pack's `ConcordFlowLines.tsx` markup to an Astro component (trivial), but **the choreography engine (pulses/glow/loop/branch/cluster) is net-new and scoped separately** (§4b); prototype its pulse+glow primitive on one beat first.
- **New components (likely):** `ConcordFlow.astro` (SVG + choreography, parameterized per beat), `GrapeCluster.astro`, `TransformCard.astro`, beat sections in `index.astro`. Reuse `SiteHeader`, `OverlayMockup`, `Logo`.
- **"Evolve existing" = contract change, not drop-in reuse.** The hero demo, refine carousel, and grape zone all encode a *warm-white, concrete-text* contract that the dark-panel/flow redesign breaks; each is re-derived (with its own dark-ground tokens + AA recheck), not reused as-is.
- **SEO/metadata continuity (preserve):** JSON-LD `SoftwareApplication`, title/description, the semantic text `<h1>` carrying the headline message (since hero art is `aria-hidden`), the `/PAR-lek/` pronunciation.
- **Analytics continuity (preserve):** GoatCounter `data-goatcounter-click` hooks on every CTA (`download-hero`, mid-page, `download-get-parleq`).
- **Mobile:** specify per-beat degradation (hide complex flow SVG / simple vertical connector per the pack's own notes); six beats is a long mobile scroll — keep it tight.
- **Print/share:** add a print stylesheet so the dark grape panels don't render as ink blocks.
- **Deploy:** unchanged — GitHub Pages via `.github/workflows/deploy-pages.yml` on push to `main` touching `web/**`. Build check: `cd web && npm run build`.
- **Process:** prototype in a git **worktree** under `../parleq-worktrees/` → adversarial + balanced subagent review → reconcile → PR **held at the approval gate**; promotion timing still gated on the Posit rollout.

## 9. Scope & phasing

- **v1 (this effort):** homepage end-to-end; reusable flow-grammar components; new dark-grape token ramp; **Tier 0 baseline + Tier 1 motion, plus Tier 2 on beat 3**. **Final copy and the icon-system decision are locked BEFORE the approval gate** (no "decide during build" for those). The dark-hero panel is prototyped and sanity-checked against "does this read as generic dark SaaS?" as an **early named checkpoint**.
- **Release gate (hard):** the redesigned site is **not released until the per-app cleanup-engine capability ships (first or simultaneously)** — beat 4 markets it in present tense, so the live site must match a build where per-app engine selection is real. Coordinate the site PR merge/deploy with that app release. (Parallel in-progress effort in another session.) Compatible with — and stacked on top of — the existing promotion-timing hold (Posit rollout).
- **Fast-follow (post-v1, gated):** Tier 3 north-star (grapes-light-up), pending a go/no-go after Tier 1.
- **Later passes:** propagate the visual language to `how-it-works`, `enterprise`, `about`, `faq`, `docs/*`.
- **Out of scope:** the voice-routing vision (private); pricing/sales framing; any other-page rewrite this round.

## 10. Alternatives considered

- **Fully on-device / privacy-maximalist hero:** rejected — undersells the product, hides BYO-cloud + the refinement loop.
- **Two-mode parity hero:** rejected — dilutes the 5-second story; complementarity is told in beat 3.
- **Keep the flat capability grid:** rejected — the known "hard to see how cool it is" problem; replaced by the arc (long tail preserved as a condensed index, §5.5).
- **Replace concrete overlay mockups with abstract flow art:** rejected after review — would trade away the show-don't-tell concreteness that converts; grammar *frames* real artifacts instead.
- **Grape cluster as the universal page mascot / definition of on-device cleanup:** rejected — brands Concord and misrepresents Gemma; scoped to a beat-3 Concord-tier device.
- **North star in v1:** rejected — Tier-3 complexity trap and a motion-dependent device; demoted to gated fast-follow.
- **Concord as named headline engine:** rejected per the wordmark constraint.

## 11. Open questions (for maintainer)

1. **Headline:** ✅ **RESOLVED — keep "Speak freely. Paste clean."** (the just-shipped #111 headline). "Messy" read slightly self-deprecating for a premium tool; "freely" stays. The pack's "Speak messy" is not used.
2. **Per-app beat (4):** ✅ **RESOLVED — full per-app engine routing, present tense, no preview label**, with the site release **coupled** to the per-app engine feature shipping (§9 release gate). Independent-rows boundary confirmed.
3. **Accuracy-band icons:** stroke icons vs. extending the grape-cluster glyphs — locked before the gate (§9).
4. **Tier 3 appetite:** confirm fast-follow (recommended) vs. attempting in v1.

## 12. Pre-gate checklist (must be true before implementation planning)

- [ ] Scrubbed copy deck written; pack strings not imported; voiceprints copy corrected.
- [ ] Grape ramp hex + dark-panel contrast ratios written into §6.
- [x] Per-app beat: present-tense full engine routing, rows-not-fan-out — confirmed. ⚠️ **release coupled to per-app engine feature shipping** (§9 release gate).
- [ ] v1 motion fenced (Tier 0–1 + Tier 2 beat 3); Tier 3 explicitly fast-follow.
- [ ] SEO/JSON-LD, semantic `<h1>`, GoatCounter hooks, install walkthrough, capability long-tail + how-it-works links: continuity confirmed.
- [x] Headline decision made — "Speak freely. Paste clean."

## 13. Reconciliation log (adversarial + balanced review)

**Adopted from adversarial:** scrubbed copy deck as sole build input + delete forbidden pack strings (C3); per-app drawn as independent rows, never a one-source fan-out routing diagram (C2); grape cluster scoped to the Concord deterministic tier, function-labeled engine, Gemma-is-also-on-device + trait-gating nuance (C4); dark-panel hero demo is a new light-on-dark component with specified contrast, not a reuse (M1); event-driven (not idle) glow + perf budget + cheap CSS over SVG filters (M5); choreography engine scoped separately and prototyped on one beat (M3); grape-ramp hex + reconcile off-brand pack colors, no parallel namespace (M4); SEO/JSON-LD/semantic-`<h1>` continuity (M8); GoatCounter + mid-page CTA continuity (M7); keep concrete overlay mockups in beat 2 (M6); north-star demoted to gated fast-follow with a working static baseline (M2); mobile per-beat degradation, print stylesheet, lock copy/icons pre-gate, re-firing IO coordinator, voiceprints-not-a-badge (minors).

**Adopted from balanced:** keep real artifacts inside the grammar as an explicit principle (#2); preserve the 12-card long tail + how-it-works deep links + install walkthrough (#3/#4); reserve a social-proof slot; require variation-within-grammar; name the dark-hero-vs-generic-SaaS checkpoint; acknowledge the through-line spans beats 1–4 only.

**Corrected against shipped code (independent judgment).** Adversarial **C1** claimed the single-dictation on-device↔cloud path is unshipped and demanded its removal. Verified false: a **user-configurable** first-pass-on-device / refine-in-cloud split *is* shipped (`Config.swift:559`, `SettingsWindow.swift:1954`). What is unshipped is the **automatic** confidence-gated handoff. Resolution: beat 3 depicts the *configurable split* ("your call"), not auto-escalation — preserving the (true) complementarity story while honoring the no-overclaim rule. This is the one finding where reconciliation diverged from a reviewer, backed by code.

**Not adopted / deferred:** none outright rejected; an A/B on hero-hints-at-refinement-loop (balanced LOW) is noted but deferred — emotional clarity keeps the loop in beat 2, rationale recorded in §10.
