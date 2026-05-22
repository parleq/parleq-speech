// ModelBadge — clickable badge in the overlay header showing the
// currently-selected model. Click opens a popover with the
// ModelPicker. Renders a small red-dot warning indicator when a
// ModelConflict is present (image-mode references attached to a
// non-vision model).

import SwiftUI

struct ModelBadge: View {
    let currentModel: ModelIdentifier
    let conflict: ModelConflict?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: providerSymbol(for: currentModel.provider))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(currentModel.displayShort)
                    .font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(alignment: .topTrailing) {
                if conflict != nil {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tooltipText)
        .accessibilityLabel(accessibilityText)
    }

    private var tooltipText: String {
        if case .visionRefsButNonVisionModel(let n) = conflict {
            return "Selected model can't see images. \(n) reference\(n == 1 ? "" : "s") will be sent as text."
        }
        return "Click to change model"
    }

    private var accessibilityText: String {
        if conflict != nil {
            return "Model: \(currentModel.displayShort) — conflict warning"
        }
        return "Model: \(currentModel.displayShort) — tap to change"
    }

    private func providerSymbol(for provider: String) -> String {
        switch provider.lowercased() {
        case "gemini", "vertex": return "g.circle"
        case "bedrock", "bedrock-bearer": return "a.circle"
        case "azure": return "o.circle"
        default: return "cpu"
        }
    }
}
