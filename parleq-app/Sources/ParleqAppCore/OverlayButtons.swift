// OverlayButtons — Copy / Cancel / Accept controls + focus-loss
// message displayed in the overlay's footer region.
//
// Behavior:
//   - Copy: copies the overlay's current cleaned text to the
//     general pasteboard. Does NOT dismiss the overlay. Shows
//     "Copied ✓" inline for ~1.2s after click — long enough to
//     register without staying on-screen so long it competes
//     with the user's next action.
//   - Cancel (Esc): discards the session and dismisses the overlay.
//   - Accept (Enter): pastes the current cleaned text into the
//     paste-target app and dismisses the overlay.
//
// When the overlay panel is not key (the user switched to another
// app via Mission Control / Cmd-Tab), the focus-loss message
// replaces the keyboard-shortcut hints to teach the user that
// Enter/Esc won't fire here until the panel regains focus.

import SwiftUI

struct OverlayButtons: View {
    let isKey: Bool
    /// Paste destination, rendered inline as a non-interactive label
    /// immediately before the Accept button — so the user can read
    /// the row as "Cancel, → Slack, Accept" and it's visually obvious
    /// which app Accept will paste into. nil → label omitted (e.g.,
    /// no destination available yet).
    let pasteTarget: PasteDestination?
    /// nil when no conflict. Non-nil swaps the normal button row for
    /// a warning row and implicitly blocks Accept.
    let conflict: ModelConflict?
    /// A configured vision-capable model the user can one-click
    /// switch to. nil → omit the Switch button.
    let visionFallbackOption: ModelIdentifier?
    let onCopy: () -> Void
    let onCancel: () -> Void
    let onAccept: () -> Void
    /// Caller writes the picked ModelIdentifier to OverlayModel
    /// .pickedModelOverride.
    let onSwitchToVisionModel: (ModelIdentifier) -> Void
    /// Caller writes OverlayModel.userDowngradedConflict = true.
    let onDowngrade: () -> Void

    @State private var showCopied = false
    /// Window prevents stale completions from a prior Copy click from
    /// resetting the label while a newer click's flash is still
    /// visible. Each click bumps the generation; the trailing reset
    /// only fires if the generation hasn't moved.
    @State private var copyGeneration = 0

    var body: some View {
        VStack(spacing: 6) {
            if !isKey {
                Text("Parleq lost focus. Click anywhere in this overlay to regain focus.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }

            if let conflict {
                conflictWarningRow(conflict)
            } else {
                normalButtonRow
            }
        }
    }

    /// Conflict warning row shown when image-mode references are
    /// attached to a non-vision model. Accept is implicitly blocked
    /// (the button is absent). User options: switch to a vision model,
    /// acknowledge downgrade (send refs as text), or cancel entirely.
    @ViewBuilder
    private func conflictWarningRow(_ conflict: ModelConflict) -> some View {
        if case .visionRefsButNonVisionModel(let n) = conflict {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("\(n) reference\(n == 1 ? "" : "s") will be sent as text — image content will be lost.")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let visionModel = visionFallbackOption {
                    Button("Switch to \(visionModel.displayShort)") {
                        onSwitchToVisionModel(visionModel)
                    }
                    .controlSize(.small)
                }
                Button("Downgrade & send", action: onDowngrade)
                    .controlSize(.small)
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            }
        }
    }

    /// Normal Copy / Cancel / Accept button row, shown when there is
    /// no active ModelConflict.
    ///
    /// Footer layout:
    ///   [Pasting to: <app>]           [Copy] [Cancel] [Accept]
    /// The paste-target sits on the LEFT as a descriptive label
    /// ("Pasting to:"), and all three actions cluster together on the
    /// RIGHT with proper button chrome (.bordered + .borderedProminent)
    /// so they read unambiguously as buttons. Earlier iterations used
    /// `.plain` controls which didn't read as tappable, and wedged the
    /// paste-target between Cancel and Accept which made the row look
    /// like a mixed cluster of peer controls.
    @ViewBuilder
    private var normalButtonRow: some View {
        HStack(spacing: 8) {
            if let target = pasteTarget {
                PastingToLabel(target: target)
            }
            Spacer(minLength: 12)

            Button(action: handleCopy) {
                Label(showCopied ? "Copied ✓" : "Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 11))
                    // Stable width so the label swap doesn't
                    // reflow the surrounding row.
                    .frame(minWidth: 60, alignment: .center)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Copy cleaned text to clipboard")

            Button(action: onCancel) {
                HStack(spacing: 5) {
                    Text("Cancel")
                    keyCap("⎋", isProminent: false)
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Cancel and dismiss")

            Button(action: onAccept) {
                HStack(spacing: 5) {
                    Text("Accept")
                    keyCap("⏎", isProminent: true)
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            // Tint Accept with the Parleq brand orange instead
            // of the system accent (blue). Ties the primary
            // action to the same color as the listening
            // indicator, so the overlay reads as having one
            // coherent accent rather than two competing colors.
            .tint(SettingsView.brandAccent)
            .controlSize(.small)
            .accessibilityLabel("Accept and paste")
        }
    }

    // pasteTargetLabel extracted to the top-level PastingToLabel view
    // so the same visual treatment ("PASTING TO" eyebrow + icon +
    // name) can render in the footer during active dictation states
    // without duplicating the view code.

    /// Mini "key cap" chip for keyboard-shortcut glyphs (⏎, ⎋).
    /// Replaces the previous inline-glyph treatment with a
    /// bordered rounded rectangle, which reads as a physical key
    /// rather than just a stray symbol. `isProminent` switches the
    /// stroke/text colors to a white-translucent palette suitable
    /// for the orange Accept button background; the default
    /// secondary palette suits the bordered Cancel button.
    @ViewBuilder
    private func keyCap(_ symbol: String, isProminent: Bool) -> some View {
        let foreground: Color = isProminent
            ? Color.white.opacity(0.85)
            : Color.secondary
        let stroke: Color = isProminent
            ? Color.white.opacity(0.4)
            : Color.secondary.opacity(0.4)
        Text(symbol)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(foreground)
            .frame(minWidth: 12)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }

    private func handleCopy() {
        onCopy()
        copyGeneration += 1
        let myGen = copyGeneration
        showCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            // Only reset if no newer click has bumped the generation.
            if copyGeneration == myGen {
                showCopied = false
            }
        }
    }
}

#if DEBUG
private let _previewTarget = PasteDestination(
    bundleID: "com.tinyspeck.slackmacgap",
    appName: "Slack",
    windowTitle: "#design-feedback",
    appIcon: NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.tinyspeck.slackmacgap")
        .flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
)

#Preview("Key, with paste target") {
    OverlayButtons(
        isKey: true,
        pasteTarget: _previewTarget,
        conflict: nil,
        visionFallbackOption: nil,
        onCopy: {},
        onCancel: {},
        onAccept: {},
        onSwitchToVisionModel: { _ in },
        onDowngrade: {}
    )
    .padding()
    .frame(width: 700)
}

#Preview("Key, no paste target") {
    OverlayButtons(
        isKey: true,
        pasteTarget: nil,
        conflict: nil,
        visionFallbackOption: nil,
        onCopy: {},
        onCancel: {},
        onAccept: {},
        onSwitchToVisionModel: { _ in },
        onDowngrade: {}
    )
    .padding()
    .frame(width: 700)
}

#Preview("Not key, focus-loss message visible") {
    OverlayButtons(
        isKey: false,
        pasteTarget: _previewTarget,
        conflict: nil,
        visionFallbackOption: nil,
        onCopy: {},
        onCancel: {},
        onAccept: {},
        onSwitchToVisionModel: { _ in },
        onDowngrade: {}
    )
    .padding()
    .frame(width: 700)
}

#Preview("Conflict — vision refs, vision fallback available") {
    OverlayButtons(
        isKey: true,
        pasteTarget: _previewTarget,
        conflict: .visionRefsButNonVisionModel(refCount: 3),
        visionFallbackOption: ModelIdentifier(provider: "gemini", model: "gemini-2.5-flash"),
        onCopy: {},
        onCancel: {},
        onAccept: {},
        onSwitchToVisionModel: { _ in },
        onDowngrade: {}
    )
    .padding()
    .frame(width: 700)
}

#Preview("Conflict — vision refs, no vision fallback") {
    OverlayButtons(
        isKey: true,
        pasteTarget: _previewTarget,
        conflict: .visionRefsButNonVisionModel(refCount: 1),
        visionFallbackOption: nil,
        onCopy: {},
        onCancel: {},
        onAccept: {},
        onSwitchToVisionModel: { _ in },
        onDowngrade: {}
    )
    .padding()
    .frame(width: 700)
}
#endif
