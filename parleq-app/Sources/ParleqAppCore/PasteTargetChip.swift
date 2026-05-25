// PasteDestination + PastingToLabel — the UI-side description of the
// paste target and the reusable view that renders it as the canonical
// "PASTING TO <App>" eyebrow + icon + name treatment seen in the
// .awaitingAccept footer.
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

/// Canonical paste-target indicator: small-caps "PASTING TO" eyebrow,
/// the destination app's icon, and its name (plus window title when
/// available). Originally lived inline as a private helper inside
/// OverlayButtons (.awaitingAccept footer); extracted so the same
/// visual treatment can render in the .capturing / .cleaning /
/// .refining footers — the user benefits from seeing the live paste
/// target BEFORE Accept so latched-compose flows that inadvertently
/// shift focus (e.g. clicking an Add-from-clipboard button that
/// activates a different app) make the change visible immediately
/// instead of waiting for the streamed text to appear.
struct PastingToLabel: View {
    let target: PasteDestination

    var body: some View {
        HStack(spacing: 6) {
            // Small-caps + tracked-out treatment for the "PASTING
            // TO" label. Reads as a typographic eyebrow rather than
            // running prose, which lets the app name (rendered at
            // normal weight + primary color) take visual priority.
            Text("PASTING TO")
                .font(.system(size: 9, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            if let icon = target.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
            }
            Text(displayText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                // .leading alignment: without it the frame centers
                // its content inside the 220pt box, leaving a gap
                // between the app icon and short names like
                // "iTerm2". Anchoring leading keeps the text snug
                // against the icon regardless of length; truncation
                // still kicks in for long window titles.
                .frame(maxWidth: 220, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Will paste into \(displayText)")
    }

    private var displayText: String {
        if let title = target.windowTitle, !title.isEmpty {
            return "\(target.appName) — \(title)"
        }
        return target.appName
    }
}

#if DEBUG
#Preview {
    PastingToLabel(target: PasteDestination(
        bundleID: "com.tinyspeck.slackmacgap",
        appName: "Slack",
        windowTitle: "#design-feedback",
        appIcon: NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.tinyspeck.slackmacgap")
            .flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
    ))
    .padding()
}
#endif
