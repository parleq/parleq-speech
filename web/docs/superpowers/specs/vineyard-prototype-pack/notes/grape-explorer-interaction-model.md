# Grape Explorer Interaction Model

## Preferred desktop interaction

Use a split-stage pattern, not a full modal by default.

### Layout

Left:

- section intro
- Cleanup cluster
- Refine & shape it cluster

Right:

- active demo panel

Bottom:

- “Jump to another grape” chips or compact navigation

### Interaction

1. Visitor hovers/focuses a grape.
2. Grape lifts slightly and shows clear affordance.
3. Visitor clicks grape.
4. Grape becomes selected:
   - larger
   - brighter rim
   - subtle amber edge
   - flow lines animate toward panel
5. Right-side demo panel changes to that grape’s demo.
6. User can:
   - go Back / Next within that demo
   - jump to another grape
   - continue scrolling

### Why this is better than default modal

- The bunch remains visible.
- The user keeps context.
- The page feels interactive without interrupting.
- It avoids hiding the central metaphor.

## Modal option

A modal can still be used on mobile or when a feature needs a larger demo.

If used, the modal should:

- feel like Parleq’s floating overlay
- have Back / Next / Close
- allow jumping to another grape
- return to the selected grape state when closed

## Mobile interaction

Do not force a literal grape bunch as the main control.

Recommended mobile:

1. Small decorative grape cluster near the top
2. Tabs:
   - Cleanup
   - Refine
3. Vertical list of grape buttons
4. Selected grape expands inline into demo card
5. Flow lines are hidden or simplified

## Accessibility

Each grape must be a real button.

Requirements:

- keyboard reachable
- visible focus ring
- aria-label or visible label
- selected state communicated with `aria-pressed` or tab semantics
- decorative flow lines `aria-hidden="true"`
- respect `prefers-reduced-motion`

## Animation

Use subtle transitions:

- 150–250ms hover/select
- 300–500ms panel transition
- slow SVG path motion only if reduced-motion is not set

Avoid:

- bouncing grapes
- literal grape splitting/opening
- liquid/juice effects
- excessive shimmer
