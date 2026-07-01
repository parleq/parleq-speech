// PresetsSettingsView — the "Presets" Settings pane. Manages the user's
// transform presets (name + prompt) and per-app behavior assignments.
// A preset's prompt is a GENERALIZED instruction reusable on any text
// ("Rewrite the text to be as concise as possible…"), not tied to one
// dictation. Tapping a chip in the overlay runs it as a refine pass;
// an app default folds it into that app's cleanup (see the spec).

import SwiftUI

@MainActor
struct PresetsSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var newPresetID: String = ""
    /// Apps added via "Add app" this session but not yet explicitly configured.
    @State private var addedApps: Set<String> = []

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

    // MARK: - App behavior section

    private var appDefaultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let presetsEnabled = model.transformPresetsEnabled
            let bundleIDs = allBehaviorBundleIDs

            Text("App behavior")
                .font(.headline)
                .padding(.top, 8)

            (Text("Parleq adapts cleanup to each app. Terminals, code editors, and spreadsheets default to ")
             + Text("Instant").bold()
             + Text(" (fast, on-device, literal); everything else to ")
             + Text("Polished").bold()
             + Text(" (your configured cleanup). Add an app to customize."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(bundleIDs, id: \.self) { bundleID in
                appBehaviorRow(bundleID: bundleID, presetsEnabled: presetsEnabled)
            }

            appAddMenu(excluding: Set(bundleIDs))
        }
    }

    // MARK: - Per-app row

    @ViewBuilder
    private func appBehaviorRow(bundleID: String, presetsEnabled: Bool) -> some View {
        let effective = effectiveMode(for: bundleID)
        let hasExplicitOverride = model.appBehaviors[bundleID] != nil
        let curatedDefault = CuratedAppDefaults.mode(for: bundleID)
        let icon = appIcon(for: bundleID)
        let displayName = resolvedAppName(for: bundleID)

        VStack(alignment: .leading, spacing: 8) {
            // ── Top row: icon + name + reset button ──
            HStack(spacing: 8) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .cornerRadius(4)
                } else {
                    Image(systemName: "app.dashed")
                        .frame(width: 20, height: 20)
                        .foregroundStyle(.secondary)
                }

                Text(displayName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                // Reset/remove — removes mode override, preset mapping, and
                // session-local addedApps entry. Records a decline if a
                // preset was mapped so the dominance suggester doesn't re-nag.
                Button(role: .destructive) {
                    if let presetID = model.presetAppDefaults[bundleID] {
                        PresetUsageJournal.shared.recordDecline(
                            appBundleID: bundleID, presetID: presetID)
                    }
                    model.appBehaviors.removeValue(forKey: bundleID)
                    model.presetAppDefaults.removeValue(forKey: bundleID)
                    addedApps.remove(bundleID)
                    model.save()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Reset behavior for \(displayName)")
            }

            // ── Mode segmented control ──
            HStack(alignment: .center, spacing: 8) {
                Picker("Mode", selection: modeBinding(for: bundleID)) {
                    Text("Instant").tag(TargetMode.instant)
                    Text("Polished").tag(TargetMode.polished)
                    Text("Raw").tag(TargetMode.raw)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                // Show "Default: X" caption when mode is inherited
                if !hasExplicitOverride, let curated = curatedDefault {
                    Text("Default: \(curated.displayLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // ── Per-mode controls ──
            switch effective {
            case .polished:
                if presetsEnabled {
                    HStack(alignment: .center, spacing: 8) {
                        // Tone/preset dropdown
                        Picker("", selection: presetBinding(for: bundleID)) {
                            Text("No preset (tone)").tag("")
                            ForEach(mappablePresets) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)

                        // Suggestion chip — only when no preset is set and there
                        // is a curated tone for this app
                        if model.presetAppDefaults[bundleID] == nil,
                           let tone = CuratedAppDefaults.suggestedTone(for: bundleID) {
                            Button {
                                acceptSuggestedTone(tone, for: bundleID)
                            } label: {
                                Label(
                                    tone == .friendlyConcise
                                        ? "Suggest: Friendly & concise"
                                        : "Suggest: Professional",
                                    systemImage: "sparkles"
                                )
                                .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(SettingsView.brandAccent)
                        }
                    }
                }
            case .instant:
                Text("On-device, literal — no styling")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .raw:
                Text("Pasted as transcribed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(SettingsView.cardBackground))
    }

    // MARK: - "Add app" affordance

    private func appAddMenu(excluding existing: Set<String>) -> some View {
        Menu {
            // Enumerate running apps + load their icons LAZILY, inside the menu
            // content, so editing a preset (which re-renders this pane on every
            // keystroke via model.save()) doesn't rescan every running app and
            // load its icon each render.
            let candidates = runningUserApps.filter { !existing.contains($0.bundleID) }
            if candidates.isEmpty {
                Text("No other apps running")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates, id: \.bundleID) { app in
                    Button {
                        addedApps.insert(app.bundleID)
                    } label: {
                        if let icon = app.icon {
                            Label {
                                Text(app.name)
                            } icon: {
                                Image(nsImage: icon)
                                    .resizable()
                            }
                        } else {
                            Text(app.name)
                        }
                    }
                }
            }
        } label: {
            Label("Add app", systemImage: "plus")
        }
    }

    // MARK: - Helpers

    /// Sorted union of all bundle IDs with an explicit mode override,
    /// an explicit preset mapping, or a session-local "just added" entry.
    private var allBehaviorBundleIDs: [String] {
        var ids = Set(model.appBehaviors.keys)
        ids.formUnion(model.presetAppDefaults.keys)
        ids.formUnion(addedApps)
        return ids.sorted()
    }

    private func effectiveMode(for bundleID: String) -> TargetMode {
        model.appBehaviors[bundleID]?.mode
            ?? CuratedAppDefaults.mode(for: bundleID)
            ?? .polished
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func resolvedAppName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName")
                        as? String)
                ?? (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName")
                    as? String)
                ?? url.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        return LearnedStore.appDisplayName(bundleID)
    }

    /// A binding over `appBehaviors[bundleID].mode` that:
    /// • removes the override when the new mode matches the curated/Polished
    ///   default AND no preset is mapped (restores the inherited state), and
    /// • sets an explicit AppBehavior(mode:) override otherwise.
    private func modeBinding(for bundleID: String) -> Binding<TargetMode> {
        Binding(
            get: { self.effectiveMode(for: bundleID) },
            set: { newMode in
                let resolvedDefault = CuratedAppDefaults.mode(for: bundleID) ?? .polished
                let hasPreset = self.model.presetAppDefaults[bundleID] != nil
                if newMode == resolvedDefault && !hasPreset {
                    self.model.appBehaviors.removeValue(forKey: bundleID)
                } else {
                    self.model.appBehaviors[bundleID] = AppBehavior(mode: newMode)
                }
                self.model.save()
            }
        )
    }

    /// A binding over `presetAppDefaults[bundleID]` (empty string = none).
    private func presetBinding(for bundleID: String) -> Binding<String> {
        Binding(
            get: { self.model.presetAppDefaults[bundleID] ?? "" },
            set: { newID in
                let trimmed = newID.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.model.presetAppDefaults.removeValue(forKey: bundleID)
                } else {
                    self.model.presetAppDefaults[bundleID] = trimmed
                }
                self.model.save()
            }
        )
    }

    /// Finds or creates the preset for a suggested tone, then assigns it to bundleID.
    private func acceptSuggestedTone(_ tone: SuggestedTone, for bundleID: String) {
        let name: String
        let prompt: String
        switch tone {
        case .friendlyConcise:
            name = "Friendly & concise"
            prompt = "Rewrite the text in a friendly, concise tone while preserving all key information and any technical terms. Keep it natural and easy to read; do not add new content."
        case .professional:
            name = "Professional"
            prompt = "Rewrite the text in a clear, professional tone suitable for workplace communication, preserving all key information and any technical terms; do not add new content."
        }
        // Reuse an existing preset with that exact name, or create a new one.
        let presetID: String
        if let existing = model.transformPresets.first(where: { $0.name == name }) {
            presetID = existing.id
        } else {
            let newPreset = TransformPreset(name: name, prompt: prompt)
            model.transformPresets.append(newPreset)
            presetID = newPreset.id
        }
        model.presetAppDefaults[bundleID] = presetID
        model.save()
    }

    // MARK: - Running apps enumeration for "Add app" menu

    private struct RunningAppEntry {
        let bundleID: String
        let name: String
        let icon: NSImage?
    }

    private var runningUserApps: [RunningAppEntry] {
        // Reuse WindowPicker's system-surface exclusions (single source of truth)
        // so a new macOS agent added there is filtered here too.
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAppEntry? in
                guard let bundleID = app.bundleIdentifier,
                      !bundleID.isEmpty else { return nil }
                guard !WindowPickerModel.systemBundleBlocklist.contains(bundleID) else { return nil }
                guard !WindowPickerModel.systemBundlePrefixBlocklist.contains(
                    where: { bundleID.hasPrefix($0) }) else { return nil }
                let name = app.localizedName ?? LearnedStore.appDisplayName(bundleID)
                return RunningAppEntry(bundleID: bundleID, name: name, icon: app.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - TargetMode display helpers

private extension TargetMode {
    var displayLabel: String {
        switch self {
        case .instant: return "Instant"
        case .polished: return "Polished"
        case .raw: return "Raw"
        }
    }
}
