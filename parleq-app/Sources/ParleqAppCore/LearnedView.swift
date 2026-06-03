// LearnedView — the "Learned" section of the Parleq app window. Surfaces
// "learn from corrections" output: pending suggestions the user can
// Accept/Dismiss, a log of auto-applied dictionary changes the user can
// Revert, and a manage/clear footer. Empty + feature-off states explain
// what the section is for.

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
        // Read the config flag ONCE per body so both branches below and the
        // header see the same value (no mid-render disk re-read or skew).
        let featureEnabled = Config.load().config.learnFromCorrectionsEnabled
        return VStack(alignment: .leading, spacing: 0) {
            header(featureEnabled: featureEnabled)
            if !featureEnabled {
                disabledState
            } else if store.pendingSuggestions.isEmpty && store.appliedChanges.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !store.pendingSuggestions.isEmpty { suggestionsSection }
                        if !store.appliedChanges.isEmpty { appliedSection }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(featureEnabled: Bool) -> some View {
        HStack {
            Text("Learned").font(.title2).bold()
            Spacer()
            if featureEnabled && (!store.pendingSuggestions.isEmpty || !store.appliedChanges.isEmpty) {
                // Clear both the suggestions/applied log AND the in-memory
                // correction ring — otherwise leftover correction records
                // could feed a later analysis run after the user cleared.
                Button("Clear all") {
                    store.clearAll()
                    clearJournal()
                }
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

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggestions").font(.headline)
            ForEach(store.pendingSuggestions) { s in
                let isRetire = s.proposal.op == .retire
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
                    Button("Dismiss") { store.dismiss(id: s.id) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
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

    private var appliedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Applied changes").font(.headline)
            ForEach(store.appliedChanges) { c in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.term).bold()
                        Text(c.rationale).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revert") { store.revert(id: c.id) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
            }
        }
    }
}
