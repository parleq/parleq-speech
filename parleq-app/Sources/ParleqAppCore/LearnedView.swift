// LearnedView — the "Learned" section of the Parleq app window. Surfaces
// "learn from corrections" output in two tiers: actionable PENDING
// suggestions at the top (term + preset suggestions, plus usage-derived
// per-app-default suggestions), and a unified "Recent activity" history
// below — every accept/dismiss/revert/restore as a kept, outcome-marked
// row. Dismissed rows offer Restore (recovers a misclick); accepted rows
// offer Revert; reverted/restored rows stay visible (anti-vanish). When
// there are no pending items, a one-line tally recaps what's been learned
// so accepting the last suggestion doesn't snap back to "Nothing learned
// yet". The empty state shows ONLY when both pending and history are
// empty. Empty + feature-off states explain what the section is for.

import SwiftUI

@MainActor
struct LearnedView: View {
    @ObservedObject var store: LearnedStore
    /// Clears the in-memory correction ring. Passed as a closure rather than
    /// observing CorrectionJournal: the view displays no journal data (only
    /// store.pendingSuggestions / appliedChanges), and the journal's
    /// @Published records fire on every dictation — observing it would
    /// re-render this view on each dictation for no visible reason.
    let clearJournal: () -> Void

    var body: some View {
        // Read the config flags ONCE per body so all branches see the same
        // values (no mid-render disk re-read or skew).
        let config = Config.load().config
        let featureEnabled = config.learnFromCorrectionsEnabled
        // Read once here (not per PresetSuggestionRow) and thread down; the
        // body re-renders on store changes, so an MDM pin that toggles
        // presets is still reflected on the next render.
        let presetsEnabled = config.transformPresetsEnabled
        // Bridge 2 suggestions are gated on transformPresetsEnabled ONLY —
        // they surface even when learn-from-corrections is off, since the
        // usage journal is independent metadata, not the correction ring.
        let hasUsageSuggestions = !store.presetDefaultSuggestions.isEmpty
        // Pending = the actionable items at the top (term + preset
        // suggestions, gated on the feature, plus usage-derived app-default
        // suggestions which are independent of it).
        let hasPending = hasUsageSuggestions
            || (featureEnabled && !store.pendingSuggestions.isEmpty)
        // History = the unified Recent Activity ring (independent of the
        // feature flag: it can hold app-default outcomes too).
        let hasHistory = !store.activityLog.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            header(featureEnabled: featureEnabled, hasHistory: hasHistory)
            if !featureEnabled && !hasUsageSuggestions && !hasHistory {
                // No correction-derived content allowed, no usage
                // suggestions, and no history — show the off explainer.
                disabledState
            } else if !hasPending && !hasHistory {
                // Empty ONLY when both pending AND history are empty.
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if hasUsageSuggestions { presetDefaultSuggestionsSection }
                        if featureEnabled && !store.pendingSuggestions.isEmpty {
                            suggestionsSection(presetsEnabled: presetsEnabled)
                        }
                        if hasHistory { activitySection(hasPending: hasPending) }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { store.refreshPresetDefaultSuggestions() }
    }

    private func header(featureEnabled: Bool, hasHistory: Bool) -> some View {
        HStack {
            Text("Learned").font(.title2).bold()
            Spacer()
            if !store.pendingSuggestions.isEmpty || hasHistory {
                // Clear the suggestions/activity log AND the in-memory
                // correction ring — otherwise leftover correction records
                // could feed a later analysis run after the user cleared.
                Button("Clear all") {
                    store.clearAll()
                    clearJournal()
                }
                .accessibilityLabel("Clear all learned activity")
            }
        }
        .padding()
    }

    private var disabledState: some View {
        VStack(spacing: 8) {
            Image(systemName: "lightbulb").font(.largeTitle).foregroundStyle(.secondary)
            Text("Learning from corrections is off").font(.headline)
            Text("Turn it on in Settings → Privacy & Features to let Parleq suggest dictionary and style improvements from your corrections.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "lightbulb").font(.largeTitle).foregroundStyle(.secondary)
            Text("Nothing learned yet").font(.headline)
            Text("As you correct dictations — spelling names out loud or refining text by voice — Parleq will occasionally suggest improvements here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestionsSection(presetsEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggestions").font(.headline)
            ForEach(store.pendingSuggestions) { s in
                if s.proposal.kind == .preset {
                    PresetSuggestionRow(store: store, suggestion: s, presetsEnabled: presetsEnabled)
                } else {
                    termSuggestionRow(s)
                }
            }
        }
    }

    @ViewBuilder
    private func termSuggestionRow(_ s: LearnedStore.PendingSuggestion) -> some View {
        let isRetire = s.proposal.op == .retire
        Group {
            HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(operationLabel(s.proposal.op))
                                .font(.caption2).bold()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill((isRetire ? Color.red : Color.accentColor).opacity(0.18)))
                                .foregroundStyle(isRetire ? Color.red : Color.accentColor)
                            Text(s.term ?? "Style preference").bold()
                        }
                        Text(s.rationale).font(.callout).foregroundStyle(.secondary)
                        if let aliases = s.proposal.aliases, !aliases.isEmpty {
                            Text("Also hears: \(aliases.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !isRetire, let prior = s.priorAliases, !prior.isEmpty {
                            Text("Keeps existing: \(prior.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let ctx = s.proposal.context, !ctx.isEmpty {
                            Text("Context: \(ctx)").font(.caption).foregroundStyle(.secondary)
                        }
                        if isRetire {
                            Text("Removes this term from your dictionary.")
                                .font(.caption).foregroundStyle(Color.red)
                        }
                    }
                    Spacer()
                    Button(isRetire ? "Retire" : "Accept") { store.accept(id: s.id) }
                        .accessibilityLabel("\(isRetire ? "Retire" : "Accept") \(s.term ?? "suggestion")")
                    Button("Dismiss") { store.dismiss(id: s.id) }
                        .accessibilityLabel("Dismiss \(s.term ?? "suggestion")")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
    }

    private func operationLabel(_ op: LearningProposal.Op) -> String {
        switch op {
        case .add: return "ADD"
        case .modify: return "MODIFY"
        case .merge: return "MERGE"
        case .retire: return "RETIRE"
        }
    }

    /// Bridge 2: per-app default suggestions from preset usage. Honest
    /// provenance ("From your preset usage") to distinguish from the
    /// refine-pattern presets above.
    private var presetDefaultSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggested app defaults").font(.headline)
            ForEach(store.presetDefaultSuggestions) { s in
                let appName = LearnedStore.appDisplayName(s.appBundleID)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("DEFAULT")
                                .font(.caption2).bold()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18)))
                                .foregroundStyle(Color.accentColor)
                            Text("From your preset usage")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Make \"\(s.presetName)\" the default for \(appName)?").bold()
                        Text("You've applied it \(s.manualUses) times there. Setting it as the default styles dictations automatically (with one-tap Undo).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Set default") { store.acceptPresetDefault(s) }
                        .accessibilityLabel("Set \(s.presetName) as default for \(appName)")
                    Button("Dismiss") { store.dismissPresetDefault(s) }
                        .accessibilityLabel("Dismiss app-default suggestion for \(appName)")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    /// Unified "Recent activity" history below the actionable pending
    /// suggestions. Every accept/dismiss/revert/restore lands here, newest
    /// first. Dismissed rows offer Restore; accepted rows offer Revert;
    /// reverted/restored rows are terminal (no button) but stay visible
    /// (anti-vanish). When there are no pending items, a one-line tally
    /// recaps what's been learned so the screen doesn't look empty.
    private func activitySection(hasPending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent activity").font(.headline)
            if !hasPending {
                let tally = LearnedStore.tally(store.activityLog)
                if !tally.isEmpty {
                    Text(tally)
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityLabel("Summary: \(tally)")
                }
            }
            ForEach(store.activityLog) { e in
                activityRow(e)
            }
        }
    }

    @ViewBuilder
    private func activityRow(_ e: ActivityEntry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.summary).bold()
                    .foregroundStyle(outcomeIsTerminal(e.outcome) ? Color.secondary : Color.primary)
            }
            Spacer()
            switch e.outcome {
            case .accepted:
                // Plain labels here: the row uses
                // `.accessibilityElement(children: .combine)`, which folds the
                // summary Text into the announcement, so a richer button label
                // would read the summary twice.
                Button("Revert") { store.revertActivity(id: e.id) }
            case .dismissed:
                Button("Restore") { store.restore(id: e.id) }
            case .reverted, .restored:
                EmptyView()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    private func outcomeIsTerminal(_ o: ActivityEntry.Outcome) -> Bool {
        o == .reverted || o == .restored
    }
}

/// A pending PRESET suggestion (Bridge 1). The proposed name + prompt are
/// EDITABLE inline before the user accepts — accepting creates a
/// TransformPreset in config. Provenance copy ("From your refine
/// patterns") keeps it honest about where the suggestion came from.
@MainActor
private struct PresetSuggestionRow: View {
    @ObservedObject var store: LearnedStore
    let suggestion: LearnedStore.PendingSuggestion
    /// Read once by LearnedView.body and threaded in (not re-read per row)
    /// — the parent re-renders on store changes, so an MDM pin that toggles
    /// presets is still reflected on the next render.
    let presetsEnabled: Bool

    @State private var name: String = ""
    @State private var prompt: String = ""
    @State private var didInit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("PRESET")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
                Text("From your refine patterns")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(suggestion.rationale).font(.callout).foregroundStyle(.secondary)
            TextField("Name (chip label)", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            TextField("Instruction", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            HStack {
                if !presetsEnabled {
                    Text("Presets disabled by policy")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Create preset") {
                    store.acceptPreset(id: suggestion.id, name: name, prompt: prompt)
                }
                .disabled(!presetsEnabled
                          || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Create preset \(name)")
                Button("Dismiss") { store.dismiss(id: suggestion.id) }
                    .accessibilityLabel("Dismiss preset suggestion \(name)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .onAppear {
            // Seed the editable fields once from the proposal; don't clobber
            // the user's edits on later re-renders.
            guard !didInit else { return }
            name = suggestion.proposal.presetName ?? ""
            prompt = suggestion.proposal.presetPrompt ?? ""
            didInit = true
        }
    }
}
