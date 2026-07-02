# Interactive Reference Windows demo — plan (2026-07-01)

**Goal.** Turn the Reference Windows walkthrough (today a 3-step *static* stepper on the homepage explorer's "How it works" tab) into a **fully interactive, guided product demo**: the visitor performs the real gestures — press **Space** to attach a window, **pick** a window, **hold to talk** to dictate — and watches Parleq produce a context-aware result. Prove the interactive-demo pattern on this ONE feature; templatize later.

Component: `web/src/components/GrapeExplorer.astro`. Panel: `data-panel="hiw-reference"`.

## Principles
- **Guided-interactive.** Each stage prompts + highlights the real gesture; the user's actual keypress/click advances it. Not free-form.
- **Never stuck.** A persistent pager (Back / dots / Next) is the fallback AND the a11y / reduced-motion / no-JS path. Next advances the state machine regardless of gesture.
- **Truthful.** Mirrors the real flow (in Parleq: hold the hotkey, tap Space → window picker → pick → keep dictating → cleanup uses the window as context). The "holding the hotkey" precondition is folded into the demo framing, not faked.
- **Only voice is simulated.** No live mic/ASR on the homepage. The "talk" step is a mic affordance that, when activated, plays a short "recording" state and types out a canned utterance.
- **Accessible + responsive from the start**, not bolted on.

## The flow — a 4-stage state machine (S0 → S1 → S2 → S3)
The right column shows a Parleq **overlay mock in Mail**; a **coachmark** line above/below the pager narrates the current step.

- **S0 · Attach a window.** Overlay shows a rough dictation in progress. Coachmark: *"Give the model context — press Space to bring a window in."* Affordance: a key-styled **`␣ Space`** button (pulsing). Activate (click / Enter / Space on the focused button) → S1.
- **S1 · Pick a window.** A window-picker drops into the overlay: **📅 Calendar** (highlighted/suggested), Slack, Notes. Coachmark: *"Pick the window to use as context."* Calendar is the actionable target (pulses); Slack/Notes are shown dimmed/inert so the flow stays deterministic. Click Calendar → S2.
- **S2 · Dictate.** Overlay now shows a **📅 Calendar — attached** chip. Coachmark: *"Now dictate your question — hold to talk."* Affordance: **🎙 Hold to talk** button (pulsing). Activate → a brief "recording" state (mic pulse) while the utterance types out: *"does thursday work for the check in"* → on finish → S3.
- **S3 · Result.** The cleaned, context-aware result reveals: *"Looks like **Thursday at 2pm** is open — does that work for the check-in?"* + a mock **Accept**. Coachmark: *"Parleq used your calendar. That's Reference Windows."* A **↺ Replay** resets to S0.

The pager: `‹ Back` · 4 dots · `Next ›` (filled grape). Next steps the machine forward (auto-completing the current gesture); Back steps back; dots reflect stage. Reaching S3 disables Next (Replay handles restart).

## Architecture
- Replace the `hiw-reference` `stepper-wrap` with an **interactive panel** (bespoke for now): the overlay mock + per-stage sub-elements (coachmark, Space affordance, picker rows, attach chip, mic button, result) that show/hide by stage, plus the shared pager markup.
- Inline `<script>` gains a small **state machine** scoped to this panel: `render(stage)` toggles the stage sub-elements, sets the coachmark text (via an `aria-live` region), updates dots + Back/Next disabled state, and **focuses the current stage's affordance with `focus({preventScroll:true})`** so Space/Enter/click all activate it natively.
- **No global Space listener** (that would hijack page scroll). The affordances are real `<button>`s; focusing the current one (only on user-initiated stage entry — i.e., after the user selects the Reference grape or clicks Next/an affordance, never on initial page load) means the native button handles Space/Enter. This satisfies "press Space" without breaking scroll or a11y.
- **Hold to talk:** the mic `<button>` responds to `pointerdown`/`pointerup` (hold) and to plain activation (click / keyboard) — either way it runs the recording+typing sim, then advances. Typing uses a timed reveal.
- **Reset:** hook the panel into the existing `stepperResets` map (keyed by `data-panel`) so selecting the Reference grape resets it to S0.
- **Reduced motion:** skip typing/pulse animations — reveal final text instantly, no pulsing.
- **No-JS:** server-render stage S3's final content (the meaningful end state: attached chip + before/after) visible, so the panel is never empty without JS. JS then resets to S0 and takes over.
- **Mobile (< lg):** the `␣ Space` affordance reads **"Tap to attach"**; the mic reads **"Tap to talk."** Everything is tap-driven; the guided highlight tells the user what to do.

## Accessibility
- Every affordance is a focusable `<button>`; the whole flow is operable by keyboard (Tab to the affordance, Enter/Space to act) and by the pager.
- The coachmark is an `aria-live="polite"` region so stage changes are announced.
- The Space keyboard shortcut is an *enhancement* via native focused-button activation — never a global hijack.
- Reduced-motion respected; focus is moved with `preventScroll`.

## Scope guardrails (YAGNI)
- **Only Reference Windows** becomes interactive now. The refine loop stays the static stepper; Voice / Never-lose / Paste stay inert placeholders.
- No live mic, no real window enumeration, no branching on which window is picked (Calendar is the guided path). All content canned + truthful.
- Ships as a clearly-labeled `spike(web):` commit.

## Verification
- `npm run build` clean + `node scripts/verify-page.mjs` green.
- Screenshot **each stage S0–S3** (temporarily default the machine to each) to confirm rendering; revert.
- Code-review the state machine + interaction wiring for stuck-states, focus handling, and reduced-motion/no-JS paths.
- Ship a manual test script for the maintainer: (1) Space → Calendar → hold mic → result; (2) keyboard-only; (3) Next-only fallback; (4) Replay.

## Risks / open questions
1. **Space scroll-hijack** — resolved by native focused-button activation instead of a global listener (see Architecture).
2. **Complexity creep** — bespoke now; templatize after it feels right.
3. **Two fidelities in one tab** (interactive RW vs static refine loop) temporarily — acceptable for the spike; note it in the report.
4. **Focus-steal** — only focus affordances on user-initiated stage entry, with `preventScroll`.
5. **Hold-vs-click mic fidelity** — support both; activation plays the sim.
