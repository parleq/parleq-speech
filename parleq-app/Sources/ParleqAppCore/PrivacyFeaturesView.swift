// PrivacyFeaturesView — Settings → Privacy & Features pane.
//
// Six user-facing feature toggles that let privacy-conscious users
// turn off optional Parleq features. The same toggles can also be
// forced by IT via macOS Managed Configuration — see
// docs/managed-configuration for the MDM schema.
//
// Pane order (matches the sidebar position: after Permissions, before
// Updates):
//   referenceWindowsEnabled (master)
//     ↳ clipboardReferenceEnabled (sub, indented)
//     ↳ imageReferenceEnabled     (sub, indented)
//     ↳ fileReferenceEnabled      (sub, indented)
//   customDictionaryEnabled
//   customModelEntryEnabled
//
// Sub-toggles are .disabled when the parent is off. All toggles are
// .disabled when the key appears in SettingsModel.managedKeys (MDM-
// forced), signaling the value is locked. The lock-icon badge (Phase
// 6) will make this more visually explicit; for now .disabled alone
// communicates the constraint without ambiguity.
//
// Auto-save: every toggle writes through model.save() via the shared
// SettingsView.bind() helper pattern (replicated inline here since
// PrivacyFeaturesSectionContent holds a direct reference to the model).

import SwiftUI

/// The content of the Settings → Privacy & Features detail pane.
/// Receives the shared SettingsModel so toggles write through to
/// Config.save() on every flip.
@MainActor
struct PrivacyFeaturesSectionContent: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Intro paragraph.
            Text("These toggles let you turn off optional Parleq features. They're per-user preferences, but an IT department can also push them via macOS Managed Configuration to lock them across a fleet — see the link below for the schema.")
                .font(.system(size: 13))
                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            // Reference Windows (master toggle + sub-toggles).
            referenceWindowsCard

            // Custom dictionary toggle.
            SettingsCard {
                featureToggleRow(
                    title: "Custom dictionary",
                    description: "When off, Parleq ignores your custom-dictionary entries when building the LLM cleanup prompt. Your entries are preserved — turning this back on restores them. Turn off to ensure no custom terms are sent to the LLM.",
                    isOn: featureToggleBinding(mdmKey: "customDictionaryEnabled",
                                              realKeyPath: \.customDictionaryEnabled)
                )
                .disabled(model.managedKeys.contains("customDictionaryEnabled"))
            }

            // Custom model entry toggle.
            SettingsCard {
                featureToggleRow(
                    title: "Custom model picker",
                    description: "When off, the \u{201C}Custom\u{2026}\u{201D} entry is removed from every provider's model dropdown. An already-saved custom model ID continues to work — this only prevents entering new ones.",
                    isOn: featureToggleBinding(mdmKey: "customModelEntryEnabled",
                                              realKeyPath: \.customModelEntryEnabled)
                )
                .disabled(model.managedKeys.contains("customModelEntryEnabled"))
            }

            // Docs link.
            HStack(spacing: 4) {
                Link(
                    "What are these?  Managed Configuration docs →",
                    destination: URL(string: "https://parleq.app/docs/managed-configuration/")!
                )
                .font(.system(size: 12))
                .foregroundStyle(SettingsView.brandAccent)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Reference Windows card

    @ViewBuilder
    private var referenceWindowsCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                featureToggleRow(
                    title: "Reference windows",
                    description: "Master switch for the entire Reference Windows feature. When off, the reference-attach button, chip strip, and drag-drop zone are hidden. Sub-toggles below become moot but are preserved for when you re-enable.",
                    isOn: featureToggleBinding(mdmKey: "referenceWindowsEnabled",
                                              realKeyPath: \.referenceWindowsEnabled)
                )
                .disabled(model.managedKeys.contains("referenceWindowsEnabled"))

                Divider().opacity(0.4).padding(.leading, 16)

                // Sub-toggles — indented 16 pt and disabled when parent is off.
                let parentOff = !model.referenceWindowsEnabled
                Group {
                    featureToggleRow(
                        title: "Clipboard as reference",
                        description: "When off, the \u{201C}Add from clipboard\u{201D} item is removed from the overlay\u{2019}s + menu.",
                        isOn: featureToggleBinding(mdmKey: "clipboardReferenceEnabled",
                                                   realKeyPath: \.clipboardReferenceEnabled)
                    )
                    .disabled(parentOff || model.managedKeys.contains("clipboardReferenceEnabled"))
                    .opacity(parentOff ? 0.5 : 1)

                    featureToggleRow(
                        title: "Image-mode references",
                        description: "When off, the T / \u{1F441} mode toggle is removed from every reference chip, and captured references always use text-mode (OCR). Prevents screenshots from being sent to the LLM.",
                        isOn: featureToggleBinding(mdmKey: "imageReferenceEnabled",
                                                   realKeyPath: \.imageReferenceEnabled)
                    )
                    .disabled(parentOff || model.managedKeys.contains("imageReferenceEnabled"))
                    .opacity(parentOff ? 0.5 : 1)

                    featureToggleRow(
                        title: "File references (picker + drag-drop)",
                        description: "When off, the \u{201C}Add file\u{2026}\u{201D} picker item and the overlay\u{2019}s drag-drop affordance are hidden. Window-capture and clipboard references remain available.",
                        isOn: featureToggleBinding(mdmKey: "fileReferenceEnabled",
                                                   realKeyPath: \.fileReferenceEnabled)
                    )
                    .disabled(parentOff || model.managedKeys.contains("fileReferenceEnabled"))
                    .opacity(parentOff ? 0.5 : 1)
                }
                .padding(.leading, 16)
            }
        }
    }

    // MARK: - Helpers

    /// One toggle row: title + description on the left, toggle on the
    /// right. Matches the visual density of other Settings cards.
    @ViewBuilder
    private func featureToggleRow(
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    /// Builds a Binding<Bool> that reads/writes a SettingsModel keyPath
    /// and also calls model.save() on change. When the MDM key is in
    /// model.managedKeys the set is a no-op (MDM controls the value).
    /// The caller is responsible for adding `.disabled(true)` when the
    /// key is managed — this binding doesn't disable the UI, it just
    /// silently ignores writes, providing defense-in-depth.
    private func featureToggleBinding(
        mdmKey: String,
        realKeyPath: ReferenceWritableKeyPath<SettingsModel, Bool>
    ) -> Binding<Bool> {
        let isManaged = model.managedKeys.contains(mdmKey)
        return Binding(
            get: { model[keyPath: realKeyPath] },
            set: { newValue in
                guard !isManaged else { return }
                model[keyPath: realKeyPath] = newValue
                model.save()
            }
        )
    }
}
