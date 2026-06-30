# Homepage redesign — the vineyard, the vine, the clusters, the grapes

**Status:** Design (locked direction, pending spec review)
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
2. Solve density by **delegating depth** (to inner pages) and by **making depth opt-in** (explorable on click), not by shaving every section.
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
| Families | **Clusters** | Capability families: Cleanup (Concord) · Refine · Built for teams. |
| Capabilities | **Grapes** | Individual features, explorable on click. |

### 2.1 The vineyard turns our hardest constraint into an asset

We are forbidden from saying "nothing leaves your Mac" because cleanup *can* cross to a cloud the user brings. The vineyard **encodes the real model as imagery** instead of fighting it:

- **The vineyard is your Mac.** *Your voice never leaves the vineyard.* (Audio is always local — fully true, and the required string.)
- The only thing that ever crosses the fence is **cleaned-up text**, and only through a **gate you chose**:
  - pick **on-device cleanup** → *no gate is crossed at all*;
  - pick **a cloud you bring** → *a gate you own and already audited*.
- **The gatekeepers are the enterprise story.** Federated SSO is literally who-gets-checked-at-the-gate. So the vineyard **unifies privacy and enterprise** under one idea: *what crosses the fence, and who controls the gate.*

### 2.2 The positioning wedge (no competitor named)

"A cluster of great ideas that work together — more powerful than the single-trick alternatives." The cluster **is** the claim, and it makes the comparison *implicitly and visually* (other tools are one grape; Parleq is the bunch). This answers "why switch?" without a feature-vs-feature table and **without naming any competitor** (per the private-vision and no-competitor-reference constraints). The "more powerful together" idea lands at two levels: grapes within a cluster, and clusters across the vine.

### 2.3 Concord stays correctly scoped, for free

Concord (by Keavi) is **one cluster on the vine** — the on-device deterministic cleanup correctors — credited there and nowhere else. The nesting prevents the attribution from smearing across the whole app. When a visitor opens the **on-device cleanup** grape, its demo reveals *its own* inner Concord sub-cluster; that is the only place "built on Concord (by Keavi)" appears.

---

## 3. Restraint guardrails (HARD rules for implementation)

The metaphor is powerful precisely because we hold it back. These are non-negotiable and become review checkpoints:

1. **No literal farm.** No cartoon gatekeepers, no leaves/tendrils/sun/rolling-hills illustration. The vineyard lives in **language + restrained visual containment** (a fence line, a framed boundary, the existing dark-grape ground) — never an illustrated scene.
2. **The metaphor is a lens, not a renaming.** Real feature labels stay literal: "Per-app cleanup," not "the targeting grape." Headlines may lean poetic; **UI controls, feature names, and nav stay plain.**
3. **Curate, don't enumerate.** Show abundance and let people explore; never render every grape inline.
4. **Two flagship interactive clusters only** (Cleanup + Refine). Enterprise teases and links out.
5. **Privacy is a posture, expressed once as the vineyard** — not a clickable cluster, not repeated in every section.
6. **All existing locked conventions are preserved** (see §8): two-tier hero, FloatingNav, grape footer, card-on-purple transition, GrapeCluster/ConcordFlow/OverlayMockup components, DocTabs, tokens, accessibility/reduced-motion/no-JS discipline.

---

## 4. Homepage skeleton (target)

A bold "trailer": short scroll, deep on click, one world holding it together. Sections, top to bottom:

1. **Hero — "Speak freely. Paste clean."**
   - Keep the live transform demo (the crown jewel) and the FloatingNav-over-grape treatment.
   - **Sharpen the subhead** to lead with the wedge, not the category. It must still contain the required string "Your voice never leaves your Mac" (in the privacy pill, as today). Lead with the differentiator (talk-it-into-shape + your-words-right) and the vineyard boundary; keep "/PAR-lek/" and the macOS/Apple-Silicon facts.
   - CTAs unchanged (Download / See it in action). Feature chips may be retuned to name the clusters.

2. **The vine — interactive clusters (the heart).**
   - A short framing line establishes the wedge: *Parleq isn't one trick; it's a cluster of small, sharp ideas that compound.*
   - **Cluster 1 — Cleanup (built on Concord):** the on-device deterministic correctors. Reuses today's `GrapeCluster`. Opening a grape reveals the Concord sub-cluster + a before→after demo.
   - **Cluster 2 — Refine & shape it:** cleanup with the AI you bring · talk it into shape (the refine loop) · one-tap presets · **per-app cleanup** · reference windows.
   - Each grape is an accessible control that opens a **demo overlay** (see §6) with back/next/close and "next grape."
   - This single section replaces today's separate on-device showcase **and** the 5-slide carousel **and** the 12-card grid — their content is redistributed into grapes (curated, not exhaustive), so depth becomes opt-in.

3. **The vineyard — private by design.**
   - One confident moment: the fence + the gates. *Your voice never leaves the vineyard. The only thing that crosses the fence is cleaned-up text — through a gate you choose: nothing leaves at all on-device, or a cloud you already own and audited.*
   - Restrained visual containment only (no farm scene). Links out to how-it-works / security review for depth.

4. **The gate for teams — enterprise.**
   - Keep the dark-grape enterprise band (already tight), reframed lightly as "who controls the gate": one sign-in, per-user audit, no Parleq servers in the path, security-review packet. Links to `/enterprise`, SSO setup, managed configuration, security review. **Enterprise is a teaser cluster — it links out, it is not interactively explorable here.**

5. **Get Parleq.**
   - Preserve the tester-readable 5-step install walkthrough verbatim-in-spirit (download → drag → permissions-in-context → pick a provider incl. on-device → hotkey). Keep the final CTA + "View source" + license line + the reserved (empty) social-proof slot.

**Net change vs. today:** the on-device deep-dive prose, the standalone refine carousel, and the flat 12-card grid collapse into the single interactive vine section. The hero, enterprise band, and install section stay (sharpened). Page gets materially shorter while gaining depth-on-demand.

---

## 5. Capability curation (which grapes, which cluster)

Curated, not exhaustive. Enterprise-only capabilities leave the consumer clusters and live in the enterprise teaser / `/enterprise`.

**Cluster 1 — Cleanup (Concord).** Grapes: Punctuation & casing · Numbers & percents · Your words (custom dictionary) · Sound-alikes (voiceprints). *(Phonetic and compound are supporting members shown inside the Concord sub-cluster, not top-level grapes.)*

**Cluster 2 — Refine & shape it.** Grapes: Cleanup with the AI you bring (providers + on-device LLM) · Talk it into shape (the refine loop) · One-tap presets · Reference windows · **Per-app cleanup** — *gated: include only if runtime-complete at merge (§7); otherwise omit or ship future-tense.*

**Moved OUT of the homepage clusters → enterprise teaser / `/enterprise`:** MDM / managed configuration; compliance-by-default posture (folds into the vineyard moment); per-user audit; federated SSO.

**Posture, not a grape (woven into the vineyard moment):** audio-never-leaves, no-backend, keys-in-Keychain, never-lose-a-dictation.

> Open item for the plan: a final pass to confirm the grape list against the live capability set, including any new capabilities the `per-target-cleanup` branch adds. Aim for ~4 grapes per flagship cluster — enough to feel abundant, few enough to stay curated.

---

## 6. The grape-overlay demo mechanic

The captivating centerpiece: clicking a grape animates open an in-page overlay that **demonstrates** that capability, with controls to step through it, close, or advance to the next grape.

### 6.1 UX
- **Trigger:** each grape is a real, focusable button (`<button>`), labeled with the capability name (accessible name is the plain feature label, not metaphor copy).
- **Open:** animates from the grape into a centered overlay/dialog (modal `role="dialog"`, `aria-modal="true"`, labelled by the capability title). Animation respects `prefers-reduced-motion` (instant show under reduced motion).
- **Content:** a short, stepped demo — typically a **before→after** and/or a reuse of `OverlayMockup` / `TransformCard` / the on-device before→after strip pattern (see §8). 1–4 steps.
- **Controls:** Back / Next within the demo; Close; and "next grape" to roll on to the following capability without closing.
- **Close:** Esc, backdrop click, and an explicit close button. Focus is trapped while open and **restored to the originating grape** on close.

### 6.2 Accessibility & resilience (locked-system discipline)
- **No-JS fallback:** every grape's demo content renders in the DOM (e.g. as a `<details>`/disclosure or a statically-visible panel) so the page is fully usable without JS; the script enhances it into the animated modal. (Mirrors the DocTabs no-JS approach.)
- **Reduced motion:** no animated open/typing; content appears instantly; any auto-advance is disabled.
- **Keyboard:** Tab order sane; arrow/Enter/Esc behave conventionally; focus trap + restore.
- **Screen readers:** dialog labelled by the capability title; a polite live region announces step changes.
- **Mobile:** the cluster and overlays must degrade gracefully on small screens (the current hero flow art is hidden below `md`; the cluster must NOT inherit that — it is the primary content here and must work on mobile, even if the grape layout simplifies to a stacked/scrollable arrangement).

### 6.3 What a "demo" is (per grape, examples — finalize in the plan)
- *Punctuation & casing:* `"did the build pass and is it ready to ship"` → `Did the build pass and is it ready to ship?`
- *Numbers & percents:* `eight point nine million` → `8.9 million`; `forty five percent` → `45%`
- *Your words:* `parlay` → `Parleq` (dictionary biasing)
- *Sound-alikes:* `kiwi` → `Keavi` (voiceprint disambiguation; "what's kept is an encrypted voiceprint, never a recording")
- *Talk it into shape:* an `OverlayMockup` with a refine instruction and the reshaped result (reuse a carousel scenario).
- *Per-app cleanup:* show the same dictation landing differently by app — Instant in a terminal, Polished in Mail/Slack (see §7 for accurate framing).
- *Reference windows:* `OverlayMockup` with an attachment pill + the PNG-in-memory privacy note.

---

## 7. Per-app cleanup — accurate copy guidance

> ⚠️ **GATE: per-app cleanup is NOT shipped yet.** In the `per-target-cleanup` worktree it exists only as the config model + curated map + resolver + tests — `TargetMode` / `AppBehavior` / `behaviorForApp` / `CuratedAppDefaults` have **zero runtime callers** and are not consulted by live dictation routing. **Do not market it present-tense until it is runtime-complete and merged.** Until then, treat the per-app grape as **deferred**: either omit it from the launch cluster, or ship it explicitly future-tense ("coming"). This is the same Beat-4 gate as before, moved — the site must not claim a feature the app doesn't perform.

When the feature *is* runtime-complete and merged, copy must match it exactly.

**The cleanup modes (`TargetMode`, three values):**
- **Instant** — forced **on-device Concord** deterministic correction: in-process, ~0 ms, **no LLM, no network, no model download.** (This tier itself shipped in 0.27.0 as the "Lightweight (on-device)" cleanup provider.)
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

- **Required strings** (homepage built HTML): "Your voice never leaves your Mac"; "built on Concord".
- **Forbidden strings:** "Nothing leaves your Mac" / "...your device"; "100% on-device"; "On-device Concord"; "Everything runs on your Mac"; voiceprints described as learning / rhythm / filler / hesitations / "sounds like you".
- **Concord** = attribution only, never a wordmark/product/logo.
- **voiceprints** = lowercase; they **disambiguate sound-alike words**; they do **not** learn speaking style.
- **Routing/destination vision stays private.** Per-app content = "Parleq applies the cleanup you set per app," never destination routing.
- **Entity = Keavi LLC.**
- Run `node scripts/verify-page.mjs` (accuracy + a11y) after every copy change; contrast via `node scripts/contrast.mjs`.

---

## 10. Verification

- `npm run build` clean.
- `node scripts/verify-page.mjs` green (required/forbidden strings, a11y assertions).
- Manual: keyboard-only walkthrough of the cluster (open/step/close/next-grape, focus trap + restore); reduced-motion check; no-JS check (grape demos still reachable); mobile layout of the cluster.
- RoboRev auto-review on each commit; work through findings before the approval gate.
- **Release gate (per-app cleanup, §7):** per-app cleanup is currently config-model-only (not runtime-wired). If the homepage ships a present-tense per-app grape, the site **must** ship together with a runtime-complete, merged `per-target-cleanup` feature. If the feature isn't runtime-complete at release, the per-app grape is **omitted or shipped future-tense**. Also still respects the Posit promotion-timing hold.

---

## 11. Open questions for the plan

1. **Vine layout:** how the two flagship clusters are arranged on the page (side-by-side vs. stacked), and how grapes lay out within a cluster at each breakpoint.
2. **How literal the vineyard visual gets** — settle the "restrained containment" treatment (fence line? framed boundary? gate motif?) within guardrail #1.
3. **Demo depth per grape** — 1 step (before→after) vs. multi-step; which grapes justify multi-step.
4. **Hero subhead final wording** — sharpen to the wedge while keeping required string + pronunciation + platform facts.
5. **Final grape roster** — confirm ~4 per cluster against the live + per-target-cleanup capability set.
6. **Does the existing hero live-demo stay as-is**, or get re-pointed to foreshadow the vine?

---

*End of design. Implementation proceeds via the writing-plans skill after spec review.*
