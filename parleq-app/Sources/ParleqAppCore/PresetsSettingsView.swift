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
    @State private var newBundleID: String = ""
    @State private var newPresetID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("One-tap transforms for the review overlay. Each preset is a short instruction applied to your dictation before you insert it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            presetList

            Button {
                // No save() here: the blank row would be filtered from
                // disk anyway (save() drops blank presets), so the write
                // would be a no-op churn. The onChange handlers on the
                // name/prompt fields persist it once the user types.
                // Consequence (intentional): a blank row that is never
                // filled in simply vanishes on the next Settings open —
                // don't "fix" this by re-adding save().
                model.transformPresets.append(
                    TransformPreset(name: "", prompt: ""))
            } label: {
                Label("Add preset", systemImage: "plus")
            }

            appDefaultsSection
        }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($model.transformPresets) { $preset in
                // Resolve the id at row-BUILD time, not tap time. A
                // ForEach($...) element binding is positional; reading it
                // inside a button action crashes when the row is stale
                // (array already shrunk — e.g. a second delete clicked
                // before SwiftUI rebuilds after the first; verified twice
                // via crash report: Array._checkSubscript via
                // Binding.getter). A plain `let` here is evaluated while
                // the row is valid, so the action closure captures a
                // String and never touches the binding.
                let presetID = preset.id
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name (chip label)", text: $preset.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                            .onChange(of: preset.name) { _, _ in model.save() }
                        Spacer()
                        Button(role: .destructive) {
                            if newPresetID == presetID { newPresetID = "" }
                            model.transformPresets.removeAll { $0.id == presetID }
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

    /// Presets eligible for a NEW per-app default: only ones that will
    /// actually persist (non-blank name + prompt). Existing mappings are
    /// preserved mid-edit elsewhere; this only gates new assignments.
    private var mappablePresets: [TransformPreset] {
        model.transformPresets.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var appDefaultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Per-app defaults")
                .font(.headline)
                .padding(.top, 8)
            Text("When you dictate into one of these apps, the chosen preset is applied automatically during cleanup — the overlay shows \"Styled with …\" and a one-tap Undo.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.presetAppDefaults.sorted(by: { $0.key < $1.key }), id: \.key) { bundleID, presetID in
                HStack {
                    Text(bundleID).font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(model.transformPresets.first { $0.id == presetID }?.name ?? "(deleted preset)")
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        model.presetAppDefaults.removeValue(forKey: bundleID)
                        model.save()
                        // Bridge 2: removing a default the user previously set
                        // is a signal they DON'T want it — record the decline
                        // durably so the dominance rule never re-suggests this
                        // (app, preset) pair (treat existing-then-removed as
                        // declined). Metadata only.
                        PresetUsageJournal.shared.recordDecline(
                            appBundleID: bundleID, presetID: presetID)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove default for \(bundleID)")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(SettingsView.cardBackground))
            }

            HStack {
                TextField("App bundle ID, e.g. com.apple.mail", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $newPresetID) {
                    Text("Choose preset").tag("")
                    ForEach(mappablePresets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                Button("Add") {
                    let bundle = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !bundle.isEmpty, !newPresetID.isEmpty,
                          mappablePresets.contains(where: { $0.id == newPresetID }) else { return }
                    model.presetAppDefaults[bundle] = newPresetID
                    model.save()
                    newBundleID = ""
                    newPresetID = ""
                }
                .disabled(newBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || newPresetID.isEmpty
                          || !mappablePresets.contains(where: { $0.id == newPresetID }))
            }
        }
    }
}
