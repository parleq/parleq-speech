// PermissionsViews — the two consumer surfaces of PermissionRow:
//
//   - PermissionsSectionContent: the Settings → Permissions detail
//     pane. Rendered by SettingsView.permissionsSection.
//   - PermissionsWizardStep: the Setup wizard's "Permissions" step
//     body. Rendered by SetupWizardView when step == .permissions.
//
// Both consume the same PermissionsModel snapshot and emit the same
// four rows via the descriptor builders in PermissionRow.swift — by
// construction, anything that changes the row UI lands in both
// surfaces simultaneously.

import SwiftUI

/// The Settings → Permissions detail-pane content. Wrapped in its
/// own View so the Settings file doesn't carry the PermissionsModel
/// observation directly.
@MainActor
struct PermissionsSectionContent: View {
    @ObservedObject private var model: PermissionsModel = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("macOS permissions Parleq needs to run, and whether to launch it automatically at login.")
                .font(.system(size: 13))
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            PermissionRow(descriptor: microphoneDescriptor(state: model.snapshot.microphone))
            PermissionRow(descriptor: accessibilityDescriptor(state: model.snapshot.accessibility))
            PermissionRow(descriptor: screenRecordingDescriptor(state: model.snapshot.screenRecording))
            PermissionRow(descriptor: openAtLoginDescriptor(state: model.snapshot.openAtLogin))

            HStack(spacing: 4) {
                Text("What does Parleq do with these?")
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                Link("See the FAQ →", destination: URL(string: "https://parleq.app/faq/#privacy-data-flow")!)
            }
            .font(.system(size: 12))
            .padding(.top, 6)
        }
        .onAppear {
            // Belt-and-suspenders: PermissionsModel observes app
            // activation, but a user who grants while Parleq is
            // already frontmost (e.g. opens Settings, clicks Allow,
            // System Settings activates briefly, user comes back via
            // the Settings window staying open) might not trigger
            // didBecomeActive. Refresh on appear catches that case.
            model.refresh()
        }
    }
}

/// The Setup wizard's Permissions step body. The wizard's chrome
/// (stepper, Back/Continue buttons, gating logic) lives in
/// SetupWizard.swift; this view supplies only the step's content.
@MainActor
struct PermissionsWizardStep: View {
    @ObservedObject private var model: PermissionsModel = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow Parleq to work")
                .font(.title2.weight(.semibold))
            Text("Two macOS permissions are required for core dictation. Screen Recording is optional — only needed for Reference Windows. Open-at-Login is an optional toggle. We'll wait here until the required ones are granted.")
                .font(.system(size: 14))
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            PermissionRow(descriptor: microphoneDescriptor(state: model.snapshot.microphone))
            PermissionRow(descriptor: accessibilityDescriptor(state: model.snapshot.accessibility))
            PermissionRow(descriptor: screenRecordingDescriptor(state: model.snapshot.screenRecording))
            PermissionRow(descriptor: openAtLoginDescriptor(state: model.snapshot.openAtLogin))

            HStack(spacing: 4) {
                Text("What does Parleq do with these?")
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                Link("See the FAQ →", destination: URL(string: "https://parleq.app/faq/#privacy-data-flow")!)
            }
            .font(.system(size: 12))
            .padding(.top, 6)
        }
        .onAppear { model.refresh() }
    }
}
