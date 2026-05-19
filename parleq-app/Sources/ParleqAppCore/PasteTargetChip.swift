// PasteTargetChip — SwiftUI view rendering the currently-tracked
// paste destination at the top of the overlay. Reads from the
// overlay model and renders the destination app's icon + name +
// (optional) window title.
//
// When no target is known (e.g., the only frontmost app is Parleq
// itself), renders a "Paste target: none" placeholder.
//
// `PasteDestination` is the UI-side description of the paste target.
// `Paster.PasteTarget` (in Paster.swift) is a separate Sendable struct
// used by the execution path — it carries pid + bundleID needed for
// the actual Cmd-V dispatch. We don't reuse it here because adding
// NSImage/windowTitle would break its Sendable conformance, which
// matters for the async paste pipeline.

import AppKit
import SwiftUI

struct PasteDestination: Equatable {
    let bundleID: String
    let appName: String
    let windowTitle: String?
    let appIcon: NSImage?

    static func == (lhs: PasteDestination, rhs: PasteDestination) -> Bool {
        lhs.bundleID == rhs.bundleID
            && lhs.appName == rhs.appName
            && lhs.windowTitle == rhs.windowTitle
            // Use object identity for the icon — if the same NSImage
            // is passed through, equality holds; if the producer
            // resolves a previously-nil icon to a real value, the
            // identity changes and SwiftUI repaints. This avoids the
            // "icon never appears" race when bundleID/appName/title
            // are stable but the icon resolves asynchronously.
            && lhs.appIcon === rhs.appIcon
    }
}

struct PasteTargetChip: View {
    let target: PasteDestination?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right.to.line")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if let target = target {
                if let icon = target.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                }
                Text(displayText(for: target))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 280)
            } else {
                Text("No paste target")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.10))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(for: target))
    }

    private func displayText(for target: PasteDestination) -> String {
        if let title = target.windowTitle, !title.isEmpty {
            return "\(target.appName) — \(title)"
        }
        return target.appName
    }

    private func accessibilityText(for target: PasteDestination?) -> String {
        guard let target = target else { return "No paste target" }
        return "Pastes to \(displayText(for: target))"
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 8) {
        PasteTargetChip(target: PasteDestination(
            bundleID: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            windowTitle: "#design-feedback",
            appIcon: NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: "com.tinyspeck.slackmacgap")
                .flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
        ))
        PasteTargetChip(target: nil)
    }
    .padding()
}
#endif
