// VoiceprintEnrollmentView — the SwiftUI sheet that drives the voice-enrollment
// wizard. All logic lives in VoiceprintEnrollmentModel; this renders the phases
// and wires per-carrier record/stop to a single AudioRecorder. Matches the
// Settings/SetupWizard palette (brand amber).

#if Concord
import SwiftUI

public struct VoiceprintEnrollmentView: View {
    @ObservedObject var model: VoiceprintEnrollmentModel
    /// Cancel / back-out path — closes the wizard, returning to the edit sheet.
    let onClose: () -> Void
    /// Success path — fired once after Save enrolls. Lets the host dismiss BOTH
    /// the wizard and the edit sheet so the user lands back on the dictionary
    /// list in a single tap (no separate "Done" gate). Defaults to `onClose`.
    let onFinished: () -> Void

    @State private var recorder: AudioRecorder?
    @State private var activeRecording: (negative: Bool, index: Int)?
    @State private var micError: String?
    /// The in-flight analyze task, tracked so Cancel can abandon it. (Even if it
    /// runs to completion it only builds an in-memory draft — storage is deferred
    /// to Save — so cancelling mid-analyze can never leave a committed voiceprint.)
    @State private var analyzeTask: Task<Void, Never>?

    public init(model: VoiceprintEnrollmentModel,
                onClose: @escaping () -> Void,
                onFinished: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
        self.onFinished = onFinished ?? onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(20) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 540, height: 560)
        .task { await model.start() }
    }

    // MARK: header / footer

    private var header: some View {
        HStack {
            Image(systemName: "mic.circle.fill").foregroundColor(SettingsView.brandAccent)
            Text("Enroll “\(model.term)” by voice").font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { analyzeTask?.cancel(); model.cancel(); onClose() }
            Spacer()
            if model.isWorking { ProgressView().controlSize(.small).padding(.trailing, 8) }
            primaryButton
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.phase {
        case .intro:
            Button("Enable voice enrollment") { model.consent() }
                .keyboardShortcut(.defaultAction)
        case .carriers:
            Button("Analyze") { analyzeTask = Task { await model.analyze() } }
                .disabled(!model.carriersReady).keyboardShortcut(.defaultAction)
        case .analyzing:
            EmptyView()
        case .confusable:
            HStack {
                Button("Not confusable") { model.skipConfusable() }
                Button("Use these") { Task { await model.proceedWithNegative() } }
                    .disabled(!model.negativesReady).keyboardShortcut(.defaultAction)
            }
        case .review:
            // One decisive action: enroll, then dismiss straight to the list —
            // no separate "Done" click-gate. (The .done phase still renders its
            // confirmation card as a momentary flash while the sheet animates
            // away, but it's never a required tap.)
            Button("Save") { model.save(); onFinished() }.keyboardShortcut(.defaultAction)
        case .done:
            // Reached only if the host kept the wizard open (onFinished == onClose
            // default); otherwise this is bypassed by the Save → onFinished dismiss.
            Button("Done") { onFinished() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .intro:      introCard
        case .carriers:   carriersCard
        case .analyzing:  analyzingCard
        case .confusable: confusableCard
        case .review:     reviewCard
        case .done:       doneCard
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recognize your voice for this term").font(.title3).bold()
            Text("""
            Parleq will record a few short clips of you saying “\(model.term)” in different \
            sentences, so it can tell the term apart from similar-sounding words using your own voice.

            The recordings are processed on your device. The derived voiceprint is kept encrypted \
            on this device. By default, the enrollment audio clips are also kept encrypted on device \
            so your voiceprint can be automatically re-derived if the speech model updates — without \
            re-recording. You can turn clip storage off in Settings → Dictionary.

            This is biometric data: on-device, opt-in, and deletable anytime.
            """)
            .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var carriersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read each sentence out loud").font(.title3).bold()
            Text("Tap record, say the whole sentence naturally, then stop. Re-record any that don’t feel right.")
                .foregroundColor(.secondary).font(.callout)
            if model.analysisFailed {
                Label("Couldn’t hear the term clearly in some clips — please re-record.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.callout)
            }
            recordingList(sentences: model.carriers, recordings: model.recordings, negative: false)
            if let micError {
                Label(micError, systemImage: "mic.slash.fill").foregroundColor(.red).font(.callout)
            }
            Button {
                Task { await model.regenerateCarriers() }
            } label: { Label("Regenerate sentences", systemImage: "arrow.clockwise") }
                .buttonStyle(.link).font(.callout)
        }
    }

    private var analyzingCard: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Analyzing your recordings…").foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var confusableCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tell “\(model.term)” apart from “\(model.negativeLabel ?? "")”").font(.title3).bold()
            Text("""
            Parleq sometimes hears “\(model.term)” as “\(model.negativeLabel ?? "")”. If \
            “\(model.negativeLabel ?? "")” is also a word you say, read these so Parleq can tell \
            them apart. If not, choose “Not confusable”.
            """)
            .foregroundColor(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
            recordingList(sentences: model.negativeCarriers, recordings: model.negativeRecordings, negative: true)
        }
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enrollment ready").font(.title3).bold()
            if let o = model.outcome {
                if o.lowQuality {
                    Label("The recordings were inconsistent — enrollment may be unreliable. Consider re-recording.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                Text("Enrolled \(o.enrolledClips) clip\(o.enrolledClips == 1 ? "" : "s").")
                    .foregroundColor(.secondary)
                // Report only the alternates actually KEPT: partitionEnrolledMishears drops
                // degenerate <3-char fragments ("e"/"et") that over-match, so the raw harvest and
                // the stored result differ. Show what's stored, not what was heard.
                if case let kept = SettingsModel.partitionEnrolledMishears(o.harvestedAliases).aliases,
                   !kept.isEmpty {
                    Text("Learned alternates: \(kept.joined(separator: ", "))")
                        .foregroundColor(.secondary).font(.callout)
                }
            }
            Text("Save to start using your voiceprint to disambiguate “\(model.term)”.")
                .foregroundColor(.secondary).font(.callout)
        }
    }

    private var doneCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundColor(.green)
            Text("“\(model.term)” enrolled").font(.title3).bold()
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: recording list

    private func recordingList(sentences: [String], recordings: [Data?], negative: Bool) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(sentences.enumerated()), id: \.offset) { idx, sentence in
                HStack(spacing: 10) {
                    recordButton(index: idx, negative: negative, hasRecording: recordings.indices.contains(idx) && recordings[idx] != nil)
                    Text(sentence).font(.callout)
                    Spacer()
                    if recordings.indices.contains(idx), recordings[idx] != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(SettingsView.cardBackground))
            }
        }
    }

    private func recordButton(index: Int, negative: Bool, hasRecording: Bool) -> some View {
        let isActive = activeRecording?.index == index && activeRecording?.negative == negative
        return Button {
            toggleRecord(index: index, negative: negative)
        } label: {
            Image(systemName: isActive ? "stop.circle.fill" : (hasRecording ? "arrow.clockwise.circle" : "mic.circle"))
                .font(.title2)
                .foregroundColor(isActive ? .red : SettingsView.brandAccent)
        }
        .buttonStyle(.plain)
    }

    private func toggleRecord(index: Int, negative: Bool) {
        // Stop the active recording (this one or another).
        if let active = activeRecording {
            let cap = try? recorder?.stop()
            recorder = nil
            activeRecording = nil
            if let data = cap?.wavData, !data.isEmpty {
                if active.negative { model.setNegativeRecording(data, at: active.index) }
                else { model.setRecording(data, at: active.index) }
            }
            if active.index == index && active.negative == negative { return } // tapped the active one → just stop
        }
        // Start a new recording.
        let r = model.makeRecorder()
        do {
            try r.start()
            recorder = r
            activeRecording = (negative, index)
            micError = nil
        } catch {
            micError = "Couldn’t start recording. Check microphone permission in System Settings → Privacy."
        }
    }
}
#endif
