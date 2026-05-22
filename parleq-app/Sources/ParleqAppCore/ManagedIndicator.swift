// ManagedIndicator — reusable lock-icon affordance for MDM-managed controls.
//
// Whenever a Settings control is locked by MDM, render a small lock icon
// next to it so users understand _why_ the control won't respond. Without
// the indicator, a disabled Toggle or Picker with no explanation creates
// confusion ("is this a bug?"). The indicator also pairs with `.disabled()`
// on the control itself — the lock makes the constraint explicit and
// short-circuits support tickets.
//
// Usage:
//
//   HStack {
//       Toggle("Reference Windows", isOn: $referenceWindowsEnabled)
//           .disabled(managedKeys.contains("referenceWindowsEnabled"))
//       ManagedIndicator(isManaged: managedKeys.contains("referenceWindowsEnabled"))
//   }
//
// For picker rows where the caption helps clarify the restriction, add
// a ManagedCaption below the control as well.
//
// Phase 2 also replaces UpdatesView's ad-hoc "Managed by your organization"
// text with this component so the lock affordance is consistent everywhere.

import SwiftUI

/// A small `lock.fill` SF Symbol indicator shown next to Settings
/// controls when their key is managed by MDM. Hidden when `isManaged`
/// is false — use it unconditionally next to every eligible control and
/// let this view decide whether to show or hide.
///
/// A `.help("Managed by your organization")` tooltip fires on hover so
/// users can discover the meaning without reading docs.
public struct ManagedIndicator: View {
    public let isManaged: Bool

    public init(isManaged: Bool) {
        self.isManaged = isManaged
    }

    public var body: some View {
        if isManaged {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Managed by your organization")
                .accessibilityLabel("Managed by your organization")
        }
    }
}

/// An optional inline caption that reads "Managed by your organization."
/// Use beneath pickers and text fields (where the single lock icon can
/// be hard to spot); toggle rows usually don't need it since `.disabled`
/// + the lock icon together make the constraint obvious. Keep hidden when
/// not managed so it doesn't occupy layout space.
public struct ManagedCaption: View {
    public let isManaged: Bool

    public init(isManaged: Bool) {
        self.isManaged = isManaged
    }

    public var body: some View {
        if isManaged {
            Text("Managed by your organization.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
