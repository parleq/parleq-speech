// PresetsSettingsView — the "Presets" Settings pane. Manages the user's
// transform presets (name + prompt) and per-app default assignments.
// A preset's prompt is a GENERALIZED instruction reusable on any text
// ("Rewrite the text to be as concise as possible…"), not tied to one
// dictation. Tapping a chip in the overlay runs it as a refine pass;
// an app default folds it into that app's cleanup (see the spec).

import SwiftUI

@MainActor
struct PresetsSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Presets")
                    .font(.title2).bold()
                Text("One-tap transforms for the review overlay. Each preset is a short instruction applied to your dictation before you insert it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                presetList

                Button {
                    model.transformPresets.append(
                        TransformPreset(name: "", prompt: ""))
                    model.save()
                } label: {
                    Label("Add preset", systemImage: "plus")
                }

                appDefaultsSection
            }
            .padding()
        }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($model.transformPresets) { $preset in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name (chip label)", text: $preset.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                            .onChange(of: preset.name) { _, _ in model.save() }
                        Spacer()
                        Button(role: .destructive) {
                            model.transformPresets.removeAll { $0.id == preset.id }
                            model.save()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Delete preset")
                    }
                    TextField("Instruction, e.g. \"Rewrite the text to be as concise as possible while preserving all key information.\"",
                              text: $preset.prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .onChange(of: preset.prompt) { _, _ in model.save() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(SettingsView.cardBackground))
            }
            if model.transformPresets.isEmpty {
                Text("No presets yet. Add one to get a one-tap transform chip in the review overlay.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // Per-app default mapping lands in the next task.
    private var appDefaultsSection: some View { EmptyView() }
}
