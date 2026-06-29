# Parleq Homepage Redesign ("Concord Direction") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Parleq homepage as a "flow grammar" narrative — an input→engine→output card-and-flow-line motif re-staged across six beats — on a framed dark-grape/amber visual system, telling Parleq's real differentiators (refinement loop, configurable on-device/cloud split, per-app engine routing) without overclaiming.

**Architecture:** New reusable Astro components (`TransformCard`, `ConcordFlow`, `GrapeCluster`) compose each beat in a rebuilt `src/pages/index.astro`. A grape token ramp extends the existing `global.css`. Motion is built in tiers: a complete static baseline first (which is also the `prefers-reduced-motion` experience), then a single vanilla rAF choreography coordinator layers traveling pulses + event-driven glow on top. Accuracy and accessibility are enforced by a scriptable verification harness, not just eyeballs.

**Tech Stack:** Astro 5, Tailwind v4 (`@theme` tokens), vanilla JS (no React), Node verification scripts (`.mjs`). Deploy: GitHub Pages via existing `.github/workflows/deploy-pages.yml`. No formal test target — verification is `npm run build` + the harness in Task 2 + maintainer visual judgment.

**Spec:** `web/docs/superpowers/specs/2026-06-29-website-redesign-concord-direction-design.md` (read it before starting).

## Global Constraints

Every task implicitly includes these (verbatim from the spec §3 + §9):

- **No blanket "Nothing leaves your Mac."** Audio line (always true): **"Your voice never leaves your Mac."** Cleanup line: **"on-device, or the cloud you bring — your call."** Never claim cleanup is universally local.
- **"On-device cleanup" is the protagonist; "Concord" is attribution, never a wordmark.** Engine node labeled by function + a small **"built on Concord (by Keavi)"** credit. The grape cluster depicts only Concord's deterministic tier — never Gemma (neural), never "the engine" generically.
- **voiceprints:** lowercase, never camelCase/™/badge. They **disambiguate sound-alike words** — they do NOT learn filler/rhythm/speaking style.
- **Keep the routing vision private:** per-app beat is **independent per-app rows**, never one voice fanning out to many destinations. Parleq selects the *cleanup*, not the destination.
- **RELEASE GATE:** beat 4 markets per-app cleanup-engine selection in present tense; **do not deploy until that parallel app feature ships.** Build/prototype in a worktree now; hold the PR at the approval gate (stacked on the Posit promotion hold).
- **Preserve:** JSON-LD `SoftwareApplication` schema, the semantic text `<h1>`, GoatCounter `data-goatcounter-click` hooks (`download-hero`, `download-get-parleq`), the tester-readable install walkthrough, and the 12-capability long tail + its `how-it-works` deep links.
- **Reduced-motion is first-class:** all content fully renders with zero motion; every animation gated behind `prefers-reduced-motion: no-preference`.
- **Entity:** Keavi LLC (existing footer is correct — don't touch it).
- **Visual judgment is the maintainer's** (per the project's walkthrough-verification split): the agent runs all machine-checkable verification (build + harness + contrast script); the maintainer signs off on look/feel at the checkpoints marked **🧑‍⚖️ MAINTAINER CHECKPOINT**.

**Out of scope for v1:** Tier 3 north-star (per-correction grape lighting) — gated fast-follow; other site pages; pricing/sales copy; the voice-routing vision.

**Process note:** Work in a git worktree under `../parleq-worktrees/` (create via `superpowers:using-git-worktrees` at execution start). Commit per task. After the build is complete, run the adversarial + balanced subagent review and RoboRev before the approval gate.

---

### Task 0: Prototype Spike (inline — visual gut-check before the full build)

Front-loads the three highest-risk visual bets so we don't build 12 tasks on a wrong foundation. **Done inline (tight maintainer loop), NOT subagent-driven.** Throwaway page; good code folds into Tasks 3/6/7/14, the rest is discarded.

**Files:**
- Create (temporary): `web/src/pages/prototype.astro` (scratch; deleted or gitignored before the PR)
- May touch (kept): `web/src/styles/global.css` (grape ramp — the Task 3 work, pulled forward if it helps the spike)

**Goal — get a 🧑‍⚖️ maintainer verdict on:**
1. **Dark grape hero panel** — premium Mac-native vs. generic dark-mode SaaS (the make-or-break call, spec §9).
2. **Grape cluster** — elegant/geometric vs. cute/childish.
3. **One beat's Tier-1 motion** — calm "heartbeat" vs. busy "screensaver" (build the minimal pulse+event-glow primitive on one flow; the only fidelity that can answer this is real motion in a browser).

- [ ] **Step 1:** Create the worktree (via `superpowers:using-git-worktrees`) under `../parleq-worktrees/`, branch e.g. `web/redesign-concord`.
- [ ] **Step 2:** Add the grape ramp to `global.css` (Task 3 Step 1) so the spike uses real tokens.
- [ ] **Step 3:** Build `prototype.astro`: a framed dark-grape hero panel with the three TransformCards + static ConcordFlow; the GrapeCluster; and a minimal Tier-1 pulse+event-glow on the hero's forward flow (reduced-motion-gated). Rough is fine — this is for *feel*, not finish.
- [ ] **Step 4:** `cd web && npm run dev` and have the maintainer open it. 🧑‍⚖️ MAINTAINER CHECKPOINT on all three bets. Iterate live until the direction is blessed — or redirected (which updates the spec/plan before the full build).
- [ ] **Step 5:** Decision gate: on **bless** → proceed to subagent-driven execution of Tasks 1→17, folding the spike's good code into Tasks 3/6/7/14 and deleting `prototype.astro`. On **redirect** → revise spec/plan, re-spike. Do not commit `prototype.astro` to the final PR.

---

### Task 1: Scrubbed copy deck (authoritative strings)

The codex pack's copy is forbidden as a build input. This deck is the single source of truth for every user-facing string; later tasks copy from here, never from the pack.

**Files:**
- Create: `web/docs/superpowers/specs/copy-deck.md`

- [ ] **Step 1: Write the copy deck** with these sections. Fill each beat's final strings; the FORBIDDEN list is load-bearing (Task 2 greps for it).

```markdown
# Parleq Homepage Copy Deck (authoritative)

## FORBIDDEN strings (must never appear in built HTML — Task 2 asserts absence)
- "Nothing leaves your Mac"        (blanket; cleanup can be cloud)
- "Nothing leaves your device"
- "100% on-device"                 (blanket)
- "On-device Concord"              (wordmark)
- "Everything runs on your Mac"
- voiceprints "learn"/"rhythm"/"filler"/"hesitations"/"sounds like you"

## REQUIRED strings (Task 2 asserts presence)
- "Your voice never leaves your Mac"      (audio privacy line)
- "built on Concord"                       (attribution credit)

## Beat 1 — Hero
- Eyebrow/privacy pill: "Your voice never leaves your Mac"
- H1: "Speak freely." / "Paste clean."
- Subhead: "Parleq /PAR-lek/ is a local-first AI dictation app for macOS. Hold a hotkey and talk; the cleaned-up result pastes into whatever app was focused — speech recognition and cleanup can both run on your Mac, or use the cloud you bring."
- Primary CTA: "Download for macOS"   Secondary: "See it in action"
- Transform cards: input = raw dictation w/ a real before example; engine = "On-device cleanup"; output = cleaned text. Use a real payload, e.g. input "we cut latency by forty five percent last quarter" → output "We cut latency by 45% last quarter."

## Beat 2 — Refinement loop
- Heading: "Not quite right? Just say so."
- Body: "Most dictation apps stop at paste. Parleq lets you refine by voice — 'make it more concise,' 'more formal,' a numbered preset — without touching the keyboard."
- (Uses the existing OverlayMockup with its real before / refine-instruction / after text.)

## Beat 3 — On-device + cloud, configurable split
- Heading: "Instant on your Mac. Powerful in your cloud. Your call."
- Body: "Keep first-pass cleanup on the on-device tier, and send refinement to the cloud provider you bring — Gemini, Bedrock, Vertex, or Azure. You decide the split."
- Engine credit: "built on Concord (by Keavi)"
- Cluster node labels: Voiceprints · Punctuation · Numbers · Dictionary · Compound

## Beat 4 — Per-app engine defaults  (PRESENT TENSE — release-gated, see plan)
- Heading: "The right cleanup for every app."
- Body: "Set which cleanup each app uses — cloud-grade for Slack and email, instant on-device for a terminal chat. Parleq remembers, per app."
- Rows: Slack → Cloud · polished ; Mail → Cloud · polished ; Terminal → On-device · instant ; Notes → On-device · instant

## Beat 5 — Accuracy band + capability index
- Heading: "Names, numbers, the works."
- Cards (each led by a real before→after):
  - voiceprints: "parlay → Parleq" ; "kiwi → Keavi"  — copy: "Tell sound-alike names apart by voice. On-device, opt-in per term; what's kept is an encrypted voiceprint, never a recording."
  - custom dictionary: "Q2RFC → Q2 RFC" — copy: "Teach Parleq your names, acronyms, and jargon so it gets them right."
  - numbers & punctuation: "eight point nine million → 8.9 million" ; "forty five percent → 45%" — copy: "Spoken numbers become digits; punctuation and casing land where they belong."
  - private by design: copy: "Your voice never leaves your Mac. Cleanup runs on-device, or on the cloud account you bring — your choice, per provider."

## Beat 6 — Enterprise/trust strip
- Heading: "Built for teams who need control."
- Columns: SSO & directory ; Bring your cloud ; No API keys on devices ; Auditable by design

## Beat 7 — Get Parleq
- Preserve the existing tester-readable install walkthrough verbatim (download → drag → permissions-in-context → provider pick → hotkey).
- Reserved (empty) social-proof slot for post-Posit.
```

- [ ] **Step 2: Commit**

```bash
git add web/docs/superpowers/specs/copy-deck.md
git commit -m "docs(web): scrubbed copy deck for homepage redesign"
```

---

### Task 2: Accuracy + accessibility verification harness

The repeatable gate. Builds the site and asserts the accuracy/a11y contract. This is the "test" every later task runs.

**Files:**
- Create: `web/scripts/verify-page.mjs`
- Create: `web/scripts/contrast.mjs`

**Produces:** `node scripts/verify-page.mjs` (run from `web/`) — exits non-zero on any violation. `node scripts/contrast.mjs '#fg' '#bg'` — prints WCAG ratio.

- [ ] **Step 1: Write `contrast.mjs`** (WCAG 2.1 relative-luminance ratio)

```js
// Usage: node scripts/contrast.mjs '#d97706' '#311551'
const hex = (h) => { const n = h.replace('#',''); return [0,2,4].map(i=>parseInt(n.slice(i,i+2),16)/255); };
const lin = (c) => c <= 0.03928 ? c/12.92 : ((c+0.055)/1.055)**2.4;
const L = (rgb) => { const [r,g,b]=rgb.map(lin); return 0.2126*r+0.7152*g+0.0722*b; };
const ratio = (a,b)=>{ const la=L(hex(a)), lb=L(hex(b)); const [hi,lo]=[Math.max(la,lb),Math.min(la,lb)]; return (hi+0.05)/(lo+0.05); };
const [fg,bg] = process.argv.slice(2);
if(!fg||!bg){ console.error('usage: contrast.mjs <fg> <bg>'); process.exit(2); }
console.log(ratio(fg,bg).toFixed(2));
```

- [ ] **Step 2: Write `verify-page.mjs`** (reads built `dist/index.html`)

```js
import { readFileSync } from 'node:fs';
const html = readFileSync(new URL('../dist/index.html', import.meta.url), 'utf8');
const FORBIDDEN = [
  'Nothing leaves your Mac', 'Nothing leaves your device', '100% on-device',
  'On-device Concord', 'Everything runs on your Mac',
];
const REQUIRED = [
  'Your voice never leaves your Mac',          // audio privacy line
  'built on Concord',                          // attribution credit
  'application/ld+json',                       // JSON-LD preserved
  'data-goatcounter-click="download-hero"',    // hero CTA hook
  'data-goatcounter-click="download-get-parleq"', // final CTA hook
  '<h1',                                        // semantic headline present
];
let fail = 0;
for (const s of FORBIDDEN) if (html.includes(s)) { console.error(`FORBIDDEN present: "${s}"`); fail++; }
for (const s of REQUIRED) if (!html.includes(s)) { console.error(`REQUIRED missing: "${s}"`); fail++; }
// Decorative flow/cluster SVGs must be aria-hidden: every <svg class="...flow|cluster..."> carries aria-hidden.
const decorative = [...html.matchAll(/<svg[^>]*class="[^"]*(?:concord-flow|grape-cluster)[^"]*"[^>]*>/g)];
for (const m of decorative) if (!/aria-hidden="true"/.test(m[0])) { console.error(`Decorative SVG missing aria-hidden: ${m[0].slice(0,80)}`); fail++; }
console.log(fail ? `\n${fail} violation(s)` : 'verify-page: OK');
process.exit(fail ? 1 : 0);
```

- [ ] **Step 3: Verify the harness runs against the current site** (forbidden absent, required present already? The current hero has `Your voice never leaves your Mac` + JSON-LD + `download-hero`, but NOT `built on Concord` or `download-get-parleq` yet — those are added by later tasks). Run:

```bash
cd web && npm run build && node scripts/verify-page.mjs || echo "expected: missing 'built on Concord' / 'download-get-parleq' until later tasks"
```

Expected: reports the two not-yet-added REQUIRED strings — confirms the harness works. (It goes green at Task 13.)

- [ ] **Step 4: Commit**

```bash
git add web/scripts/verify-page.mjs web/scripts/contrast.mjs
git commit -m "test(web): accuracy + a11y verification harness for redesign"
```

---

### Task 3: Grape token ramp + dark-panel tokens + contrast verification

**Files:**
- Modify: `web/src/styles/global.css` (extend `@theme` — do not remove existing tokens)

**Produces:** CSS vars `--color-grape-{950,900,800,700,600,500,400,300,200,100}`, `--color-panel-ink` (near-white on dark), plus flow gradient vars `--flow-voice` / `--flow-clean`. Consumed by every later component.

- [ ] **Step 1: Add the ramp** (starting hex; Step 2 verifies/adjusts for AA). `-500` equals the existing `--color-grape`.

```css
/* Concord grape ramp — derived from the existing --color-grape #5b2a86.
   Dark steps ground the framed hero panel + trust strip; light steps
   feed flow-line gradients, cluster nodes, and the lavender headline.
   Verified for WCAG AA at the pairings used (see scripts/contrast.mjs). */
--color-grape-950: #150720;
--color-grape-900: #23103a;
--color-grape-800: #311551;
--color-grape-700: #472075;
--color-grape-600: #552789;
--color-grape-500: #5b2a86;
--color-grape-400: #7d44b0;
--color-grape-300: #a87fce;
--color-grape-200: #cdb4e6;
--color-grape-100: #ebe0f6;
--color-panel-ink: #f6f1fb;   /* near-white body/headline on dark panel */
--flow-voice: var(--color-accent);     /* amber spark = voice energy */
--flow-clean: var(--color-grape-300);  /* lavender = cleanup/intelligence */
```

- [ ] **Step 2: Verify AA on the load-bearing pairings** and record results. Run each:

```bash
cd web
node scripts/contrast.mjs '#f6f1fb' '#23103a'   # body on panel — expect ≥ 7 (AAA)
node scripts/contrast.mjs '#a87fce' '#23103a'   # lavender headline (large) — expect ≥ 3
node scripts/contrast.mjs '#d97706' '#311551'   # amber small text on panel — EXPECT ~4.4 (FAILS AA 4.5)
```

Expected finding (matches spec §6): **amber as small body text on dark grape fails AA.** Rule that follows: amber on the dark panel is used **only** for large text, icons, and CTA *fill* (white text on amber fill — verify `#ffffff` on `#d97706` ≥ 4.5), never small purple-on-amber body text. Write the three ratios as a comment block above the ramp in `global.css`.

- [ ] **Step 3: Add a print stylesheet stub** (so dark panels don't print as ink blocks — completed in Task 12; stub now to reserve the location):

```css
@media print {
  /* Dark grape panels render light for print/share — filled in Task 12. */
  .panel-grape, .strip-grape { background: #fff !important; color: #111 !important; }
}
```

- [ ] **Step 4: Build + commit**

```bash
cd web && npm run build && git add src/styles/global.css && \
git commit -m "feat(web): grape token ramp + dark-panel tokens (AA-verified)"
```

---

### Task 4: `TransformCard.astro` — the card primitive

**Files:**
- Create: `web/src/components/TransformCard.astro`

**Interfaces — Produces:** a component with props:
```ts
variant: 'input' | 'engine' | 'output'   // styling + role
title: string                            // e.g. "You speak", "On-device cleanup", "Parleq pastes"
lines?: { text: string; mark?: boolean }[]  // transcript lines; mark=true highlights the changed token via .hero-demo-mark
items?: string[]                         // engine variant: capability labels (Cleanup, Punctuation, …)
credit?: string                          // engine variant: "built on Concord (by Keavi)"
size?: 'sm' | 'md'                       // engine card is visibly smaller (sm)
```

- [ ] **Step 1: Build the component** to these acceptance criteria (markup follows existing Tailwind idiom; reuse `.hero-demo-mark` for marked tokens):
  - `input`/`output`: rounded card on a translucent light surface over the dark panel (`bg-white/5`, `border-white/10`), title in `--color-grape-200`, lines in `--color-panel-ink`; marked tokens use `.hero-demo-mark`.
  - `engine`: `size='sm'`, visibly narrower; title "On-device cleanup"; `items` as a check-list; `credit` rendered small and muted (`text-[color:var(--color-grape-300)]/70`). The word "Concord" appears ONLY inside `credit`.
  - No `aria-hidden` (these carry real text). Decorative inner glyphs are `aria-hidden`.

- [ ] **Step 2: Render-test in isolation** — temporarily import into `index.astro` with one of each variant, `npm run build`, confirm no build error and the three cards render. Remove the temporary import.

```bash
cd web && npm run build
```
Expected: build PASS.

- [ ] **Step 3: Commit**

```bash
git add web/src/components/TransformCard.astro
git commit -m "feat(web): TransformCard card primitive for flow grammar"
```

---

### Task 5: `ConcordFlow.astro` — static flow lines (Tier 0)

**Files:**
- Create: `web/src/components/ConcordFlow.astro`

**Interfaces — Produces:** props:
```ts
shape: 'forward' | 'loop' | 'branch'   // beat 1/3 forward, beat 2 loop-back, beat 4 branch
intensity?: 'subtle' | 'standard'      // opacity of background lines
```
Renders an absolutely-positioned, `aria-hidden="true"` SVG with `class="concord-flow ..."` (so Task 2's harness recognizes it as decorative) using **the new grape ramp**, not the pack's off-brand `--color-concord-*`. No motion yet — this IS the reduced-motion baseline.

- [ ] **Step 1: Port the pack's Bézier path data** from `~/Downloads/parleq-redesign-codex-pack/ConcordFlowLines.tsx` (`leftPaths`/`rightPaths` arrays) into an Astro component. Rewrite the gradient `<stop>` colors to `var(--flow-voice)` and `var(--flow-clean)` (delete the pack's hardcoded `#8b4dcc`/`#e87900` fallbacks). Add `shape` variants: `forward` (left+right as today), `loop` (a return path from output back to engine), `branch` (engine → multiple outputs). Keep glow filters defined but unreferenced for now (Task 11 wires event-driven glow; idle glow is banned).

- [ ] **Step 2: Build + harness** — confirm the SVG carries `aria-hidden="true"` and `class="concord-flow"`.

```bash
cd web && npm run build && node scripts/verify-page.mjs || true
```
Expected: no "Decorative SVG missing aria-hidden" error for `concord-flow` (other REQUIRED-missing warnings still expected until Task 13).

- [ ] **Step 3: Commit**

```bash
git add web/src/components/ConcordFlow.astro
git commit -m "feat(web): ConcordFlow static SVG flow lines (Tier 0 baseline)"
```

---

### Task 6: `GrapeCluster.astro` — static Concord-tier cluster

**Files:**
- Create: `web/src/components/GrapeCluster.astro`

**Interfaces — Produces:** props `nodes: { label: string; glyph: 'voiceprint'|'punct'|'number'|'dict'|'compound' }[]`. Renders a refined geometric cluster of small circular nodes (grapes), each with an inline stroke glyph + label, `class="grape-cluster"`, `aria-hidden="true"` on purely decorative SVG parts (labels stay readable text). **Geometric, never cartoon 3D.** This depicts only Concord's deterministic tier (Global Constraints).

- [ ] **Step 1: Build the static cluster** to acceptance:
  - Nodes arranged as a tight, slightly-irregular cluster (not a grid), each a circle filled `--color-grape-700` with a `--color-grape-200` stroke glyph; labels in `--color-grape-200`.
  - One small "stem/leaf" accent allowed, geometric only.
  - 🧑‍⚖️ MAINTAINER CHECKPOINT: cluster reads as "premium/elegant," not "cute." Adjust node size/spacing/glyph weight on feedback.

- [ ] **Step 2: Build**

```bash
cd web && npm run build
```
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add web/src/components/GrapeCluster.astro
git commit -m "feat(web): GrapeCluster (Concord deterministic tier, static)"
```

---

### Task 7: Beat 1 — the framed dark-grape hero

**Files:**
- Modify: `web/src/pages/index.astro` (replace the centered hero `<section>` at lines ~121-227; KEEP the JSON-LD slot at line 118 and `SiteHeader`)

**Consumes:** `TransformCard`, `ConcordFlow` (shape `forward`), the grape ramp, copy-deck Beat 1.

- [ ] **Step 1: Build the hero** to acceptance:
  - A framed (not full-bleed) rounded panel `class="panel-grape"` on the warm-ivory page, `bg-[color:var(--color-grape-900)]`, generous page margin around it.
  - Left column: privacy pill "Your voice never leaves your Mac"; semantic `<h1 class="font-display">` with "Speak freely." in `--color-panel-ink` and "Paste clean." in `--color-grape-300`; subhead (copy deck); **primary CTA preserving `data-goatcounter-click="download-hero"` + `href={downloadUrl}`**; secondary "See it in action" anchor to `#refine`; the feature chips (reuse `.chip`/`.chip-grape`, themed for the dark panel).
  - Right column: `TransformCard` input → `TransformCard` engine (sm, credit "built on Concord (by Keavi)") → `TransformCard` output, with `<ConcordFlow shape="forward" />` absolutely positioned behind them. Use the real payload from the copy deck.
  - The semantic `<h1>` carries the message (decorative art stays `aria-hidden`) — preserves SEO/SR contract.
  - Keep the existing `release.version` suffix on the CTA and the `Apache-2.0 · macOS 14+` line.
  - 🧑‍⚖️ MAINTAINER CHECKPOINT (named in spec §9): does the dark panel read **premium Mac-native**, not **generic dark-mode SaaS**? This is the make-or-break visual; iterate here before proceeding.

- [ ] **Step 2: Build + harness + contrast spot-check**

```bash
cd web && npm run build && node scripts/verify-page.mjs || true
```
Expected: `download-hero`, `Your voice never leaves your Mac`, `built on Concord`, `<h1`, JSON-LD all present; only `download-get-parleq` still missing (Task 13).

- [ ] **Step 3: Commit**

```bash
git add web/src/pages/index.astro
git commit -m "feat(web): beat 1 — framed dark-grape hero with flow grammar"
```

---

### Task 8: Beat 2 — refinement loop (frames the real overlay)

**Files:**
- Modify: `web/src/pages/index.astro` (replace the `#refine` section ~325-529)

**Consumes:** `OverlayMockup` (existing, real before/refine/after text), `ConcordFlow shape="loop"`, copy-deck Beat 2.

- [ ] **Step 1: Build the section** to acceptance:
  - Heading "Not quite right? Just say so." + body (copy deck).
  - Center the real `OverlayMockup` (with `refine="..."` showing a concrete spoken instruction and the before/after transcript) and wrap it with `<ConcordFlow shape="loop" />` so a return path visually loops output → engine → refined output. **The concrete text is the payload; the loop only frames it** (Global Constraints / spec M6).
  - Preserve the section `id="refine"` (the hero's "See it in action" anchors to it) and `scroll-mt-20`.

- [ ] **Step 2: Build + commit**

```bash
cd web && npm run build && git add web/src/pages/index.astro && \
git commit -m "feat(web): beat 2 — refinement loop framing the real overlay"
```

---

### Task 9: Beat 3 — configurable on-device/cloud split + cluster reveal

**Files:**
- Modify: `web/src/pages/index.astro` (replace the `#on-device` grape-zone section ~233-323)

**Consumes:** `TransformCard`, `GrapeCluster`, `ConcordFlow`, copy-deck Beat 3.

- [ ] **Step 1: Build the section** to acceptance:
  - Heading "Instant on your Mac. Powerful in your cloud. Your call." + body describing the **user-configured** split (first-pass on-device, refine to your cloud) — **no automatic handoff language** (Global Constraints; spec §2.2).
  - Show the on-device engine node opening into `<GrapeCluster nodes={[voiceprint,punct,number,dict,compound]} />` with the "built on Concord (by Keavi)" credit.
  - Show the two lanes (on-device ⇄ your cloud: Gemini/Bedrock/Vertex/Azure) as a configurable choice, not an arrow that auto-flows.
  - Keep `id="on-device"` + `scroll-mt-20`.

- [ ] **Step 2: Build + commit**

```bash
cd web && npm run build && git add web/src/pages/index.astro && \
git commit -m "feat(web): beat 3 — configurable split + Concord cluster reveal"
```

---

### Task 10: Beat 4 — per-app engine rows (independent, no fan-out)

**Files:**
- Modify: `web/src/pages/index.astro` (insert a new section after beat 3)

**Consumes:** copy-deck Beat 4. **RELEASE-GATED** (Global Constraints).

- [ ] **Step 1: Build the section** to acceptance:
  - Heading "The right cleanup for every app." + body (copy deck).
  - **Four independent rows** — Slack→Cloud·polished, Mail→Cloud·polished, Terminal→On-device·instant, Notes→On-device·instant — each a self-contained "dictation already in that app" tile with its own configured cleanup badge. **Never a single source fanning out to multiple destinations** (Global Constraints / spec C2). No mic/voice origin node feeding all four.
  - Present tense, no "coming soon"/preview label (release-gated).

- [ ] **Step 2: Manual boundary check + build** — re-read the rendered section: does any element imply "speak → Parleq chooses where to send it"? If yes, redraw. Then:

```bash
cd web && npm run build && git add web/src/pages/index.astro && \
git commit -m "feat(web): beat 4 — per-app engine defaults (independent rows)"
```

---

### Task 11: Beat 5 — accuracy band + capability index + mid CTA

**Files:**
- Modify: `web/src/pages/index.astro` (replace the feature-band section ~531-652)

**Consumes:** copy-deck Beat 5, the existing `capabilities` array (lines 41-114 — KEEP it and its `how-it-works` hrefs).

- [ ] **Step 1: Build the band** to acceptance:
  - Four cards led by **real before→after** micro-examples (copy deck): voiceprints, custom dictionary, numbers & punctuation, private-by-design. Icons are quiet supporting stroke marks (decision on stroke-vs-cluster-glyph locked here per spec Q3). The private-by-design card uses the accurate split language; voiceprints card uses the accurate disambiguation language (Global Constraints).
  - Below the four cards, a **condensed capability index** that preserves all 12 `capabilities` entries (title + the existing `href` deep links into `how-it-works`/`enterprise`) so no inbound link equity is lost — compact list/grid, not the old uniform 12-card wall.
  - A **mid-page CTA** here: `data-goatcounter-click="download-mid"` → `downloadUrl`. (Add `download-mid` is optional in the harness; `download-hero`/`download-get-parleq` remain required.)

- [ ] **Step 2: Build + commit**

```bash
cd web && npm run build && git add web/src/pages/index.astro && \
git commit -m "feat(web): beat 5 — accuracy band + capability index + mid CTA"
```

---

### Task 12: Beat 6 enterprise strip + Beat 7 install/CTA/social slot + mobile + print

**Files:**
- Modify: `web/src/pages/index.astro` (enterprise `#enterprise` ~654-697; final CTA ~699-741)
- Modify: `web/src/styles/global.css` (finish the print block from Task 3; add any mobile utilities)

**Consumes:** copy-deck Beats 6 & 7.

- [ ] **Step 1: Enterprise strip** — evolve `#enterprise` into the compact dark `strip-grape` band (SSO & directory / Bring your cloud / No API keys on devices / Auditable by design), secondary and not salesy. Keep `id="enterprise"`.

- [ ] **Step 2: Get-Parleq section** — preserve the tester-readable install walkthrough and the final CTA with **`data-goatcounter-click="download-get-parleq"`**. Add a reserved, empty social-proof slot (commented placeholder rendered as nothing) for post-Posit.

- [ ] **Step 3: Mobile degradation** — per beat, hide complex `ConcordFlow` SVGs below `sm` (or swap a simple vertical connector); stack hero columns; keep the scroll tight. Verify at 375px width in the browser. 🧑‍⚖️ MAINTAINER CHECKPOINT: mobile scroll length + legibility.

- [ ] **Step 4: Print** — finish the `@media print` block so `.panel-grape`/`.strip-grape` render dark-text-on-white.

- [ ] **Step 5: Build + commit**

```bash
cd web && npm run build && git add web/src/pages/index.astro web/src/styles/global.css && \
git commit -m "feat(web): beats 6-7 + mobile degradation + print stylesheet"
```

---

### Task 13: Full harness green (Tier 0 baseline complete)

**Files:** none (verification gate).

- [ ] **Step 1: Run the full harness — must be green now**

```bash
cd web && npm run build && node scripts/verify-page.mjs
```
Expected: `verify-page: OK` (all FORBIDDEN absent, all REQUIRED present, all decorative SVG `aria-hidden`).

- [ ] **Step 2: Reduced-motion baseline check** — in the browser with "Reduce motion" ON (macOS System Settings → Accessibility → Display), confirm every beat fully renders and reads correctly with zero motion (it must, since no motion exists yet). 🧑‍⚖️ MAINTAINER CHECKPOINT: the static page is genuinely complete and compelling on its own.

- [ ] **Step 3: Commit** (if any fixes were needed)

```bash
git commit -am "fix(web): Tier 0 baseline passes full verification harness" || echo "nothing to fix"
```

---

### Task 14: Motion Tier 1 — choreography coordinator (pulses + event glow)

**Files:**
- Create: `web/src/scripts/flow-choreography.ts` (or an `is:inline` script block in `index.astro` matching the existing inline-script idiom)
- Modify: `web/src/components/ConcordFlow.astro` (expose pulse target elements + glow hooks)

**Architecture:** ONE `requestAnimationFrame` coordinator drives all beats. A single **re-firing** `IntersectionObserver` (distinct from the existing once-only `.reveal` observer) registers/unregisters each beat's flow as it enters/leaves the viewport, so offscreen beats consume zero frames. Motion only initializes when `matchMedia('(prefers-reduced-motion: no-preference)').matches`.

- [ ] **Step 1: Implement the coordinator** to acceptance:
  - For each on-screen flow: one bright traveling pulse per active path (animate a short bright dash/segment along the Bézier via `getPointAtLength` or an offset-path element).
  - Engine **glow is event-driven**: fires when a pulse arrives, decays via a CSS transition, then stops. **No idle/looping glow or border shimmer** (Global Constraints / spec M5).
  - Sequencing per beat: input-pulse → engine-glow → output-pulse (loop beat: + return pulse; branch beat: + per-row pulses).
  - Prefer CSS `box-shadow`/opacity transitions over animated SVG Gaussian-blur filters (perf).
  - Performance budget: ≤ ~6 concurrent animated elements on screen; pause fully when the tab is hidden (`visibilitychange`) and when offscreen.

- [ ] **Step 2: Verify reduced-motion + offscreen** — with Reduce-motion ON: confirm NO pulses initialize (static baseline unchanged). With it OFF: confirm pulses run only for the in-view beat and stop when scrolled away (check via DevTools Performance that offscreen beats aren't animating). 🧑‍⚖️ MAINTAINER CHECKPOINT: motion reads as a calm "heartbeat," not a screensaver; no jank on a non-Pro Mac.

- [ ] **Step 3: Build + harness (still green) + commit**

```bash
cd web && npm run build && node scripts/verify-page.mjs && \
git add web/src/scripts/flow-choreography.ts web/src/components/ConcordFlow.astro web/src/pages/index.astro && \
git commit -m "feat(web): Tier 1 motion — choreographed pulses + event-driven glow"
```

---

### Task 15: Motion Tier 2 — cluster reveal (beat 3 only)

**Files:**
- Modify: `web/src/components/GrapeCluster.astro`, `web/src/scripts/flow-choreography.ts`

- [ ] **Step 1: Animate the cluster reveal** — when beat 3 enters view (motion allowed), the engine node opens into the cluster with a soft, one-shot scale/opacity reveal of the nodes (staggered), plus a single soft border accent that **decays** (not a loop). Reduced-motion: cluster is simply present (Task 6 static state).

- [ ] **Step 2: Verify + commit**

```bash
cd web && npm run build && node scripts/verify-page.mjs && \
git add web/src/components/GrapeCluster.astro web/src/scripts/flow-choreography.ts && \
git commit -m "feat(web): Tier 2 motion — beat-3 cluster reveal"
```

---

### Task 16: Performance + SEO pass

**Files:** none (measurement) → minor fixes as found.

- [ ] **Step 1: Lighthouse** (mobile + desktop) on the built preview:

```bash
cd web && npm run build && npm run preview &
# run Lighthouse against http://localhost:4321/ (or the printed port), then kill preview
```
Expected: Performance ≥ 90, Accessibility ≥ 95, Best-Practices/SEO ≥ 95. Record scores. Fix regressions (font loading, layout shift from the hero panel, oversized SVG).

- [ ] **Step 2: Confirm SEO continuity** — JSON-LD present and valid, `<title>`/description intact, canonical correct, the semantic `<h1>` carries the headline, `/PAR-lek/` retained in the subhead.

- [ ] **Step 3: Commit any fixes**

```bash
git commit -am "perf(web): Lighthouse + SEO continuity pass" || echo "no fixes needed"
```

---

### Task 17: Review gate (hold before deploy)

**Files:** none.

- [ ] **Step 1: Self-review** the full diff against the spec's §12 pre-gate checklist (copy deck, contrast ratios, per-app rows-not-fan-out, motion fenced to Tier 0–1+Tier 2 beat 3, SEO/CTA/install/long-tail continuity, headline).
- [ ] **Step 2: Adversarial + balanced subagent review** (project process) — dispatch both on the built branch; reconcile findings; fix.
- [ ] **Step 3: RoboRev** the commits; address high/critical + medium, read lows.
- [ ] **Step 4: HOLD at the approval gate.** Do NOT open the PR / merge / deploy until (a) the maintainer approves AND (b) the parallel **per-app cleanup-engine feature has shipped or ships simultaneously** (RELEASE GATE). Tier 3 north-star remains a post-v1 gated fast-follow.

---

## Self-review (plan vs. spec)

- **Spec coverage:** positioning/differentiators → beats 1-4 (Tasks 7-10); accuracy guardrails → Global Constraints + Task 2 harness + copy deck (Tasks 1-2); flow grammar → Tasks 4-5; grape cluster scoped to Concord tier → Task 6/9; tiered motion w/ static-first → Tasks 5,13,14,15; north-star → explicitly deferred (Global Constraints/Task 17); token ramp + AA → Task 3; SEO/CTA/install/long-tail continuity → Tasks 7,11,12,16; mobile/print → Task 12; per-app release gate → Global Constraints + Tasks 10,17; review process → Task 17. All §11 resolved decisions encoded (headline Task 7, per-app Task 10). Open Q3 (icons) resolved at Task 11; Q4 (Tier 3) deferred.
- **Placeholder scan:** deterministic tasks (1-3, 14) carry full code; visual tasks (4-12) carry props/interfaces + checkable acceptance criteria + 🧑‍⚖️ checkpoints (appropriate for a visual redesign with no unit-test target — verification is build + harness + maintainer judgment, stated in the header).
- **Type consistency:** `ConcordFlow` `shape` values (`forward`/`loop`/`branch`) used consistently in Tasks 5,7,8,9; `TransformCard` variants (`input`/`engine`/`output`) consistent Tasks 4,7,9; GoatCounter hooks (`download-hero`, `download-get-parleq`) match the harness REQUIRED list and Tasks 7,12.
