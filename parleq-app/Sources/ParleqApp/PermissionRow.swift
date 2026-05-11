// PermissionRow — the reusable SwiftUI row that renders one permission
// in the Permissions Settings section and in the Setup wizard's
// Permissions step.
//
// Design: docs/superpowers/specs/2026-05-11-permissions-section-design.md
//
// Layout (matches the assembled mockup):
//   [ icon ] [ title / subtitle ] [ flexible spacer ] [ status pill ] [ button ]
//
// The pill carries the at-a-glance state (green ✓ Granted / amber ⚠ Required
// / grey Off / grey Manual). The button label and primary-vs-secondary
// styling adapts per row and state — set by the caller via
// PermissionDescriptor.

import SwiftUI

/// All copy and behavior for one permission row. The descriptor is
/// the integration point — Settings and the wizard build descriptors
/// from the same PermissionsModel snapshot, so the two surfaces
/// behave identically by construction.
struct PermissionDescriptor {
    /// SF Symbol name (e.g. "mic", "accessibility", "arrow.right.circle").
    let icon: String
    let title: String
    let subtitle: String
    /// Pill copy. Caller knows whether this row is Microphone vs Open
    /// at Login etc. and picks the right phrasing ("Required" vs "Off"
    /// vs "Manual" vs "Granted" / "On").
    let pillLabel: String
    /// Visual treatment of the pill — drives the background + text
    /// colors. `.granted` = green, `.attention` = amber, `.neutral`
    /// = grey.
    let pillStyle: PillStyle
    /// Button copy. When nil, no button is rendered (rare — used only
    /// if a future state has no actionable affordance).
    let actionLabel: String?
    /// When true, the action button is rendered disabled (still
    /// visible — preserves layout — but unclickable). Used for the
    /// "Manage…" affordance on granted rows.
    let actionDisabled: Bool
    /// When true, the action button is rendered in primary (amber)
    /// style. Otherwise standard secondary.
    let actionPrimary: Bool
    let onAction: () -> Void

    enum PillStyle {
        case granted   // green
        case attention // amber
        case neutral   // grey
    }
}

struct PermissionRow: View {
    let descriptor: PermissionDescriptor

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: descriptor.icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(descriptor.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            PermissionPill(label: descriptor.pillLabel, style: descriptor.pillStyle)

            if let actionLabel = descriptor.actionLabel {
                Button(action: descriptor.onAction) {
                    Text(actionLabel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(descriptor.actionPrimary ? .orange : nil)
                .disabled(descriptor.actionDisabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}

/// The status pill. Three visual styles map to the three row states.
/// Kept private to this file — no other component renders pills.
private struct PermissionPill: View {
    let label: String
    let style: PermissionDescriptor.PillStyle

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous).fill(backgroundColor)
            )
            .foregroundStyle(foregroundColor)
    }

    private var backgroundColor: Color {
        // System semantic .green / .orange tinted at low opacity. They
        // adapt for dark mode automatically (macOS shifts both colors
        // and how opacity composes on top of the dark window chrome),
        // so the pill stays legible in both appearances without
        // hand-rolled dynamic providers per channel.
        switch style {
        case .granted:   return Color.green.opacity(0.18)
        case .attention: return Color.orange.opacity(0.18)
        case .neutral:   return Color(NSColor.quaternaryLabelColor).opacity(0.5)
        }
    }

    private var foregroundColor: Color {
        // System .green / .orange darkened/brightened by the system
        // for the current appearance — they render with enough
        // contrast on the matching low-opacity background in both
        // light and dark modes.
        switch style {
        case .granted:   return Color.green
        case .attention: return Color.orange
        case .neutral:   return Color(NSColor.secondaryLabelColor)
        }
    }
}

// MARK: - Descriptor builders

/// Builds a Microphone descriptor from the current state. The action
/// is bound to `Permissions.requestMicrophone`.
@MainActor
func microphoneDescriptor(state: PermissionState) -> PermissionDescriptor {
    switch state {
    case .granted:
        return PermissionDescriptor(
            icon: "mic",
            title: "Microphone",
            subtitle: "Required to capture your speech.",
            pillLabel: "✓ Granted",
            pillStyle: .granted,
            actionLabel: "Manage…",
            actionDisabled: true,
            actionPrimary: false,
            onAction: {}
        )
    case .missing:
        return PermissionDescriptor(
            icon: "mic",
            title: "Microphone",
            subtitle: "Required to capture your speech.",
            pillLabel: "⚠ Required",
            pillStyle: .attention,
            actionLabel: "Allow…",
            actionDisabled: false,
            actionPrimary: true,
            onAction: { Permissions.requestMicrophone() }
        )
    case .notSupported:
        // Microphone can't reach .notSupported via Permissions.microphone
        // today — it only emits .granted or .missing. The handler exists
        // for exhaustiveness, and degrades to an inert row that opens
        // System Settings rather than silently mis-firing requestAccess
        // on an environment where TCC isn't available.
        return PermissionDescriptor(
            icon: "mic",
            title: "Microphone",
            subtitle: "Manage in System Settings → Privacy & Security → Microphone.",
            pillLabel: "Manual",
            pillStyle: .neutral,
            actionLabel: "Open System Settings…",
            actionDisabled: false,
            actionPrimary: false,
            onAction: { Permissions.requestMicrophone() }
        )
    }
}

@MainActor
func accessibilityDescriptor(state: PermissionState) -> PermissionDescriptor {
    switch state {
    case .granted:
        return PermissionDescriptor(
            icon: "accessibility",
            title: "Accessibility",
            subtitle: "Reads the focused app and synthesizes the paste keystroke — never reads your screen.",
            pillLabel: "✓ Granted",
            pillStyle: .granted,
            actionLabel: "Manage…",
            actionDisabled: true,
            actionPrimary: false,
            onAction: {}
        )
    case .missing:
        return PermissionDescriptor(
            icon: "accessibility",
            title: "Accessibility",
            subtitle: "Reads the focused app and synthesizes the paste keystroke — never reads your screen.",
            pillLabel: "⚠ Required",
            pillStyle: .attention,
            actionLabel: "Allow…",
            actionDisabled: false,
            actionPrimary: true,
            onAction: { Permissions.requestAccessibility() }
        )
    case .notSupported:
        // Same reasoning as microphone's .notSupported branch.
        return PermissionDescriptor(
            icon: "accessibility",
            title: "Accessibility",
            subtitle: "Manage in System Settings → Privacy & Security → Accessibility.",
            pillLabel: "Manual",
            pillStyle: .neutral,
            actionLabel: "Open System Settings…",
            actionDisabled: false,
            actionPrimary: false,
            onAction: { Permissions.requestAccessibility() }
        )
    }
}

@MainActor
func openAtLoginDescriptor(state: PermissionState) -> PermissionDescriptor {
    switch state {
    case .granted:
        return PermissionDescriptor(
            icon: "arrow.right.circle",
            title: "Open at Login",
            subtitle: "Launch Parleq automatically when you log in.",
            pillLabel: "On",
            pillStyle: .granted,
            actionLabel: "Turn off",
            actionDisabled: false,
            actionPrimary: false,
            onAction: { Permissions.toggleOpenAtLogin() }
        )
    case .missing:
        return PermissionDescriptor(
            icon: "arrow.right.circle",
            title: "Open at Login",
            subtitle: "Launch Parleq automatically when you log in.",
            pillLabel: "Off",
            pillStyle: .neutral,
            actionLabel: "Turn on",
            actionDisabled: false,
            actionPrimary: false,
            onAction: { Permissions.toggleOpenAtLogin() }
        )
    case .notSupported:
        return PermissionDescriptor(
            icon: "arrow.right.circle",
            title: "Open at Login",
            subtitle: "This build can't auto-register. Add Parleq manually in System Settings.",
            pillLabel: "Manual",
            pillStyle: .neutral,
            actionLabel: "Open Login Items Settings…",
            actionDisabled: false,
            actionPrimary: false,
            onAction: { Permissions.toggleOpenAtLogin() }
        )
    }
}
