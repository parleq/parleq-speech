// ModelPicker — popover content view shown when the user clicks the
// ModelBadge. Lists configured models grouped by provider. Each row
// shows the model name and a 👁 marker for vision-capable models so
// users can deliberately pick a vision model when attaching image
// references.
//
// Phase 2 scope: the picker shows the user's configured cleanup
// model + optional context model (deduped). Multi-provider configs
// from Settings land later.

import SwiftUI

struct ModelPicker: View {
    /// All currently configured models the picker should offer.
    /// Phase 2: typically just the cleanup model (and context model
    /// if distinct). Broader multi-provider configs land later.
    let models: [ModelEntry]
    let selectedModel: ModelIdentifier
    let onPick: (ModelIdentifier) -> Void

    /// One row in the picker. Carries the info ModelPicker needs to
    /// render and route a pick without taking a hard dependency on
    /// LLMProvider's full type (which has init/auth requirements
    /// inappropriate for a picker data source).
    ///
    /// `id` satisfies `Identifiable` using the `ModelIdentifier`
    /// itself (Equatable + Codable makes it a fine identity key).
    struct ModelEntry: Identifiable {
        /// The model identifier — also serves as the Identifiable key.
        let modelId: ModelIdentifier
        let displayName: String
        let supportsVision: Bool

        /// `Identifiable.id` delegates to `modelId` so ForEach can
        /// distinguish rows without a separate UUID.
        var id: ModelIdentifier { modelId }

        init(id: ModelIdentifier, displayName: String, supportsVision: Bool) {
            self.modelId = id
            self.displayName = displayName
            self.supportsVision = supportsVision
        }
    }

    var body: some View {
        pickerBody
            .padding(.bottom, 8)
            .frame(width: 240)
    }

    @ViewBuilder
    private var pickerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groupedByProvider, id: \.providerName) { group in
                providerSection(group)
            }
        }
    }

    @ViewBuilder
    private func providerSection(_ group: ProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.providerName.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(group.models, id: \.modelId) { entry in
                entryRow(entry)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: ModelEntry) -> some View {
        Button(action: { onPick(entry.modelId) }) {
            HStack {
                Text(entry.displayName)
                    .font(.system(size: 12))
                Spacer()
                if entry.supportsVision {
                    Text("👁").font(.system(size: 11))
                }
                if entry.modelId == selectedModel {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private struct ProviderGroup {
        let providerName: String
        let models: [ModelEntry]
    }

    private var groupedByProvider: [ProviderGroup] {
        let dict = Dictionary(grouping: models, by: { $0.modelId.provider })
        return dict.keys.sorted().map { key in
            ProviderGroup(
                providerName: key,
                models: dict[key]!.sorted { $0.displayName < $1.displayName }
            )
        }
    }
}
