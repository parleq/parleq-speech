// ReferenceChip — SwiftUI view rendering a single reference as a
// chip in the overlay's reference strip.
//
// Layout: app icon (16×16) + truncated label + × remove button.
// Hover state reveals the × button; otherwise the chip shows just
// the icon + label. Thumbnail preview is deferred to Phase 2 (it
// would require a popover; the chip itself stays compact).

import SwiftUI

struct ReferenceChip: View {
    let reference: Reference
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon = reference.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "doc")
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }

            Text(reference.label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)

            // Always present (stable accessibility tree + no neighbor
            // reflow); only fade visually on hover.
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("Remove reference \(reference.label)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
        )
        .onHover { hovering = $0 }
    }
}

#if DEBUG
#Preview("Single chip") {
    ReferenceChip(reference: .sampleWindow, onRemove: {})
        .padding()
}

#Preview("Strip") {
    HStack(spacing: 8) {
        ReferenceChip(reference: .sampleWindow, onRemove: {})
        ReferenceChip(reference: .sampleSpec, onRemove: {})
    }
    .padding()
}
#endif
