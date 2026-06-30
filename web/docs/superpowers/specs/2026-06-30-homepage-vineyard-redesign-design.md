# Homepage redesign — the vineyard, the vine, the clusters, the grapes

**Status:** Design (locked direction) — **review-reconciled 2026-06-30** (two-agent + RoboRev pass; see §12); pending maintainer review
**Date:** 2026-06-30
**Branch:** `web/redesign-concord` (worktree `../parleq-worktrees/web-redesign`)
**Scope this round:** the **homepage** (`web/src/pages/index.astro`) only. Inner pages may adopt the metaphor in a later round.
**Supersedes for the homepage:** the flat-grid structure described in `copy-deck.md` Beats 4–5 and the current `index.astro` section order.

---

## 1. Why this round exists

The visual/structural redesign is complete and the copy is already accurate and well-voiced. The remaining problem is **content density and shape**, not bad copy. The homepage currently does five jobs that the dedicated inner pages already do in full:

- a hero with a live transform demo,
- a long on-device-cleanup deep-dive (with a *sub*-deep-dive into the grape cluster),
- a 5-slide refinement carousel,
- a **twelve-card** capability grid where **every card links out to a how-it-works anchor**, and
- an enterprise band + a 5-step install walkthrough.

That last tell is the diagnosis: the 12-card grid is a **table of contents wearing the costume of content**. The page is long because it restates how-it-works (6,500 words), enterprise (1,900), and the install guide inline instead of trusting those pages to carry depth.

**Goals**
1. Make the homepage a short, captivating "trailer" that makes a first-time visitor *want* Parleq and *understand* it fast.
2. Solve density by **delegating depth** (to inner pages) and by **progressively disclosing** it (visible at a glance, deeper on click), not by shaving every section. **"Shorter" = default/perceived scroll length and section count, not built-HTML byte count** — the full demo content stays in the DOM (no-JS, screen readers, SEO), just collapsed by default. Target: ≤ 6 scroll sections; the new vine section's always-visible height nets shorter than today's on-device deep-dive + 5-slide carousel + 12-card grid combined.
3. Give the page one coherent organizing idea that doubles as the competitive wedge.
4. Fold in the **per-app cleanup** feature (from the `per-target-cleanup` worktree) **if and only if it is runtime-complete at merge** — see §7. As of this writing the feature is config-model-only (not wired into dictation routing), so the old "Beat 4 release gate" is **moved, not retired**.

**Non-goals (this round):** restructuring inner pages; the white-on-amber CTA contrast fix (tracked separately); the deferred inter-section flow connectors; any change to app behavior or shipped features.

---

## 2. The organizing idea: a vineyard metaphor

A single nested metaphor gives the page its spine, its visual language, and its positioning. It maps to **product truth at every layer** — it is not decoration applied on top.

| Layer | Metaphor | Product truth |
|---|---|---|
| The boundary | **Vineyard** — fenced ground, gated | Your Mac = the trust boundary. Audio stays inside; text leaves only through a gate you choose. |
| The plant | **Vine** = Parleq | A collection of clusters that compound — more than the sum of single tricks. |
| Families | **Clusters** | Capability families: Cleanup · Refine · Built for teams. *(Cleanup is **built on Concord** — attribution only, never the cluster's name. Of the three, only Cleanup and Refine are interactive on the homepage; Built for teams is a teaser that links out.)* |
| Capabilities | **Grapes** | Individual features, explorable on click. |

### 2.1 The vineyard turns our hardest constraint into an asset

We are forbidden from saying "nothing leaves your Mac" because cleanup *can* cross to a cloud the user brings. The vineyard **encodes the real model as imagery** instead of fighting it:

- **The vineyard is your Mac.** *Your voice never leaves the vineyard.* (Audio is always local — fully true, and the required string. **Audio never approaches the gate.**)
- What crosses the fence is only what you send out **for cleanup**, and only through a **gate you chose**:
  - your **cleaned-up text** — and, *only if you attach it,* a **reference snapshot** you point at (a window, file, or clipboard; PNG/data held in memory, never written to disk);
  - pick **on-device (Instant) cleanup** → *no gate is crossed at all*;
  - pick **a cloud you bring** → *it crosses to a gate you control*, and reference snapshots go only to the LLM endpoint you configured.
- **The gatekeepers are the enterprise story.** Federated SSO is literally who-gets-checked-at-the-gate. So the vineyard **unifies privacy and enterprise** under one idea: *what crosses the fence, and who controls the gate.*

> **Accuracy note (RoboRev 7261):** do **not** write "the only thing that crosses the fence is cleaned-up text." Reference Windows can also send an attached window/file/clipboard snapshot to the configured LLM. The accurate claim is: *audio never crosses; cleaned-up text crosses for cleanup/refine (nothing crosses on Instant/on-device); reference snapshots cross only when you attach them, only to the endpoint you configured.*

### 2.2 The positioning wedge (no competitor named)

"A cluster of great ideas that work together — more powerful than the single-trick alternatives." The cluster **is** the claim, and it makes the comparison *implicitly and visually* (other tools are one grape; Parleq is the bunch). This answers "why switch?" without a feature-vs-feature table and **without naming any competitor** (per the private-vision and no-competitor-reference constraints). The "more powerful together" idea lands at two levels: grapes within a cluster, and clusters across the vine.

### 2.3 Concord stays correctly scoped, for free

The **Cleanup** cluster is built on Concord (by Keavi) — the on-device deterministic correctors. "Concord" is an **attribution, not the cluster's name or a product label**; the cluster is called "Cleanup." The nesting keeps the attribution from smearing across the whole app: when a visitor opens the **on-device cleanup** grape, its demo reveals *its own* inner correctors sub-cluster, and that is the only place "built on Concord (by Keavi)" appears.

---

## 3. Restraint guardrails (HARD rules for implementation)

The metaphor is powerful precisely because we hold it back. These are non-negotiable and become review checkpoints:

1. **No literal farm.** No cartoon gatekeepers, no leaves/tendrils/sun/rolling-hills illustration. The vineyard lives in **language + restrained visual containment** (a fence line, a framed boundary, the existing dark-grape ground) — never an illustrated scene. **Grapes are flat, circular UI buttons** (deep-grape fill, subtle radial highlight, soft rim light, a simple stroke icon, a short label, a clear selected/focus state) — **not** photoreal 3-D fruit, water droplets, vines, leaves, or tendrils. *(The B/C prototype renders with realistic grapes + leaves are explicitly rejected; borrow their composition, not their texture.)*
2. **The metaphor is a lens, not a renaming.** Real feature labels stay literal: "Per-app cleanup," not "the targeting grape." Headlines may lean poetic; **UI controls, feature names, and nav stay plain.**
3. **Curate, don't enumerate.** Show abundance and let people explore; never render every grape inline.
4. **Two flagship *interactive* clusters** (Cleanup + Refine). "Built for teams" is the **third cluster on the vine conceptually** but is **non-interactive** on the homepage — a teaser band that links out, not an explorable bunch. (Three families in §2's table; two interactive — keep these consistent.)
5. **Privacy is a posture, not a clickable cluster.** The **literal** required line ("Your voice never leaves your Mac") anchors it in the hero; the **vineyard** is its single *narrative* expression (§4, section 3). Don't relitigate the fence/gate in every section.
6. **All existing locked conventions are preserved** (see §8): two-tier hero, FloatingNav, grape footer, card-on-purple transition, GrapeCluster/ConcordFlow/OverlayMockup components, DocTabs, tokens, accessibility/reduced-motion/no-JS discipline.
7. **The metaphor is never a prerequisite to understanding.** Every literal claim (what Parleq does, the privacy promise, each capability) must stand on its own in plain language; vineyard/vine/cluster/grape is an *enhancement layer* a visitor may enjoy but never has to decode. If understanding the page requires "getting" the metaphor first, it's wrong.

---

## 4. Homepage skeleton (target)

A bold "trailer": short scroll, deep on click, one world holding it together. Sections, top to bottom:

1. **Hero — "Speak freely. Paste clean."**
   - Keep the live transform demo (the crown jewel) and the FloatingNav-over-grape treatment.
   - **Sharpen the subhead** to lead with the wedge, not the category. Lead with the differentiator (talk-it-into-shape + your-words-right); keep "/PAR-lek/" and the macOS/Apple-Silicon facts.
   - **The literal privacy claim stays prominent.** "Your voice never leaves your Mac" is the legally-vetted, harness-checked line and must read as a clear, first-class statement (the existing privacy pill is fine as its anchor) — **not** demoted beneath the metaphor. The vineyard restatement ("…never leaves the vineyard") is **secondary support, used only after** the literal claim lands and the metaphor is established; a first-time visitor must not have to decode "vineyard" to understand the privacy promise.
   - CTAs unchanged (Download / See it in action). Feature chips may be retuned to name the clusters.

2. **The vine — interactive clusters (the heart).**
   - A short framing line establishes the wedge **in text** (so it survives mobile/screen-reader linearization, where the bunch flattens to a list): *Parleq stacks small, sharp wins into clean text — a whole bunch, not one grape.* The comparison stays implicit (no competitor named).
   - **Cluster 1 — Cleanup (built on Concord):** the on-device deterministic correctors. Reuses today's `GrapeCluster`. Opening a grape reveals the Concord sub-cluster + a before→after demo.
   - **Cluster 2 — Refine & shape it:** cleanup with the AI you bring · talk it into shape (the refine loop) · one-tap presets · **per-app cleanup** · reference windows.
   - Each grape is an accessible control that opens a **demo overlay** (see §6) with back/next/close and "next grape."
   - This single section replaces today's separate on-device showcase **and** the 5-slide carousel **and** the 12-card grid — their content is redistributed into grapes (curated, not exhaustive), so depth becomes opt-in.

3. **The vineyard — private by design.**
   - **Candidate headline (ChatGPT round):** *"Your Mac is the vineyard."* + support *"Your voice stays inside; text only crosses the gate you choose."* Prototype **C** is the atmospheric reference for this section — borrow its subtle fence/boundary + light-lavender ground (differentiated from the dark hero), drop the literalness.
   - **This section owns the *fence*** (what crosses): the literal "Your voice never leaves your Mac," then — what you send out for cleanup is your cleaned-up text (and, only if you attach it, a reference snapshot you point at), through a gate you choose: **nothing crosses at all on Instant/on-device**, or a cloud you control.
   - **Do not** reduce this to "only cleaned-up text crosses" (see the §2.1 accuracy note — reference snapshots can also cross when attached).
   - **The fence visual appears here, once.** Restrained containment only (no farm scene). Links out to how-it-works / security review for depth.

4. **The gate for teams — enterprise.**
   - **Division of labor:** section 3 owns the *fence*; this section owns the *gatekeeper* (who's checked: SSO, per-user audit). **No repeated fence motif here** — otherwise the two adjacent sections read as saying the same thing twice (the opposite of the goal). Text/enterprise-band moment only.
   - Keep the dark-grape enterprise band (already tight): one sign-in, per-user audit, no Parleq servers in the path, security-review packet. Links to `/enterprise`, SSO setup, managed configuration, security review. **Non-interactive teaser cluster — it links out.**

5. **Get Parleq.**
   - Keep the tester-readable 5-step install walkthrough — **the five steps and their order stay intact** (download → drag → permissions-in-context → pick a provider incl. on-device → hotkey); copy may be lightly retuned to voice, but the permissions-in-context step is preserved. Keep the final CTA + "View source" + license line + the reserved (empty) social-proof slot.

**Net change vs. today:** the on-device deep-dive prose, the standalone refine carousel, and the flat 12-card grid collapse into the single interactive vine section. The hero, enterprise band, and install section stay (sharpened). The page is **shorter by default-scroll** (fewer sections, less always-visible prose) while keeping the depth in the DOM behind progressive disclosure — see the "shorter" definition in §1. It is deliberately **not** shorter in raw HTML (no-JS + SEO resilience).

---

## 5. Capability curation (which grapes, which cluster)

Curated, not exhaustive. Enterprise-only capabilities leave the consumer clusters and live in the enterprise teaser / `/enterprise`.

**Cluster 1 — Cleanup** (built on Concord — attribution only, not the cluster name). Grapes: Punctuation & casing · Numbers & percents · Your words (custom dictionary) · Sound-alikes (voiceprints). *(Phonetic and compound are supporting members shown inside the on-device correctors sub-cluster, not top-level grapes.)*

**Cluster 2 — Refine & shape it** (lock to **4** grapes). Default roster: Cleanup with the AI you bring (providers + on-device LLM) · Talk it into shape (the refine loop) · One-tap presets · Reference windows. **Per-app cleanup** becomes the 4th *only if* runtime-complete at merge (§7) — and if it's in, **Reference windows demotes** to a supporting member so the cluster stays at 4. Roster size must not depend on whether the gated feature ships.

**Moved OUT of the homepage clusters → enterprise teaser / `/enterprise`:** MDM / managed configuration; compliance-by-default posture (folds into the vineyard moment); per-user audit; federated SSO.

**Posture, not a grape (woven into the vineyard moment):** audio-never-leaves, no-backend, keys-in-Keychain, never-lose-a-dictation.

> Open item for the plan: a final pass to confirm the grape list against the live capability set, including any new capabilities the `per-target-cleanup` branch adds. Aim for ~4 grapes per flagship cluster — enough to feel abundant, few enough to stay curated.

---

## 6. The grape explorer (interaction)

> **Updated 2026-06-30 after the ChatGPT visual-prototyping round (see §13).** The default desktop interaction is now a **split-stage explorer (persistent cluster + in-place demo panel)**, *not* a modal. This is both better UX (the bunch stays visible; exploration is continuous) and a major build de-risk: it's a **tabs/tabpanel** pattern we can model on the existing `DocTabs`, so **no focus-trapping dialog, no `inert`, no backdrop is needed on desktop.** Supersedes the modal-default + staging language recorded in §12.

The captivating centerpiece. **Two layers, deliberately:**

- **At a glance (no interaction):** the cluster's grape **labels + icons** read as a capability map, and **one grape is selected by default**, so its demo panel already shows a real before→after on load. A bouncing or screen-reader / mobile visitor grasps what the section offers without clicking. The wedge ("a bunch beats one grape") is **legible in text** (the section intro), not carried by the bunch shape alone (it flattens to a list on mobile / for SR).
- **On select (extra depth):** choosing a grape swaps the demo panel **in place** to that capability's demo (optionally stepped). Selection is *enhancement* — never the only way to learn what a capability is.

**Division of labor with the hero:** the hero is the single **end-to-end** "speak → clean" wow; the grapes are **atomic, single-mechanism** reveals. Avoid building eight mini-heroes.

### 6.1 Desktop — split-stage explorer (default)
- **Layout:** left = the section intro + the two clusters (Cleanup, Refine) as grape **buttons**; right = a single **demo panel** styled as Parleq's dark floating overlay (reuse `OverlayMockup`). One grape is selected on load.
- **Pattern = WAI-ARIA tabs.** The grapes are a `tablist` of `tab` buttons; the demo panel is the `tabpanel`. **Model it on `DocTabs`** (hash-aware deep-link, no-JS fallback). No modal, no focus trap, no `inert`, no backdrop on desktop — far less new plumbing than the earlier modal plan.
- **Selected grape:** slightly larger, brighter grape rim, subtle amber edge, `aria-selected` + focus-visible ring; decorative amber→violet **flow lines** (reuse `ConcordFlow` language, `aria-hidden`) run from the selected grape into the panel.
- **Demo panel:** before→after (or a short step sequence); a small **per-grape status chip** (accuracy-critical — see §6.3); optional Back / Next for multi-step; a **"Jump to another grape"** chip row beneath (= quick tab switches) + an "Explore all / how it works →" link out.
- **Content:** reuse `OverlayMockup` / `TransformCard` / the on-device before→after strip (see §8). **Default every grape to a single before→after (1 step);** reserve multi-step (≤4) only for genuinely sequential capabilities — "talk it into shape" and per-app. Don't over-build 4-step demos for atomic corrections.

### 6.2 Mobile, no-JS, and accessibility
- **Mobile (below `md`):** do **not** force the bunch as the control. Small decorative cluster at top; **tabs for Cleanup / Refine**; a **vertical list of grape buttons**; the selected grape **expands inline** into its demo card; flow lines hidden/simplified.
- **No-JS / baseline (ship-ready v1):** the tablist+panel degrades to the `DocTabs` no-JS model (all panels render; script hides inactive). The at-a-glance before→after stays visible without JS. Everything beyond this is enhancement.
- **Grapes are real `<button>`s:** keyboard-reachable, visible focus ring, accessible name = the **plain feature label** (never metaphor copy); selected state via tab semantics. Decorative flow lines / art `aria-hidden`. Respect `prefers-reduced-motion` (no path animation; instant panel swap). Transitions ~150–250 ms select / ~300–500 ms panel.
- **Optional modal:** only if a specific demo needs a larger surface (or on mobile). If used, it behaves like Parleq's overlay with Back/Next/Close and returns focus to the selected grape. **Not the default, not on the critical path.**

### 6.3 What a "demo" is (per grape, examples — finalize in the plan)
- **Per-grape status chip (ACCURACY-CRITICAL).** On-device cleanup grapes (punctuation, numbers, your words, sound-alikes) show an **"On-device"** chip and may state processing stays on the Mac *for that capability*. Refine grapes that use the configured provider (talk-it-into-shape, presets, reference windows, per-app Polished) must **not** show "On-device" — chip them "Your cleanup" / "Your provider" or omit the chip. **Never put a section-wide "100% on-device / No cloud / Nothing leaves your Mac" band under the explorer** — the prototype images (B, C) do exactly this, and it's the forbidden blanket claim, because the explorer spans both on-device and cloud-capable grapes. Privacy is scoped **per grape**, via the chip — not asserted over the whole section.
- *Punctuation & casing:* `"did the build pass and is it ready to ship"` → `Did the build pass and is it ready to ship?`
- *Numbers & percents:* `eight point nine million` → `8.9 million`; `forty five percent` → `45%`
- *Your words:* `parlay` → `Parleq` (dictionary biasing)
- *Sound-alikes:* `kiwi` → `Keavi` (voiceprint disambiguation; the kept voiceprint is **a derived mathematical signature, not your dictation audio**). ⚠️ Do **not** assert the absolute "never a recording": the Concord/release build's opt-in durable-voiceprints feature keeps encrypted *enrollment* clips at rest (`EnrollmentAudioStore`). This line also appears in today's live copy — reconcile it before shipping (flagged to maintainer).
- *Talk it into shape:* an `OverlayMockup` with a refine instruction and the reshaped result (reuse a carousel scenario).
- *Per-app cleanup* (⚠️ **gated — see §7**; include only if runtime-complete, else omit/future-tense): show **one app at a time** with the cleanup *level* you set for it (e.g. Instant in a terminal; Polished in Mail). Do **not** show one utterance fanning out to multiple apps — "landing in different apps" reads as destination routing (the private vision). Frame as "the cleanup you set per app," never routing.
- *Reference windows:* `OverlayMockup` with an attachment pill + the PNG-in-memory privacy note.

---

## 7. Per-app cleanup — accurate copy guidance

> ⚠️ **GATE: per-app cleanup is NOT shipped yet.** In the `per-target-cleanup` worktree it exists only as the config model + curated map + resolver + tests — `TargetMode` / `AppBehavior` / `behaviorForApp` / `CuratedAppDefaults` have **zero runtime callers** and are not consulted by live dictation routing. **Do not market it present-tense until it is runtime-complete and merged.** Until then, treat the per-app grape as **deferred**: either omit it from the launch cluster, or ship it explicitly future-tense ("coming"). This is the same Beat-4 gate as before, moved — the site must not claim a feature the app doesn't perform.

When the feature *is* runtime-complete and merged, copy must match it exactly.

**The cleanup modes (`TargetMode`, three values):**
- **Instant** — forced on-device deterministic correction (built on Concord): in-process, ~0 ms, **no LLM, no network, no model download.** (This tier itself shipped in 0.27.0 as the "Lightweight (on-device)" cleanup provider.) *(Avoid the forbidden phrase "on-device Concord" — see §9.)*
- **Polished** — today's pipeline unchanged: routes to the user's **configured** cleanup provider, which may be a **cloud LLM (Gemini/Vertex/Bedrock/Azure) OR an on-device option (the MLX `local` LLM, or Concord).** **Polished is NOT synonymous with cloud.**
- **Raw** — skip cleanup, paste the transcript as recognized (the old `none`).

**What per-app adds (safe to say, once shipped):**
- You can set **which mode each app uses**, by app. Parleq ships **curated defaults** so it works out of the box: terminals, IDEs, and spreadsheets default to **Instant**; chat, email, docs, and browsers default to **Polished**.
- For some communication apps Parleq also **suggests** a tone (e.g. "Professional" for Mail/Outlook, "Friendly & concise" for Slack/Teams) as a **one-tap, dismissable suggestion you accept — never auto-applied.** A tone preset attaches only to **Polished** mode (it's meaningless for Instant/Raw).
- Resolution order: your per-app override → the curated default mode → Polished.

**Must NOT say:**
- Do **not** frame it as per-app **provider/engine** selection. It is per-app **mode** (Instant / Polished / Raw).
- Do **not** equate "Polished = cloud." Polished routes to the user's configured cleanup, which may be on-device. Frame the per-app contrast as **"instant on-device vs. fuller cleanup,"** not "on-device vs. cloud."
- Do **not** imply the suggested tone is applied automatically — it is suggested only.
- Do **not** say IT can lock per-app **modes** via MDM. MDM gates the per-app **tone preset** (via `transformPresetsEnabled`); the mode still resolves when presets are disabled.
- Do **not** claim per-app cleanup is available today until it is runtime-wired (see the gate above).
- Do **not** expose any cross-app *routing/destination* vision (kept private).

> Mode semantics and MDM-gating above are confirmed against `Config.swift` / `CuratedAppDefaults.swift` in the `per-target-cleanup` branch. **Reconcile once more — and re-confirm runtime-completeness — against the merged branch at integration time before any per-app copy ships.**

---

## 8. Locked conventions preserved (do not fight these)

- **Two-tier hero hierarchy** (deep grape marquee for home).
- **`FloatingNav.astro`** pill, `spacer={false}` on the homepage hero; active = `aria-current` + amber underline.
- **Grape footer** in `Layout.astro`.
- **Card-on-purple transition** — the first white section overlaps the grape hero (`-mt-16`, `sm:rounded-t-[28px]`, the documented shadow), inside the hero's `max-w-[1700px]` frame. *(If the vine section becomes the first white section, it inherits this treatment.)*
- **Components:** reuse `GrapeCluster`, `ConcordFlow`, `OverlayMockup`, `TransformCard`. New work = the interactive-overlay wrapper + grape-button affordances; prefer extending existing components over new ones.
- **Tokens** in `global.css` (grape ramp, panel-ink, flow-voice/flow-clean, hero-light); Fraunces display + Inter body.
- **The table-cell `<code>` template-literal gotcha** — use entity-escaped braces, never a JS template literal inside `<code>` in a table cell.

---

## 9. Accuracy & legal constraints (carry-through)

- **Required strings** (homepage built HTML): "Your voice never leaves your Mac"; "built on Concord" (the `verify-page.mjs` harness checks this substring; **write the attribution in full as "built on Concord (by Keavi)"** to preserve the Keavi LLC credit). Both required strings must sit in **static** DOM, never behind JS-only rendering.
- **Forbidden strings:** "Nothing leaves your Mac" / "...your device"; "100% on-device"; "On-device Concord"; "Everything runs on your Mac"; voiceprints described as learning / rhythm / filler / hesitations / "sounds like you".
- **Concord** = attribution only, never a wordmark/product/logo.
- **voiceprints** = lowercase; they **disambiguate sound-alike words**; they do **not** learn speaking style. The voiceprint is a **derived signature, not your audio**; do **not** claim an absolute "never a recording" (the opt-in durable-voiceprints feature keeps encrypted *enrollment* clips at rest — `EnrollmentAudioStore`).
- **Routing/destination vision stays private.** Per-app content = "Parleq applies the cleanup you set per app," never destination routing.
- **"What crosses the fence" must stay accurate (RoboRev 7261).** Audio never crosses; cleaned-up text crosses for cloud cleanup/refine (nothing crosses on Instant/on-device); **reference snapshots (window/file/clipboard) cross only when the user attaches them**, only to the configured LLM endpoint. Never write "only cleaned-up text crosses."
- **Entity = Keavi LLC.**
- Run `node scripts/verify-page.mjs` (accuracy + a11y) after every copy change; contrast via `node scripts/contrast.mjs`.

---

## 10. Verification

- `npm run build` clean.
- `node scripts/verify-page.mjs` green (required/forbidden strings, a11y assertions).
- Manual: keyboard-only walkthrough of the **split-stage explorer** (tab between grapes, panel swaps in place, Back/Next, Jump-to chips); focus-visible ring on grapes; reduced-motion (instant panel swap, no flow-line animation); **no-JS check (all panels render, at-a-glance before→after visible)**; mobile (tabs + inline expand).
- **Privacy-chip accuracy:** every demo panel's status chip matches the grape (on-device grapes = "On-device"; refine/provider grapes ≠ "On-device"); **no section-wide blanket "on-device / nothing leaves your Mac" claim** anywhere under the explorer.
- **"Shorter" check:** default-scroll section count ≤ 6; the vine section's always-visible height is less than today's combined on-device + carousel + grid. Record the before/after.
- **SEO check:** the relocated how-it-works-style content + its internal links remain in the **rendered** HTML at reasonable prominence (progressive disclosure, not JS-injection); required strings + the Concord attribution sit in static DOM.
- RoboRev auto-review on each commit; work through findings before the approval gate.
- **Release gate (per-app cleanup, §7):** per-app cleanup is currently config-model-only (not runtime-wired). If the homepage ships a present-tense per-app grape, the site **must** ship together with a runtime-complete, merged `per-target-cleanup` feature. If the feature isn't runtime-complete at release, the per-app grape is **omitted or shipped future-tense**. Also still respects the Posit promotion-timing hold.

---

## 11. Open questions for the plan

Several earlier opens were **resolved in the 2026-06-30 review reconciliation** (see §12): demo-depth default (1-step; multi only for refine/per-app), the hero-vs-vine division of labor (end-to-end vs atomic), the "shorter" definition, the staged build, and the next-grape traversal. Remaining:

1. **Vine layout** — how the two interactive clusters are arranged (side-by-side vs. stacked), and how grapes lay out within a cluster at each breakpoint.
2. **How literal the vineyard visual gets** — settle the "restrained containment" treatment (fence line? framed boundary? gate motif?) within guardrails #1/#7. *(Good question for the ChatGPT visual-prototyping handoff.)*
3. **Hero subhead final wording** — sharpen to the wedge while keeping the prominent literal privacy line + pronunciation + platform facts.
4. **Final grape roster** — confirm the locked 4-per-cluster against the live + per-target-cleanup capability set.
5. **What gets dropped *entirely*** — "curated, not exhaustive" means some current grid/carousel capabilities won't appear on the homepage at all (only on how-it-works). Name them explicitly so nothing valuable is silently lost.
6. **Grape-content table (required plan deliverable)** — one table: grape → demo type → step count → before/after copy → component used. This is where accuracy bugs hide (a dozen-plus authored before/afters, each must pass verify-page.mjs).
7. **Instrumentation** — whether opening a grape fires a GoatCounter event (captivation is cheaply measurable; CTA tracking already exists).
8. **Hero live-demo** — keep as-is, or re-point it to foreshadow the vine (now that hero = end-to-end, vine = atomic)?

---

## 12. Review reconciliation (2026-06-30)

The spec was reviewed by two independent agents (one adversarial, one constructive) plus RoboRev. Findings reconciled as follows.

**Applied (accuracy — non-negotiable):**
- Removed "Concord" as a cluster wordmark (cluster is **Cleanup**; Concord is attribution only) — §2 table, §2.3, §5.
- Scrubbed the forbidden phrase "on-device Concord" from the spec's own prose — §7.
- Required attribution written in full as "built on Concord (by Keavi)"; required strings pinned to static DOM — §9.
- Softened the voiceprint claim away from the absolute "never a recording" (the durable-voiceprints `EnrollmentAudioStore` keeps encrypted *enrollment* clips) — §6.3, §9. **(Also affects today's live copy — flagged below.)**
- Reframed the per-app demo to one-app-at-a-time "cleanup level," never one-utterance-to-many-apps, to avoid reading as the private routing vision — §6.3.
- Qualified the vineyard egress copy for reference-window snapshots (RoboRev 7261) — §2.1, §4, §9.

**Applied (design — improves the goals):**
- Defined **"shorter"** as default/perceived scroll length, not HTML bytes (no-JS keeps content for resilience + SEO); added a section-count budget and a length check — §1, §4, §10.
- Made grapes **legible at a glance** (visible before→after, no click); the overlay is *extra depth*. Hero = end-to-end wow; grapes = atomic reveals (kills demo-fatigue / behind-the-click risk) — §6.
- Carried the competitive wedge **in text**, not just the bunch composition (survives mobile/SR) — §4, §6.
- **Staged the build:** no-JS `<details>` disclosure is v1 (ship-ready); fade/scale modal is v2; dropped shared-element FLIP as the default — §6.2.
- Kept the **literal privacy line prominent**; vineyard is secondary narrative — §4.1, guardrail #5.
- Split **fence (§3) vs. gatekeeper (§4)** so the two sections don't repeat — §4.
- Added guardrail **#7: the metaphor is never a prerequisite to understanding.**
- Reconciled enterprise as the conceptual-third, non-interactive cluster — §2/§3/§4.
- Locked Cluster 2 to **4 grapes** regardless of whether per-app ships (Reference windows demotes if per-app is in) — §5.
- Defined next-grape traversal (within-cluster), focus-restore target (last-viewed grape), background `inert`; mobile = inline disclosure — §6.
- Added SEO check; added open items for "what's dropped entirely," the grape-content-table deliverable, and instrumentation — §10, §11.

**Flagged to the maintainer (judgment calls — not changed unilaterally):**
1. **"Never a recording" appears in today's *live* copy** (homepage + copy-deck), and is an overclaim given the opt-in enrollment-audio store. Recommend a small wording fix on the live site too, not just here.
2. **White-on-amber CTA contrast (3.19:1, below AA)** is currently a non-goal "tracked separately." A flagship relaunch is the natural place to fix it; recommend folding the `--color-accent-hover` swap into this round. Your brand call.
3. **Wine connotation** of vineyard/grape/cluster for a workplace tool — low-cost to pressure-test with a couple of cold readers; worth a fallback framing if "is this a wine app?" shows up.

---

## 13. ChatGPT visual-prototyping round (2026-06-30)

A prototype pack (3 mockups + design notes) came back from a ChatGPT visual-prototyping pass. The **notes** are committed at `vineyard-prototype-pack/notes/` (alongside this spec); the three **PNG mockups** are kept locally but **gitignored** (large AI renders — `vineyard-prototype-pack/prototypes/`, also in `~/Downloads/parleq-vineyard-prototype-pack/`). It converges strongly with §12 and contributed one material improvement plus one accuracy catch.

**Folded in:**
- **Split-stage explorer replaces the modal default** (§6) — persistent cluster on the left, in-place demo panel on the right, selected grape stays visible and connected by flow lines, "jump to another grape" chips. Modeled on `DocTabs` (WAI-ARIA tabs), so **no focus-trapping dialog on desktop** — this resolves the §12 / adversarial "modal is the highest build risk" finding. Modal is now optional (mobile / oversized demos only).
- **Mobile pattern** (§6.2): decorative bunch + Cleanup/Refine tabs + vertical grape buttons + inline expand.
- **Per-grape status chip is the privacy mechanism** (§6.3, §10): on-device grapes show "On-device"; refine/provider grapes do not. **No section-wide blanket "100% on-device / nothing leaves your Mac" band** — the prototype images (B, C) commit exactly this forbidden claim; do not copy it.
- **Grape visual style hardened** (guardrail #1): flat circular UI buttons, not photoreal 3-D fruit/leaves/tendrils (prototypes B/C over-render — borrow composition, not texture).
- **Privacy-section direction** (§4, section 3): candidate headline "Your Mac is the vineyard."; Prototype C as the atmospheric reference.
- Confirmed alignment on: hero stays product-first (metaphor begins below it), Concord attribution-only, voiceprints = sound-alike disambiguation, "Your voice never leaves your Mac" prominent.

**Synthesis the pack recommends:** Prototype **B** structure + Prototype **A** restraint + Prototype **C** boundary cue. Treat the images as composition/mood references only — **do not reproduce generated text or icons literally** (several contain the forbidden privacy claims and invented feature labels).

**Two decisions — resolved by the maintainer (2026-06-30):**
1. **H1 stays "Speak freely. Paste clean."** — declined "Speak messy"; keep the locked, more elegant headline.
2. **Keep the §5 locked Refine roster** (AI you bring · talk it into shape · presets · reference windows); preset styles are shown as example chips *inside* the presets grape, not as separate grapes.

**General rule (maintainer):** the ChatGPT prototype **text is non-authoritative** — that session was visual-only. All user-facing copy comes from the copy deck + the team's product knowledge, never the mockups; the images are composition/mood references only.

---

*End of design. Implementation proceeds via the writing-plans skill after spec review.*
