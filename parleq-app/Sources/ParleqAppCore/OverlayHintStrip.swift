// OverlayHintStrip — the per-state hint copy at the bottom of the
// dictation overlay for Reference Windows v2's latched-compose flow.
//
// The strip is the only visual surface that teaches the new Space-
// during-dictation gesture. It renders empty when composeState is
// .idle (the v1 dominant case) so users who never press Space see
// no UI change at all. As composeState advances through the latched
// flow, the strip surfaces the next available actions.
//
// Wording calibrated for teaching on first encounter, then trimming
// to terser cues in the latched states once the user has the
// gesture vocabulary. See
// docs/superpowers/specs/2026-05-23-reference-windows-latched-compose-design.md
// for the rationale on each copy variant.

import SwiftUI

@MainActor
struct OverlayHintStrip: View {
    let state: ComposeState
    /// Display name of the user's dictation hotkey (e.g. "⌥-Right",
    /// "Fn"). Falls back to "the hotkey" when empty so a forgot-to-
    /// inject path still renders sensible English.
    let hotkeyDisplayName: String
    /// Mirror of Config.referenceWindowsEnabled. When false, the
    /// .recording-state hint is suppressed entirely — Space wouldn't
    /// open the picker in that case (gated upstream in AppState), so
    /// teaching the gesture would be misleading. The .latched /
    /// .latchedRecording states are unreachable when the feature is
    /// off (the .recording → .pickerOpen transition is gated on the
    /// same flag), so they don't need separate guarding.
    let referenceWindowsEnabled: Bool
    /// True from the moment Space lands during a dictation hold until
    /// the hold ends. When true and state is .recording, swaps the
    /// teaching hint for an "armed" confirmation hint so the user
    /// gets immediate feedback that Space was recognized — they
    /// don't have to wait for the hotkey release for visual proof.
    let spaceArmedDuringHold: Bool

    private var hotkeyLabel: String {
        hotkeyDisplayName.isEmpty ? "the hotkey" : hotkeyDisplayName
    }

    var body: some View {
        Group {
            switch state {
            case .recording:
                // First encounter — teach the gesture in full
                // English. After the user presses Space and lands
                // in .pickerOpen / .latched, subsequent strips can
                // assume vocabulary. Suppressed entirely when the
                // user / IT admin has disabled reference windows;
                // promising "Press Space to attach a window" when
                // Space wouldn't actually attach anything is worse
                // than no hint.
                //
                // The spaceArmedDuringHold variant swaps the teaching
                // copy for an "armed" confirmation the instant Space
                // is pressed (the listener edge-triggers a callback
                // into AppState.spacePressedDuringHold). Without this
                // the user gets no visual feedback until the hotkey
                // is released and the picker actually opens — feels
                // unresponsive on the dominant fast Space-then-
                // release path.
                // Spike note: the strip now renders inside the footer
                // row, REPLACING the "Release ⌥ when done" hint during
                // the hold — so the recording copy leads with the
                // release cue to keep that affordance discoverable.
                if referenceWindowsEnabled {
                    if spaceArmedDuringHold {
                        Text("Picker opens on release · Esc to cancel")
                    } else {
                        Text("Release: done · Space: attach a window · C: this window · P: Parleq")
                    }
                } else {
                    // Reference windows are off, so there's no Space
                    // gesture to teach — but the hold-hotkey + P gesture
                    // (summon the Parleq window) still works, so keep
                    // that hint visible.
                    Text("Release: done · P: open Parleq")
                }

            case .pickerOpen:
                // Picker has its own UI; strip is hidden so it
                // doesn't compete for attention.
                EmptyView()

            case .latched:
                // Audio paused, picker closed, overlay locked open.
                // The user isn't holding the hotkey — so "release to
                // send" is misleading (there's nothing held to
                // release). And Space pressed here goes to the
                // focused app because HotkeyListener only consumes
                // Space while the dictation hotkey is held (consuming
                // it in .latched would require coupling that we
                // haven't built and don't need: users can attach
                // another reference by starting a new hold + Space).
                //
                // Copy leads with the dominant next-action: a quick
                // tap-and-release sends. Hold-for-more comes second
                // (less common after attaching a single reference),
                // Esc third. Earlier wording led with "Hold to
                // dictate more" and buried "tap to send" mid-line,
                // which user testing flagged as not-obvious-enough
                // that you can simply tap to ship the composition.
                Text(
                    "Tap \(hotkeyLabel) to send · Hold for more · Esc cancel"
                )

            case .latchedRecording:
                // Second-or-later hold in the latched session.
                // User has the vocabulary; trim to action cues. The
                // spaceArmedDuringHold variant swaps for an "armed"
                // confirmation when Space is pressed mid-hold, so
                // the hint behaves symmetrically with .recording —
                // the user gets the same instant feedback signal
                // whether they're in their first hold or a later
                // latched-compose hold.
                if spaceArmedDuringHold {
                    Text("Picker opens on release · Esc to cancel")
                } else {
                    Text("Release to send · Space: another reference")
                }

            case .idle:
                // v1 dominant case — no strip. Keeps the existing
                // overlay layout unchanged for users who never
                // touch the latched flow.
                EmptyView()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        // No horizontal padding — the parent overlay container
        // already applies .padding(16). An extra 12pt inset here
        // would visually indent the hint relative to the footer
        // line above it ("Release ⌥ when done"), which the user
        // flagged as looking misaligned. Vertical padding stays
        // to space the hint a bit from the line above.
        .padding(.vertical, 6)
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
