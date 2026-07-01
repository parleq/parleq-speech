# Homepage Vineyard Promotion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the settled "grape explorer" from the throwaway prototype into the real homepage (`web/src/pages/index.astro`), and land the full vineyard homepage skeleton — accessible, mobile-ready, accuracy-clean — holding at the approval gate.

**Architecture:** Extract the explorer into a reusable Astro component (`GrapeExplorer.astro`) with proper WAI-ARIA semantics + no-JS fallback + reduced-motion; wire it as the "vine" section of `index.astro`, replacing today's on-device deep-dive + 5-slide carousel + 12-card grid; keep the rest of the §4 skeleton (hero, vineyard/privacy, for-teams, get-Parleq) within the locked design system.

**Tech Stack:** Astro 5, Tailwind, inline `is:inline` scripts, SVG. No test framework for the site — **"verification" for every task = `npm run build` clean + `node scripts/verify-page.mjs` green + a headless screenshot review + keyboard/no-JS/reduced-motion spot-checks.**

**Source of truth:** the design spec `docs/superpowers/specs/2026-06-30-homepage-vineyard-redesign-design.md` (esp. §4 skeleton, §5 roster, §7 per-app gate, §9 accuracy, §14 settled design + tracked inventory). The prototype `web/src/pages/prototype.astro` is the visual reference to port from — **its copy strings are placeholders; real copy comes from `docs/superpowers/specs/copy-deck.md` + product knowledge.**

## Global Constraints

- **Accuracy — required strings in built homepage HTML (static DOM, not JS-only):** `Your voice never leaves your Mac`; `built on Concord` (write in full as `built on Concord (by Keavi)`).
- **Accuracy — forbidden strings:** `Nothing leaves your Mac` / `...your device`; `100% on-device`; `On-device Concord`; `Everything runs on your Mac`; voiceprints described as learning/rhythm/filler/hesitations/"sounds like you". **No section-wide blanket privacy claim under the mixed explorer** — privacy is scoped **per grape** via the status chip (`On-device` vs `Your provider`).
- **Concord** = attribution only, never a wordmark/product/cluster name.
- **voiceprints** disambiguate sound-alike words; do NOT claim absolute "never a recording" (enrollment-audio store exists).
- **Routing/destination vision stays private** — per-app content = "the cleanup you set per app," never destination routing.
- **Per-app cleanup is config-model-only / not runtime-wired (§7)** — include the per-app grape present-tense ONLY if runtime-complete at worktree merge; else omit or ship future-tense.
- **Photoreal grapes** are the chosen look (§14.1) — no foliage/stems/scenery/wine.
- **Locked design system:** `FloatingNav`, grape footer, card-on-purple transition, two-tier hero, tokens in `global.css`, Fraunces + Inter. Reuse `DocTabs` a11y pattern, `OverlayMockup`, `ConcordFlow`.
- **Entity = Keavi LLC.** Commit style per repo. **Do NOT push / open a PR until the maintainer approves.**
- **Gotcha:** never a JS template literal inside `<code>` in a table cell (use entity-escaped braces).

---

## Phase 0 — Decisions to resolve before/at integration (unblock the copy)

These gate the copy but not the component build. Capture answers, then proceed.

### Task 0: Confirm blocking decisions with the maintainer

- [ ] **Per-app grape (§7):** is `per-target-cleanup` runtime-complete at merge? → include the per-app grape (present-tense) or omit/future-tense. Default: **omit** until confirmed.
- [ ] **Hero subhead** final wording (§11): sharpen to the wedge, keep the prominent literal "Your voice never leaves your Mac" + `/PAR-lek/` + macOS/Apple-Silicon facts.
- [ ] **Final grape roster** (§5): Cleanup = Punctuation & casing · Numbers & percents · Your words · Sound-alikes (+ Compound as a real on-device corrector if kept); Refine = AI you bring · Talk it into shape · Presets · Reference windows. Confirm labels (**"Your words," not "Jargon"**).
- [ ] **Three flagged calls (§12):** (1) fix "never a recording" in live copy; (2) fold white-on-amber CTA contrast fix into this round? (`--color-accent` → `--color-accent-hover #b45309` on Download buttons = 5.02:1); (3) wine-connotation cold-read.
- [ ] **What's dropped from the homepage entirely** (§11) — name the current grid/carousel capabilities that will live only on how-it-works, so nothing is silently lost.

---

## Phase 1 — Extract the explorer into a component

### Task 1: Create `GrapeExplorer.astro` from the prototype (structure + data)

**Files:**
- Create: `web/src/components/GrapeExplorer.astro`
- Reference: `web/src/pages/prototype.astro` (visual source), `web/src/components/DocTabs.astro` (a11y pattern), `web/src/components/OverlayMockup.astro` (demo card)

**Interfaces:**
- Produces: `<GrapeExplorer />` — self-contained; reads its capability data from a local const array `{ id, group, icon, title, label, chip: 'on'|'byo', before, after, desc, pasting, instruction?, presets?, attachment? }`.

- [ ] **Step 1:** Copy the settled markup/CSS from `prototype.astro` into `GrapeExplorer.astro`: the editorial group tabs, the single 9-orb bunch (`POS` array, photoreal `.grape-orb`, `data-tone` center/shadow), the embossed icon (`emboss()`) + engraved `.g-lb`, the demo cards, the Codex flow-lines SVG + CSS.
- [ ] **Step 2:** Replace prototype placeholder copy with copy-deck strings; fix the "Jargon" label to "Your words"; apply the roster confirmed in Task 0; **omit the per-app grape unless Task 0 says otherwise.**
- [ ] **Step 3:** Keep the single-glowing-focal behavior (only `[data-selected]` glows; default-select the `data-tone="center"` grape) and the per-grape `On-device`/`Your provider` chip.
- [ ] **Step 4 (verify):** `npm run build` clean; screenshot `GrapeExplorer` on a scratch page; confirm one glowing focal, chips correct, no blanket claim string present.
- [ ] **Step 5:** Commit `feat(web): extract GrapeExplorer component from prototype`.

### Task 2: Make the explorer accessible (WAI-ARIA + keyboard + no-JS + reduced-motion)

**Files:** Modify `web/src/components/GrapeExplorer.astro`

- [ ] **Step 1:** Group tabs = `role="tablist"` with `role="tab"`, `aria-selected`, arrow-key nav (model on `DocTabs`). Grapes = focusable controls with accessible names (the plain title); selected state exposed via `aria-current`/`aria-pressed`.
- [ ] **Step 2:** No-JS fallback — ensure the active family's grape labels + one demo render without JS (server-render the default family + demo; script enhances). Decorative flow-lines `aria-hidden`.
- [ ] **Step 3:** Gate the flow-line pulse + grape transitions behind `@media (prefers-reduced-motion: reduce)`.
- [ ] **Step 4 (verify):** keyboard-only walkthrough (tab to a grape, arrow between families, Enter selects, demo swaps); disable JS → content still present + readable; reduce-motion → no pulse. Build clean.
- [ ] **Step 5:** Commit `feat(web): a11y + no-JS + reduced-motion for GrapeExplorer`.

### Task 3: Mobile treatment

**Files:** Modify `web/src/components/GrapeExplorer.astro`

- [ ] **Step 1:** Below `md`: family tabs + a vertical list / inline-accordion of the active family's grapes (each expands to its demo); hide/simplify the flow lines; the bunch may become a small decorative header.
- [ ] **Step 2 (verify):** headless screenshot at 390px width; keyboard + tap flow works; build clean.
- [ ] **Step 3:** Commit `feat(web): responsive mobile treatment for GrapeExplorer`.

---

## Phase 2 — Integrate into the homepage

### Task 4: Wire `GrapeExplorer` as the "vine" section, retiring the old sections

**Files:** Modify `web/src/pages/index.astro`

- [ ] **Step 1:** Remove the on-device deep-dive, the 5-slide refine carousel, and the 12-card capability grid. Insert `<GrapeExplorer />` as the vine section, inside the card-on-purple frame (first white section overlapping the grape hero) per §8.
- [ ] **Step 2:** Add the short "vine" framing line carrying the wedge in text ("a bunch beats one grape").
- [ ] **Step 3 (verify):** build clean; `verify-page.mjs` green (required strings still present in static hero DOM; no forbidden strings); screenshot the homepage top-to-vine.
- [ ] **Step 4:** Commit `feat(web): replace grid+carousel with the vine explorer on the homepage`.

### Task 5: Hero subhead + vineyard (privacy) + for-teams + get-Parleq sections

**Files:** Modify `web/src/pages/index.astro`

- [ ] **Step 1:** Sharpen the hero subhead (Task 0 wording); keep the prominent literal privacy line.
- [ ] **Step 2:** The vineyard/privacy section (§4.3) — fence-owns-what-crosses copy, accurate egress (audio never crosses; text crosses for cloud cleanup; reference snapshots only when attached); restrained containment, no farm scene. Candidate headline "Your Mac is the vineyard."
- [ ] **Step 3:** For-teams band (gatekeeper) links to `/enterprise`; Get-Parleq install steps preserved.
- [ ] **Step 4 (verify):** build + `verify-page.mjs` green; full-page screenshot; confirm "shorter" (≤ 6 scroll sections) and no section-wide privacy claim under the explorer.
- [ ] **Step 5:** Commit `feat(web): vineyard privacy + teams + install sections`.

---

## Phase 3 — Accuracy, sweep, SEO

### Task 6: Accuracy pass + extend the verify gate

**Files:** Modify `web/scripts/verify-page.mjs`; audit `index.astro` + `GrapeExplorer.astro`

- [ ] **Step 1:** Confirm per-grape chips (`On-device` for on-device grapes, `Your provider` for refine); no blanket claim anywhere in the explorer.
- [ ] **Step 2:** Extend `verify-page.mjs` to assert the required/forbidden strings on the inner pages too (not just the homepage).
- [ ] **Step 3 (verify):** `verify-page.mjs` green across pages; grep built HTML for forbidden strings = 0.
- [ ] **Step 4:** Commit `chore(web): extend accuracy-string gate beyond the homepage`.

### Task 7: (Rec C) cross-page consistency & terminology sweep

**Files:** audit `web/src/pages/**`

- [ ] **Step 1:** Unify terminology (cleanup/refine/on-device/voiceprints) across inner pages; fix drift; align with the new homepage framing.
- [ ] **Step 2 (verify):** build + `verify-page.mjs` green; skim each inner page.
- [ ] **Step 3:** Commit `docs(web): cross-page terminology + accuracy sweep`.

### Task 8: (Rec D) per-page SEO meta/titles + social-proof slot

**Files:** `web/src/layouts/Layout.astro` + each page's frontmatter

- [ ] **Step 1:** Distinct, compelling meta description + title per page; keep the reserved (empty) social-proof slot ready.
- [ ] **Step 2 (verify):** build; inspect `<head>` per route.
- [ ] **Step 3:** Commit `feat(web): per-page SEO meta + titles`.

---

## Phase 4 — Close-out (HOLD at approval gate)

### Task 9: Pre-PR cleanup, review, and gate

- [ ] **Step 1:** Delete `web/src/pages/prototype.astro` and the `vineyard-prototype-pack` if no longer needed.
- [ ] **Step 2:** Lighthouse/perf + SEO continuity pass; fix regressions.
- [ ] **Step 3:** Adversarial + balanced subagent review (per the redesign process); address findings; RoboRev each commit.
- [ ] **Step 4:** Confirm the release gates: per-app grape state matches the shipped feature; plan to **merge with `per-target-cleanup`** before release; Posit promotion hold noted.
- [ ] **Step 5:** **STOP.** Stage everything on `web/redesign-concord`; do NOT push or open a PR. Summarize for the maintainer and wait for explicit approval.

---

## Self-review notes

- **Spec coverage:** §2 metaphor → Tasks 4/5; §4 skeleton → Tasks 4/5; §5 roster → Task 0/1; §6/§14 explorer → Tasks 1–3; §7 per-app gate → Task 0/1 + Global Constraints; §9 accuracy → Task 6 + Global Constraints; §11 open questions → Task 0; §12/§14.3 flagged calls → Task 0 + task #10; Rec C → Task 7; Rec D → Task 8; release gates → Task 9.
- **Adaptation:** this is visual/Astro work — "tests" are build + `verify-page.mjs` + screenshot + keyboard/no-JS/reduced-motion checks, not unit tests. That is intentional and matches the repo (no site test target).
- **Not silently dropped:** the maintainer decisions (Task 0 / task #10), the "what's dropped from the homepage" list, and the release gates are explicit tasks, not assumptions.
