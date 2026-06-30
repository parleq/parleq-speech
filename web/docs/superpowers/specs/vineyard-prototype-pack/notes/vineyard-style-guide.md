# Vineyard Visual Style Guide for Parleq

## Visual north star

Premium indie Mac app, not playful web toy.

The vineyard metaphor should feel like a tasteful organizing lens, not a literal theme park.

Desired feeling:

- calm
- confident
- tactile
- intelligent
- slightly playful
- privacy-aware
- beautifully crafted

## Palette

Use the existing palette from the handoff.

```css
:root {
  --background: #fafaf7;
  --surface: #ffffff;

  --text: #0f172a;
  --muted: #475569;
  --subtle: #64748b;

  --amber: #d97706;
  --amber-hover: #b45309;
  --amber-soft: #fef3c7;

  --grape-950: #150720;
  --grape-900: #23103a;
  --grape-800: #311551;
  --grape-700: #472075;
  --grape-600: #552789;
  --grape-500: #5b2a86;
  --grape-400: #7d44b0;
  --grape-300: #a87fce;
  --grape-200: #cdb4e6;
  --grape-100: #ebe0f6;

  --panel-ink: #f6f1fb;
}
```

## Typography

- Display/headlines: Fraunces
- Body/UI: Inter

Use Fraunces for section titles such as:

- “The vine”
- “Explore the bunch”
- “Your Mac is the vineyard”

Use Inter for all controls, labels, chips, panel text, demo text, and navigation.

## Grape explorer section

The grape explorer should sit after the main hero.

Recommended desktop layout:

```text
[Section intro + grape clusters]  [Active demo panel]
```

or:

```text
[Heading]
[Cluster + demo panel side by side]
[Jump to another grape chips]
```

The explorer must feel interactive.

### Grape visual style

Grapes should be circular buttons.

Use:

- deep grape fill
- subtle radial highlight
- soft rim light
- simple icon
- short label
- visible selected state
- focus-visible ring

Do not use:

- realistic fruit texture
- water droplets
- wine motifs
- leaf-heavy illustration
- cartoon vines
- excessive shadows

### Selected grape state

Selected grape:

- slightly larger
- brighter grape rim
- subtle amber edge light
- emits flow lines to demo panel
- shows a small check or active marker only if needed

### Cluster layout

Use two clusters:

1. Cleanup
2. Refine & shape it

Keep the number of visible grapes curated.

Avoid a huge bunch with dozens of circles.

Cleanup examples:

- Punctuation
- Numbers
- Your words
- Sound-alikes
- Custom dictionary

Refine examples:

- Shorten
- Simplify
- Tone
- Structure
- Style presets
- Context / reference window

Final labels can be changed by content work. The prototype can use placeholders.

## Demo panel style

Use the Parleq floating overlay motif.

Panel style:

- dark rounded card
- background around `#1c2128`
- subtle grape border
- top hint row
- small model/cleanup chip
- before/after or step sequence
- amber-tinted action chips
- bottom bar with destination and actions

Suggested controls:

- Back
- Next
- Step indicator
- Close or return option if modal-style
- Jump to another grape chips below

Primary action button should use amber.

## Flow lines

Use the existing amber→violet visual language.

Flow lines should:

- originate from selected grape
- converge into the demo panel or active cleanup area
- be thin and elegant
- include one or two bright active strands
- include several low-opacity supporting strands
- avoid chaotic neon

Implementation can use SVG cubic Bézier paths.

## Vineyard privacy section

Use the vineyard metaphor here more directly, but restrained.

Suggested headline:

```text
Your Mac is the vineyard.
```

Suggested supporting concept:

```text
Your voice stays inside. Text only crosses the gate you choose.
```

Visual treatment:

- large rounded rectangle or framed panel representing the Mac boundary
- subtle fence/gate line
- no literal scenery
- no characters
- no sun/hills/leaves/wine
- small gate motif for user-controlled outbound cleanup
- outside boundary: user-owned cloud options
- enterprise policy/SSO as gate rules

Use Prototype C only as an atmospheric reference. Reduce literalness in implementation.

## Icon style

Use crisp geometric stroke icons.

Recommendations:

- Lucide or custom SVG icons
- 1.75–2px stroke
- rounded caps/joins
- grape color foreground
- pale lavender circular backing
- no glossy 3D icon assets
- no AI-generated raster icons

Icon concepts:

- Voiceprints: microphone + sound split / two word bubbles
- Numbers: hash or “123”
- Punctuation: quotes / period / question mark
- Custom words: book or tag
- Sound-alikes: two similar waveforms
- Privacy: shield / lock
- Refine: wand/sparkle only if restrained
- Style presets: sliders or chips

## Restraint rules

### Do

- Use the grape motif as clickable UI
- Keep the page short and opt-in
- Show one idea at a time
- Keep feature names literal
- Use dark Parleq overlay panels for demos
- Keep “Your voice never leaves your Mac” prominent
- Use visual containment for privacy

### Don’t

- Create a literal vineyard scene
- Add wine references
- Add farm visuals
- Use cartoon leaves/tendrils
- Rename features into metaphor terms
- Show too many grapes at once
- Claim “nothing leaves your Mac” when text cleanup may use user-provided cloud
