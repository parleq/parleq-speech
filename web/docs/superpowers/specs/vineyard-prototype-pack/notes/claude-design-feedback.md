# Claude Design Feedback — Parleq Vineyard Handoff

## Executive summary

The vineyard metaphor is promising because it maps to real product concepts rather than acting as pure decoration.

The strongest idea is not “grapes are cute.” The strongest idea is:

> Parleq is not one dictation trick. It is a cluster of small, sharp capabilities that compound.

The grape explorer can replace a long feature grid with a compact, interactive, opt-in learning object. That is a strong direction for a shorter indie-Mac-app-style homepage.

The main caution: keep the metaphor restrained. The moment this becomes a literal vineyard illustration, it risks feeling kitschy and less premium.

## What works very well in the handoff

### 1. The nested metaphor has real product logic

The handoff maps:

- vineyard boundary → the user’s Mac / privacy boundary
- vine → Parleq
- clusters → capability families
- grapes → individual features

That is a useful design system because it creates a visual hierarchy for the product.

### 2. The grape explorer solves the “too much content” problem

The current homepage is described as dense and long. The grape explorer is a good answer because it lets the homepage show breadth while letting details stay opt-in.

A compact explorer can replace a long grid of static feature cards.

### 3. The privacy boundary is honest

The handoff’s distinction is important:

- “Your voice never leaves your Mac” is accurate and should remain prominent.
- “Nothing leaves your Mac” is too broad because text cleanup can use a user-provided cloud account.

The vineyard/gate metaphor helps explain this honestly without sounding legalistic.

### 4. The restraint guardrails are exactly right

The following guardrails should be preserved:

- no literal farm scene
- no wine
- no cartoon gatekeepers
- no rolling hills / sun / rural illustration
- real feature names stay literal
- the metaphor is a lens, not a full renaming system
- curate, don’t enumerate

These guardrails are essential.

## Pushback / recommended adjustments

### 1. Keep the main hero product-first

The vineyard metaphor should probably begin below the hero.

The already-selected hero direction is strong: dark grape panel, “Speak messy. Paste clean.”, input-to-clean-output transformation, download CTA.

Do not let grapes take over the hero. The hero should immediately explain the product. The grape explorer should become the next section for exploration.

### 2. Use “Speak messy. Paste clean.” unless there is a strong reason not to

The handoff mentions “Speak freely. Paste clean.” That is elegant, but “Speak messy. Paste clean.” is more distinctive and more conversion-oriented.

“Speak messy” immediately communicates the product insight: users do not need to compose polished dictation in their head before speaking.

A possible compromise:

- H1: “Speak messy. Paste clean.”
- Supporting copy includes “Speak freely with a global hotkey…”

### 3. Do not over-brand Concord in public-facing UI

The handoff says Concord should be attribution only. That means the visual engine in the hero or explorer should not over-present Concord as a public product brand.

Prefer labels such as:

- Cleanup
- On-device cleanup
- Parleq cleanup
- Cleanup engine

Then add small attribution where appropriate:

- “built on Concord by Keavi”

This preserves the visual “engine” concept without making Concord compete with Parleq.

### 4. Be precise about Voiceprints

Do not describe Voiceprints as learning the user’s style, rhythm, or personal voice.

Use wording such as:

> Voiceprints help Parleq tell sound-alike words apart — for example, “Keavi” the name vs. “kiwi” the fruit.

This is more accurate and more concrete.

### 5. Prefer a split-stage explorer over a full modal on desktop

The handoff suggests that a grape opens into an overlay/modal. That can work, but a full modal may hide the bunch and interrupt exploration.

Recommended desktop pattern:

- left: grape cluster(s)
- right: active demo panel
- selected grape remains visible
- active grape connects to the panel with amber→violet flow lines
- demo panel updates in place
- optional Back/Next inside the panel

This keeps the bunch visible and makes exploration feel continuous.

### 6. Keep mobile different

Do not force a literal grape bunch interaction on mobile.

Recommended mobile pattern:

- small decorative bunch at top
- tabs for Cleanup / Refine
- vertical list of grape buttons
- selected grape expands inline into demo card
- complex flow lines are hidden or simplified

## Prototype evaluation

### Prototype A — Minimal editorial grape explorer

Strengths:

- Most restrained
- Strong whitespace
- Best preservation of indie Mac app calm
- Grape cluster reads as UI rather than illustration
- Demo panel is close to the actual Parleq overlay motif

Weaknesses:

- The second “Refine” group feels visually underpowered
- The section may feel a little too quiet if the goal is captivation
- Some grapes may need clearer labels / affordances

Recommended use:

- Borrow its restraint, spacing, and dark overlay panel treatment.

### Prototype B — Balanced grape explorer

Strengths:

- Most likely overall winner for the explorer direction
- Clear two-cluster structure
- Grape metaphor is obvious but still mostly premium
- Demo panel is rich and understandable
- “Jump to another grape” pattern is promising
- Stronger sense of interaction and browsability

Weaknesses:

- Leaves/tendrils push close to kitsch
- The literal vine stem may be too much
- The demo panel risks becoming too content-heavy
- Some generated icons/details should not be copied literally

Recommended use:

- Use as the primary inspiration, but remove or heavily reduce literal leaves/tendrils.
- Keep the two-cluster arrangement and right-side demo panel pattern.

### Prototype C — Immersive vineyard / boundary

Strengths:

- Best exploration of the privacy/boundary mood
- Shows how a subtle fence/gate motif can work
- The “active grape sends lines into demo” concept is strong
- Light lavender atmosphere feels differentiated from the hero
- Useful for the future privacy section

Weaknesses:

- Too atmospheric for the main grape explorer
- The fence posts at the bottom are near the edge of becoming literal
- The phrase “Explore your vineyard” may be too metaphor-heavy
- The clusters feel more illustrative than clickable

Recommended use:

- Borrow its boundary/gate visual language for the privacy section, not necessarily the explorer.
- Keep the fence motif extremely subtle.

## Recommended synthesis

Use this direction:

> Prototype B structure + Prototype A restraint + Prototype C privacy/boundary cue.

For the grape explorer:

- Two flagship clusters: Cleanup and Refine & shape it
- Grape buttons are clickable UI, not decorative illustration
- Active grape remains visible and connected to demo panel
- Demo panel uses real Parleq floating overlay motif
- Avoid literal leaves/tendrils or use only the faintest abstract hint
- Keep feature names literal

For the privacy section:

- Use a separate “vineyard boundary” moment
- Show the Mac as a contained boundary
- Show a subtle gate where user-controlled text cleanup can leave
- Keep “Your voice never leaves your Mac” as the anchor claim
- Avoid literal farming visuals

## Final recommendation

Proceed with visual direction based on Prototype B, but simplify it.

Claude should not attempt to reproduce the generated images literally. Instead, implement a refined product UI that borrows their composition and mood.
