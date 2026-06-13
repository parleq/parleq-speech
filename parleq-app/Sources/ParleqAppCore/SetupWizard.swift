// SetupWizard — first-run setup window (#21 step 6).
//
// Triggers:
//   1. Auto-launches on first app start (config.wizardCompleted == false).
//   2. Reachable from the menu bar at any time via "Run Setup…".
//   3. Reachable from Settings → "Run Setup Again" button.
//
// Flow:
//   Welcome → Pick a cleanup approach → Per-provider auth setup → Done
//
// Tone is light-educational: brief explanations + links out to the
// website's how-it-works page and provider-specific docs. Never
// required to complete — every step has a "Skip / Configure later"
// out, and the cleanup-pick step's first option is "None — paste
// raw ASR" so a user who only wants local dictation can finish
// in two clicks.
//
// Important non-goals:
//   - We do NOT block on STT model download. `LocalASR.start()`
//     kicks off the Parakeet TDT v3 download in the background at
//     app launch; the menu-bar icon surfaces "Initializing speech
//     model…" until it lands. The wizard mentions the download is
//     happening but doesn't drive it explicitly.
//   - We do NOT capture all of Settings. The wizard sets the
//     handful of fields needed to make cleanup work; everything
//     else (custom dictionary, hotkey binding, audio routing) is
//     deferred to the regular Settings window.

import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by Settings → "Run Setup Again" button. ParleqApp's
    /// main-actor block subscribes and forwards to
    /// `SetupWizardController.show()`. Decoupling the Settings UI
    /// from the wizard controller this way avoids plumbing the
    /// controller through SettingsModel just for one click handler.
    public static let parleqRunSetupAgain = Notification.Name("ParleqRunSetupAgain")

    /// Posted by Settings → Updates → "Check for Updates Now" and by
    /// the menu-bar "Check for Updates…" item. ParleqApp's main-actor
    /// block subscribes and forwards to the retained Sparkle
    /// `SPUStandardUpdaterController.checkForUpdates(_:)`. Same
    /// decoupling rationale as `parleqRunSetupAgain` — the Settings
    /// UI doesn't need a reference to the updater controller.
    public static let parleqCheckForUpdates = Notification.Name("ParleqCheckForUpdates")

    /// Posted whenever the user changes their microphone selection
    /// from any UI surface (today: the menu-bar Microphone submenu
    /// and Settings → Audio). userInfo carries `["uid": String]` —
    /// empty string for "System Default", otherwise a Core Audio
    /// device UID. ParleqApp subscribes and updates the
    /// AudioRecorder's runtime selection + the menu's checkmark
    /// state on receipt. Letting both UI surfaces fire the same
    /// notification keeps the two pickers in sync automatically.
    public static let parleqMicrophoneSelectionChanged = Notification.Name("ParleqMicrophoneSelectionChanged")

    /// Posted by the app-launch path when a restart-initiated reopen
    /// is detected (parleq.reopenSettingsOnLaunch UserDefaults flag).
    /// ParleqApp subscribes and calls SettingsWindowController.show().
    /// Using a notification keeps ParleqApp_relaunch() and the launch
    /// path both ignorant of the SettingsWindowController instance.
    public static let parleqOpenSettings = Notification.Name("ParleqOpenSettings")

    /// Posted by SettingsModel.save() when the overlay-show delay
    /// changes (#56). main.swift observes it and calls
    /// HotkeyListener.setPHoldThreshold so the hold-hotkey+P gesture
    /// threshold stays in lockstep with the overlay delay without an
    /// app restart. userInfo["ms"] carries the new delay as an Int.
    public static let parleqOverlayDelayChanged = Notification.Name("ParleqOverlayDelayChanged")

    /// Posted when the cleanup provider changes in Settings, so the on-device
    /// restart-to-activate menu-bar item re-evaluates `onDeviceActivationPending`
    /// (the menu-bar observer otherwise only fires on model-state transitions, so
    /// switching local→other while the model is ready would leave a stale item).
    public static let parleqCleanupProviderChanged = Notification.Name("ParleqCleanupProviderChanged")

    /// Posted when "learn from corrections" is enabled OUTSIDE the Settings
    /// window — i.e. via the overlay's inline toggle (`LearnBanner`). An open
    /// `SettingsModel` loaded the old value at init and would otherwise write
    /// the stale `false` back on its next save, silently re-disabling the
    /// feature. The app view observes this and syncs the single field.
    public static let parleqLearnFeatureEnabledExternally = Notification.Name("ParleqLearnFeatureEnabledExternally")

    /// Posted by the AWS/Vertex cleanup cards' "Open Company Account"
    /// button (the corporate-sign-in auth modes) when the user isn't
    /// signed in yet. The app shell observes it and selects the
    /// `.companyAccount` settings section so the user lands on the
    /// sign-in surface. Carries no payload.
    public static let parleqOpenCompanyAccount = Notification.Name("ParleqOpenCompanyAccount")
}

/// Controller that owns the wizard NSWindow + SwiftUI hosting.
/// Mirrors SettingsWindowController's pattern.
@MainActor
public final class SetupWizardController {
    /// The shared on-device model store. Injected at construction so the
    /// wizard's Done step can show live download progress and the pick-
    /// provider step can trigger the download when the user chooses "local".
    /// Same store instance that main.swift and LocalLLMProvider hold.
    private let localModelStore: LocalModelStore

    public init(localModelStore: LocalModelStore) {
        self.localModelStore = localModelStore
    }

    private var window: NSWindow?

    /// Show the wizard, creating it on first call. Always re-centers
    /// on the active screen — this is a one-shot focused flow that
    /// should grab attention each time it opens, not restore wherever
    /// the user dragged it last.
    public func show() {
        if window == nil {
            let view = SetupWizardView(
                onFinish: { [weak self] in self?.window?.close() },
                localModelStore: localModelStore
            )
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Welcome to Parleq"
            w.styleMask = [.titled, .closable]
            w.collectionBehavior = [.fullScreenAuxiliary]
            w.isReleasedWhenClosed = false
            // Force the content size up-front so center() below
            // operates on the real frame, not a default tiny one.
            // (See SettingsWindowController.show for the same dance
            // and the explanation of why this matters on first open.)
            w.setContentSize(NSSize(width: 660, height: 540))
            self.window = w
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Wizard step machine. Each enum case is a screen.
private enum WizardStep: Int, CaseIterable {
    case welcome
    case permissions
    case pickProvider
    case configureProvider
    case advancedModel   // optional step; skipped when pickedProvider == "none"
    case done

    /// Short label used in the wizard's step-pill indicator.
    /// Three-or-fewer words so the six pills + dividers fit on
    /// one line at the wizard's standard width.
    var displayName: String {
        switch self {
        case .welcome:           return "Welcome"
        case .permissions:       return "Permissions"
        case .pickProvider:      return "Pick provider"
        case .configureProvider: return "Configure"
        case .advancedModel:     return "Advanced"
        case .done:              return "Done"
        }
    }
}

@MainActor
private final class WizardModel: ObservableObject {
    @Published var step: WizardStep = .welcome

    /// Top-level tier choice on the pick-provider step. nil until the user
    /// makes a selection (forcing a deliberate choice; Continue is disabled
    /// while nil). Values: "local", "cloud", "none".
    @Published var pickedTier: String? = nil

    /// The cloud sub-provider selected when pickedTier == "cloud".
    /// Drives the ConfigureProvider step and commit(). When pickedTier is
    /// "local" or "none" this field is not consulted.
    @Published var pickedProvider: String = "gemini" {
        didSet {
            if oldValue != pickedProvider {
                resetAdvancedModelState()
            }
        }
    }

    // Auth-config state — duplicated from SettingsModel rather than
    // sharing because the wizard is a discrete one-shot flow that
    // shouldn't live-update Settings while the user is mid-flow.
    @Published var pendingGeminiKey = ""
    @Published var pendingAzureKey = ""
    @Published var pendingAzureResource = ""
    @Published var pendingAzureDeployment = ""
    /// "apiKey" (default) or "azureAd". Drives whether the wizard's
    /// Azure step shows the key-paste field or the `az login` blurb.
    @Published var pendingAzureAuthMode = "apiKey"
    @Published var pendingVertexProject = ""
    @Published var pendingVertexRegion = "us-central1"
    /// "adc" (default) or "serviceAccount". Drives whether the
    /// wizard's Vertex step shows the gcloud blurb or the SA-JSON
    /// paste TextEditor.
    @Published var pendingVertexAuthMode = "adc"
    /// Pasted service-account JSON content for Vertex SA auth. Only
    /// committed to the Keychain when pendingVertexAuthMode is
    /// "serviceAccount" AND non-empty AND parses successfully.
    @Published var pendingVertexServiceAccountJSON = ""
    @Published var pendingAwsRegion = "us-east-2"
    @Published var pendingAwsProfile = ""
    /// "sso" (default) or "oidc" (corporate sign-in / federation).
    /// Static-credential + Bedrock-API-key modes still live only in
    /// Settings; the wizard offers the AWS CLI session path and the
    /// federated corporate-sign-in path.
    @Published var pendingAwsAuthMode = "sso"
    /// IAM role ARN federated into when pendingAwsAuthMode == "oidc".
    @Published var pendingAwsRoleArn = ""
    /// "adc"/"serviceAccount"/"oidcFederation" — extends the Vertex
    /// auth modes with corporate sign-in (Workforce Identity Federation).
    /// GCP workforce provider resource name for "oidcFederation".
    @Published var pendingVertexWorkforceProvider = ""

    // MARK: OIDC corporate sign-in (shared across providers)

    /// OIDC issuer + client ID. The wizard may be the FIRST surface where
    /// these are configured, so they're collected here when a corporate
    /// sign-in mode is picked. Prefilled from the loaded config (so a
    /// re-run, or an MDM-pinned org, shows existing values) and disabled
    /// when MDM-pinned. The actual sign-in happens after relaunch under
    /// Company Account — the wizard only writes config.
    @Published var pendingOidcIssuer = ""
    @Published var pendingOidcClientID = ""
    /// MDM-pinned key set snapshotted at init so the wizard renders
    /// pinned OIDC fields read-only with the org note.
    let managedKeys: Set<String>

    init() {
        let (config, _) = Config.load()
        self.managedKeys = config.managedKeys
        self.pendingOidcIssuer = config.oidcIssuer
        self.pendingOidcClientID = config.oidcClientID
        self.pendingAwsRoleArn = config.awsRoleArn
        self.pendingVertexWorkforceProvider = config.vertexWorkforceProvider
        // Seed auth-mode pickers from the persisted config so a wizard
        // re-run can't silently revert federation modes back to the
        // hard-coded defaults. Allowlist guards against unknown values.
        self.pendingAwsAuthMode = ["sso", "oidc"].contains(config.awsAuthMode)
            ? config.awsAuthMode : "sso"
        self.pendingVertexAuthMode = ["adc", "serviceAccount", "oidcFederation", "googleOAuth"].contains(config.vertexAuthMode)
            ? config.vertexAuthMode : "adc"
    }

    // MARK: Advanced step state

    /// Phase 2: the user's choice on the Advanced step.
    /// nil  → "Same as cleanup" (default); Config.contextModel is
    ///         written nil, and the runtime resolver falls back to
    ///         the cleanup model — same as today's behaviour.
    /// non-nil → user explicitly picked a different model on the
    ///           Advanced step; we write that to Config.contextModel.
    @Published var pickedContextModel: ModelIdentifier?

    /// True when the user has flipped the "Pick a different model"
    /// radio on the Advanced step. Drives the dropdown's visibility.
    @Published var advancedPickEnabled: Bool = false

    /// Reset Advanced-step state so a provider change doesn't carry a
    /// stale context-model identifier across providers. Called from the
    /// pickedProvider didSet (any provider switch) and from goBack when
    /// the user backs out of the advancedModel step.
    fileprivate func resetAdvancedModelState() {
        advancedPickEnabled = false
        pickedContextModel = nil
    }

    /// Persist the wizard's choices to ~/.parleq/config.json + the
    /// macOS Keychain. Called when the user clicks Finish on the
    /// done screen. Skip-cleanup ("none") still writes the provider
    /// choice so the next launch knows the user picked it.
    func commit() {
        let (existing, _) = Config.load()
        var c = existing

        // Resolve the effective provider from the tier choice.
        //   "local" → provider="local", leave llmModel alone (factory ignores
        //             id.model on the local path; writing a stale cloud id
        //             would pollute logs and the UsageLedger).
        //   "none"  → provider="none" (no cleanup).
        //   "cloud" → delegate to pickedProvider (gemini/vertex/bedrock/azure).
        let effectiveProvider: String
        switch pickedTier {
        case "local": effectiveProvider = "local"
        case "none":  effectiveProvider = "none"
        default:      effectiveProvider = pickedProvider   // "cloud" or legacy path
        }

        c.llmProvider = effectiveProvider

        // Sensible default model per provider — matches Settings'
        // defaultModelByProvider table so the user gets a working
        // model id without typing one. Local path deliberately does
        // NOT write llmModel — the factory ignores it for local and
        // a stale cloud model id in config.llm.model would pollute
        // logs and the UsageLedger.
        switch effectiveProvider {
        case "gemini": c.llmModel = "gemini-2.5-flash"
        case "vertex":
            c.llmModel = "gemini-2.5-flash"
            c.vertexProject = pendingVertexProject.trimmingCharacters(in: .whitespacesAndNewlines)
            c.vertexRegion = pendingVertexRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.vertexRegion.isEmpty { c.vertexRegion = "us-central1" }
            c.vertexAuthMode = ["adc", "serviceAccount", "oidcFederation", "googleOAuth"].contains(pendingVertexAuthMode)
                ? pendingVertexAuthMode : "adc"
            if pendingVertexAuthMode == "oidcFederation" {
                applyWizardOIDC(&c)
                c.vertexWorkforceProvider = pendingVertexWorkforceProvider
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if pendingVertexAuthMode == "googleOAuth" {
                // No workforce provider: the Google sign-in's access token is
                // the Vertex bearer directly. Seed only the shared OIDC config
                // (issuer/client ID/scopes/extra params).
                applyWizardOIDC(&c)
            }
        case "bedrock":
            c.llmModel = "openai.gpt-oss-120b-1:0"
            c.awsRegion = pendingAwsRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.awsRegion.isEmpty { c.awsRegion = "us-east-2" }
            let trimmed = pendingAwsProfile.trimmingCharacters(in: .whitespacesAndNewlines)
            c.awsProfile = trimmed.isEmpty ? nil : trimmed
            // The wizard offers two Bedrock auth paths: the AWS CLI
            // session (SSO) path for new individual users, and the
            // federated corporate-sign-in (OIDC) path for enterprise.
            // Static IAM creds + Bedrock API keys need secret-paste
            // sheets that live in the Settings window.
            c.awsAuthMode = ["sso", "oidc"].contains(pendingAwsAuthMode) ? pendingAwsAuthMode : "sso"
            if pendingAwsAuthMode == "oidc" {
                applyWizardOIDC(&c)
                c.awsRoleArn = pendingAwsRoleArn.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "azure":
            c.llmModel = "gpt-4o-mini"
            c.azureResource = pendingAzureResource.trimmingCharacters(in: .whitespacesAndNewlines)
            c.azureDeployment = pendingAzureDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
            c.azureAuthMode = ["apiKey", "azureAd"].contains(pendingAzureAuthMode)
                ? pendingAzureAuthMode : "apiKey"
        default:
            break
        }
        c.wizardCompleted = true
        // Advanced step: nil means "same as cleanup" which is also
        // Config.contextModel's nil meaning, so this is a straight
        // pass-through in both the "skipped" and "same as cleanup"
        // cases. Skip-cleanup ("none") and local have no cleanup cloud
        // model to be "different from", so don't touch contextModel.
        if effectiveProvider != "none" && effectiveProvider != "local" {
            c.contextModel = pickedContextModel
        }
        do {
            try Config.save(c)
            // Refresh the on-device restart-to-activate affordance. The wizard
            // changes the provider via Config.save (not the Settings picker), and
            // if the model is already downloaded no `.ready` transition fires —
            // so without this the menu-bar restart item wouldn't update when
            // on-device is enabled from the wizard. Mirrors the picker's post.
            NotificationCenter.default.post(name: .parleqCleanupProviderChanged, object: nil)
        } catch {
            FileHandle.standardError.write(
                "[parleq] wizard: save failed: \(error)\n".data(using: .utf8) ?? Data()
            )
        }

        // Secrets land in the Keychain via KeychainStore — never in
        // the JSON config file. Each branch only writes if the
        // user actually committed to the cloud tier AND picked the
        // matching provider AND filled the field. The `pickedTier == "cloud"`
        // guard prevents a pending key (typed while exploring the cloud
        // sub-path) from being written if the user backed out and finished
        // with the On-device or None tier.
        if pickedTier == "cloud" {
            let geminiTrimmed = pendingGeminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if pickedProvider == "gemini", !geminiTrimmed.isEmpty {
                KeychainStore.setGeminiAPIKey(geminiTrimmed)
            }
            let azureTrimmed = pendingAzureKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if pickedProvider == "azure", pendingAzureAuthMode == "apiKey", !azureTrimmed.isEmpty {
                KeychainStore.setAzureAPIKey(azureTrimmed)
            }
            let saTrimmed = pendingVertexServiceAccountJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if pickedProvider == "vertex", pendingVertexAuthMode == "serviceAccount", !saTrimmed.isEmpty {
                // Best-effort: try to parse to validate before storing.
                // Bad JSON gets stored anyway so the user can re-run
                // the wizard and edit; the provider's per-request
                // path will surface a clean missingCredentials error
                // until they fix it.
                if (try? ServiceAccountKey.parse(saTrimmed)) == nil {
                    let msg = "[parleq] wizard: pasted Vertex SA JSON did not validate; storing anyway. Provider will surface a clear error on first dictation if it's still bad.\n"
                    FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
                }
                KeychainStore.setVertexServiceAccountJSON(saTrimmed)
            }
        }

        // Drop in-memory secret state on commit so it doesn't sit in
        // a SwiftUI debug surface for the rest of the session.
        pendingGeminiKey = ""
        pendingAzureKey = ""
        pendingVertexServiceAccountJSON = ""
    }

    /// Write the OIDC issuer + client ID collected on a corporate-sign-in
    /// card, unless they're MDM-pinned (in which case Config.save() would
    /// preserve the on-disk value anyway, but we skip writing to avoid any
    /// churn). No tokens or identity are involved — the actual sign-in
    /// happens after relaunch under Company Account.
    private func applyWizardOIDC(_ c: inout Config) {
        if !managedKeys.contains("oidcIssuer") {
            c.oidcIssuer = pendingOidcIssuer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !managedKeys.contains("oidcClientID") {
            c.oidcClientID = pendingOidcClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private struct SetupWizardView: View {
    let onFinish: () -> Void
    /// Shared on-device cleanup model store. Observed for live download
    /// state in DoneStep; download() is called here when the user picks the
    /// on-device tier and advances past the pick-provider step.
    @ObservedObject var localModelStore: LocalModelStore
    @StateObject private var model = WizardModel()
    /// Observed so `canAdvance` and the Continue button label
    /// re-evaluate every time a permission state changes (e.g. the
    /// user grants Mic, comes back, snapshot republishes, Continue
    /// flips from disabled to enabled).
    @ObservedObject private var permissionsModel: PermissionsModel = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top header strip — sidebar-tone background + a small
            // step indicator so the user can see how far through
            // the flow they are.
            stepIndicator
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsView.sidebarBackground)

            // Body — scrollable so a small window doesn't clip
            // long step content (DoneStep can be tall).
            ScrollView {
                Group {
                    switch model.step {
                    case .welcome:
                        WelcomeStep()
                    case .permissions:
                        PermissionsWizardStep()
                    case .pickProvider:
                        PickProviderStep(model: model, localModelStore: localModelStore)
                    case .configureProvider:
                        ConfigureProviderStep(model: model)
                    case .advancedModel:
                        AdvancedModelStep(model: model)
                    case .done:
                        DoneStep(model: model, localModelStore: localModelStore)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsView.detailBackground)

            // Footer toolbar. Same tone as the header strip so the
            // top + bottom read as a unified frame around the
            // active step.
            HStack(spacing: 12) {
                // "Skip Setup" is hidden on the pick-provider step: the cleanup
                // choice is now a forced decision. The user can still close the
                // window (the window's close button remains active — abandoning
                // the wizard safely leaves config unchanged so raw ASR continues
                // to work). All other steps keep the skip affordance.
                if model.step != .pickProvider {
                    Button("Skip Setup") {
                        let (existing, _) = Config.load()
                        var c = existing
                        c.wizardCompleted = true
                        try? Config.save(c)
                        onFinish()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if model.step != .welcome {
                    Button("Back") {
                        goBack()
                    }
                    .buttonStyle(.bordered)
                }
                if model.step == .done {
                    Button("Finish later") {
                        model.commit()
                        onFinish()
                    }
                    .buttonStyle(.bordered)
                    Button("Finish & Restart") {
                        model.commit()
                        onFinish()
                        ParleqApp_relaunch()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(continueButtonLabel) {
                        advance()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(SettingsView.sidebarBackground)
        }
        .frame(width: 660, height: 540)
        .accentColor(SettingsView.brandAccent)
    }

    /// Step pills — a compact horizontal indicator showing where
    /// the user is in the four-step flow. The active step is shown
    /// in brand amber + white text; completed steps use the same
    /// amber at lower opacity; upcoming steps are a muted grey.
    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(WizardStep.allCases, id: \.rawValue) { step in
                stepPill(step)
                if step != WizardStep.allCases.last {
                    Rectangle()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 16, height: 1)
                }
            }
            Spacer()
            Text("Setup • Step \(model.step.rawValue + 1) of \(WizardStep.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stepPill(_ step: WizardStep) -> some View {
        let isActive = step == model.step
        let isComplete = step.rawValue < model.step.rawValue
        let fill: Color
        let textColor: Color
        if isActive {
            fill = SettingsView.brandAccent
            textColor = .white
        } else if isComplete {
            fill = SettingsView.brandAccent.opacity(0.35)
            textColor = .primary
        } else {
            fill = Color.primary.opacity(0.08)
            textColor = .secondary
        }
        return Text(step.displayName)
            .font(.caption.weight(isActive ? .semibold : .regular))
            .foregroundStyle(textColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(fill)
            )
    }

    /// Continue-button label. Normally just "Continue", but on the
    /// `.permissions` step we surface the specific blocking reason
    /// in the label itself so the user is never confused about why
    /// the button is disabled.
    private var continueButtonLabel: String {
        guard model.step == .permissions else { return "Continue" }
        let snap = permissionsModel.snapshot
        if snap.microphone != .granted    { return "Continue (grant Microphone first)" }
        if snap.accessibility != .granted { return "Continue (grant Accessibility first)" }
        return "Continue"
    }

    /// Issuer + client ID are both present (or MDM-pinned). Gates the
    /// corporate-sign-in wizard cards — without them the federation can't
    /// be constructed at the next launch.
    private var wizardOIDCConfigComplete: Bool {
        let issuerOK = model.managedKeys.contains("oidcIssuer")
            || !model.pendingOidcIssuer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let clientOK = model.managedKeys.contains("oidcClientID")
            || !model.pendingOidcClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return issuerOK && clientOK
    }

    private var canAdvance: Bool {
        switch model.step {
        case .welcome: return true
        case .permissions:
            // Mic + Accessibility are load-bearing — Parleq's hotkey
            // does nothing useful without them. Open at Login stays
            // optional (the row is in the step but doesn't gate).
            let snap = permissionsModel.snapshot
            return snap.microphone == .granted && snap.accessibility == .granted
        case .pickProvider:
            // Tier must be chosen. If "cloud" is chosen, a sub-provider
            // must also be selected. "local" and "none" need no sub-pick.
            guard let tier = model.pickedTier else { return false }
            if tier == "cloud" { return !model.pickedProvider.isEmpty }
            return true
        case .configureProvider:
            // Vertex needs a project (and SA JSON when in SA mode);
            // Azure needs resource + deployment; Gemini and Bedrock
            // can finish without — Gemini's key is optional
            // (per-request resolve), Bedrock's profile is optional
            // (falls back to default profile / env var). Azure's API
            // key is also per-request-resolved, so it's optional in
            // apiKey mode and not used at all in azureAd mode.
            // "none" trivially passes.
            switch model.pickedProvider {
            case "vertex":
                let projectOK = !model.pendingVertexProject
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if model.pendingVertexAuthMode == "serviceAccount" {
                    let jsonOK = !model.pendingVertexServiceAccountJSON
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    return projectOK && jsonOK
                }
                if model.pendingVertexAuthMode == "oidcFederation" {
                    let workforceOK = model.managedKeys.contains("vertexWorkforceProvider")
                        || !model.pendingVertexWorkforceProvider
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    return projectOK && workforceOK && wizardOIDCConfigComplete
                }
                if model.pendingVertexAuthMode == "googleOAuth" {
                    // Native Google sign-in: needs issuer + client ID (the
                    // shared OIDC config) and a project — but NO workforce
                    // provider (no federation hop; the access token is the
                    // Vertex bearer directly).
                    return projectOK && wizardOIDCConfigComplete
                }
                return projectOK
            case "bedrock":
                if model.pendingAwsAuthMode == "oidc" {
                    let roleOK = model.managedKeys.contains("awsRoleArn")
                        || !model.pendingAwsRoleArn
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    return roleOK && wizardOIDCConfigComplete
                }
                return true
            case "azure":
                return !model.pendingAzureResource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !model.pendingAzureDeployment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return true
            }
        case .advancedModel:
            // The step is always advanceable: "Same as cleanup" is
            // the default and the dropdown only gates when the user
            // explicitly picks "Pick a different model" but leaves
            // the selection nil — that shouldn't happen because we
            // eagerly assign a default on radio selection, but guard
            // defensively anyway.
            if model.advancedPickEnabled { return model.pickedContextModel != nil }
            return true
        case .done: return true
        }
    }

    private func advance() {
        switch model.step {
        case .welcome:
            model.step = .permissions
        case .permissions:
            model.step = .pickProvider
        case .pickProvider:
            let tier = model.pickedTier ?? "cloud"
            if tier == "local" {
                // Kick off the model download now (idempotent — LocalModelStore.download()
                // guards against re-entering when not in .notDownloaded state, so if the
                // model is already .ready or .downloading this is a safe no-op).
                localModelStore.download()
                // Local and none both skip configure + advanced (no cloud auth needed).
                model.step = .done
            } else if tier == "none" {
                model.step = .done
            } else {
                // Cloud: show the per-provider configure step.
                model.step = .configureProvider
            }
        case .configureProvider:
            model.step = .advancedModel
        case .advancedModel:
            model.step = .done
        case .done:
            model.commit()
            onFinish()
        }
    }

    private func goBack() {
        switch model.step {
        case .welcome:
            break // no-op; Back is hidden on the welcome step
        case .permissions:
            model.step = .welcome
        case .pickProvider:
            model.step = .permissions
        case .configureProvider:
            model.step = .pickProvider
        case .advancedModel:
            // Clear the advanced-model choice when backing out: re-entering
            // should start fresh rather than re-showing a stale radio state.
            model.resetAdvancedModelState()
            model.step = .configureProvider
        case .done:
            // Mirror the forward skip: local and none both bypassed configure
            // and advanced; cloud went through them.
            let tier = model.pickedTier ?? "cloud"
            if tier == "local" || tier == "none" {
                model.step = .pickProvider
            } else {
                model.step = .advancedModel
            }
        }
    }
}

// MARK: - Step views

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Parleq.")
                .font(.title)
            Text("Press a global hotkey, speak, see your words appear — cleaned up, punctuated, and pasted into whatever app was focused. Audio stays on your Mac.")
                .font(.body)
            Text("This setup walks through one decision: how to clean up your transcripts. The local speech model is downloading in the background; you'll be ready to dictate when the menu-bar icon switches from the download glyph to a microphone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Link("Read how Parleq works →",
                 destination: URL(string: "https://parleq.app/how-it-works/")!)
                .font(.callout)
        }
    }
}

private struct PickProviderStep: View {
    @ObservedObject var model: WizardModel
    @ObservedObject var localModelStore: LocalModelStore

    // MARK: - Tier cards (top level)

    private struct TierOption: Identifiable {
        var id: String
        var title: String
        var blurb: String
    }

    private var ramTier: RAMTier { RAMTier.current }
    /// Snapshotted once at view creation — `Config.load()` is file I/O and
    /// must not run per render. The pick-provider step doesn't hot-reload
    /// config while it's visible, so a once-per-view-instance value is fine.
    private let localAllowUnsupportedRAM: Bool = {
        let (config, _) = Config.load()
        return config.localAllowUnsupportedRAM
    }()

    private var tierOptions: [TierOption] {
        [
            .init(id: "local",
                  title: "On-device",
                  blurb: localCardBlurb),
            .init(id: "cloud",
                  title: "Cloud provider",
                  blurb: "Best quality. Google Gemini (free tier, recommended for personal use), AWS Bedrock, Vertex AI, or Azure OpenAI — needs an API key or your org's sign-in."),
            .init(id: "none",
                  title: "None — paste raw speech-to-text",
                  blurb: "Local dictation only. No cloud calls. Faster, fully private. Output won't be punctuated or polished — best when transcript content cannot leave the device."),
        ]
    }

    private var localCardBlurb: String {
        switch ramTier {
        case .unsupported where !localAllowUnsupportedRAM:
            return "Needs a Mac with 12 GB+ memory — the model alone uses ~6 GB while active."
        default:
            return "Runs entirely on this Mac. No account or API key. Uses about 6 GB of memory while cleaning up. ~4 GB one-time download."
        }
    }

    // MARK: - Cloud sub-provider options (shown when tier == "cloud")

    private struct CloudOption: Identifiable {
        var id: String
        var title: String
        var blurb: String
    }
    private let cloudOptions: [CloudOption] = [
        .init(id: "gemini", title: "Google Gemini (recommended for personal use)",
              blurb: "Free tier covers most personal dictation. One API key from Google AI Studio. Fastest setup."),
        .init(id: "bedrock", title: "AWS Bedrock",
              blurb: "Anthropic Claude or OpenAI GPT-OSS, hosted in your AWS account. Use when your org blocks Google API calls. Auth via your existing AWS CLI session."),
        .init(id: "vertex", title: "Google Vertex AI",
              blurb: "Same Gemini models as the direct API but on the GCP control plane — IAM, audit logs, data residency. Auth via gcloud."),
        .init(id: "azure", title: "Azure OpenAI",
              blurb: "OpenAI GPT-4o family hosted in your Azure subscription. Use on Microsoft contracts (BAA, EU residency). Resource API key."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a cleanup approach.")
                .font(.title2)
            Text("Parleq's local speech recognition gets the words; an LLM polishes them — adds punctuation, drops fillers, fixes obvious misrecognitions. You can swap providers later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(tierOptions) { opt in
                    tierCard(opt)
                }
            }

            // Cloud sub-picker — revealed when the user picks "cloud".
            if model.pickedTier == "cloud" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Select a cloud provider:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(cloudOptions) { opt in
                            cloudProviderRow(opt)
                        }
                    }
                    .padding(.leading, 16)
                }
            }
        }
    }

    // MARK: - Tier card renderer

    private func tierCard(_ opt: TierOption) -> some View {
        let isLocalUnsupported = opt.id == "local"
            && ramTier == .unsupported
            && !localAllowUnsupportedRAM
        let isPicked = model.pickedTier == opt.id

        return Button {
            if !isLocalUnsupported {
                model.pickedTier = opt.id
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isPicked ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isPicked ? SettingsView.brandAccent : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(opt.title)
                        .font(.body)
                        .fontWeight(isPicked ? .semibold : .regular)
                        .foregroundStyle(isLocalUnsupported ? Color.secondary : Color.primary)
                    Text(opt.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    // Cautioned caption: appended for 16 GB Macs when not unsupported.
                    if opt.id == "local" && ramTier == .cautioned {
                        Text("On a 16 GB Mac this can slow other memory-hungry apps; Parleq frees the memory after a few minutes of inactivity.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isPicked
                          ? SettingsView.brandAccent.opacity(0.12)
                          : SettingsView.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isPicked
                            ? SettingsView.brandAccent.opacity(0.55)
                            : SettingsView.cardBorder,
                            lineWidth: isPicked ? 1.0 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocalUnsupported)
        .opacity(isLocalUnsupported ? 0.5 : 1.0)
    }

    // MARK: - Cloud sub-provider row renderer (reuses the same visual pattern)

    private func cloudProviderRow(_ opt: CloudOption) -> some View {
        let isPicked = (model.pickedProvider == opt.id)
        return Button {
            model.pickedProvider = opt.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isPicked ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isPicked ? SettingsView.brandAccent : Color.secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 3) {
                    Text(opt.title)
                        .font(.callout)
                        .fontWeight(isPicked ? .semibold : .regular)
                        .foregroundStyle(Color.primary)
                    Text(opt.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isPicked
                          ? SettingsView.brandAccent.opacity(0.10)
                          : SettingsView.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isPicked
                            ? SettingsView.brandAccent.opacity(0.45)
                            : SettingsView.cardBorder,
                            lineWidth: isPicked ? 1.0 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ConfigureProviderStep: View {
    @ObservedObject var model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Configure \(providerTitle).")
                .font(.title2)

            SettingsCard {
                switch model.pickedProvider {
                case "gemini":
                    geminiPanel
                case "bedrock":
                    bedrockPanel
                case "vertex":
                    vertexPanel
                case "azure":
                    azurePanel
                default:
                    Text("Skip cleanup — nothing to configure.")
                }
            }
        }
    }

    private var providerTitle: String {
        switch model.pickedProvider {
        case "gemini": return "Google Gemini"
        case "bedrock": return "AWS Bedrock"
        case "vertex": return "Google Vertex AI"
        case "azure": return "Azure OpenAI"
        default: return "your cleanup provider"
        }
    }

    private var geminiPanel: some View {
        // Phase 7 — when staticApiKeysAllowed=false, Gemini's API-key
        // auth path is blocked at runtime by makeProvider's
        // BlockedProvider sentinel. Hide the credential field in the
        // wizard so the user isn't confused into pasting a key that
        // won't be usable. The provider-picker step ideally would
        // route them away from Gemini entirely, but for now this
        // matches the Settings UI's gate.
        let geminiBlocked = ManagedConfig.isProviderAuthPathBlocked(provider: "gemini", authMode: nil)
        return VStack(alignment: .leading, spacing: 10) {
            if geminiBlocked {
                HStack(spacing: 6) {
                    ManagedIndicator(isManaged: true)
                    Text("API key entry disabled by your organization.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Gemini direct (Google AI Studio API) requires a static API key, which your organization has disabled. Choose a federated-auth provider (Vertex with ADC, Azure with Entra ID, or Bedrock with SSO) in the previous step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Get a free API key from Google AI Studio.")
                    .font(.callout)
                Link("Open Google AI Studio →",
                     destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.callout)
                SecureField("AIza…", text: $model.pendingGeminiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 400)
                Text("Stored in the macOS Keychain. You can also leave this blank and paste the key later in Settings — Parleq picks it up on the next dictation without a restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bedrockPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Auth mode", selection: $model.pendingAwsAuthMode) {
                Text("AWS CLI session").tag("sso")
                Text("Corporate sign-in").tag("oidc")
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Region:")
                    .frame(width: 70, alignment: .trailing)
                TextField("us-east-2", text: $model.pendingAwsRegion)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }

            if model.pendingAwsAuthMode == "oidc" {
                bedrockOIDCFields
            } else {
                Text("Sign in via the AWS CLI (one time): `aws configure sso` then `aws sso login --profile <name>`. Make sure you've enabled Bedrock model access in the AWS console for the region you're using.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Bedrock setup walkthrough →",
                     destination: URL(string: "https://parleq.app/docs/bedrock/")!)
                    .font(.callout)
                HStack {
                    Text("Profile:")
                        .frame(width: 70, alignment: .trailing)
                    TextField("(optional, e.g. work)", text: $model.pendingAwsProfile)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                Text("Static-credential mode (paste access keys directly) is available in Settings after setup. The AWS CLI session path is the recommended starting point.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Corporate-sign-in (OIDC) fields for the Bedrock wizard card:
    /// the shared issuer/client-ID config plus the IAM role ARN, then
    /// the honest restart-then-sign-in explainer.
    private var bedrockOIDCFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            wizardOIDCConfigFields
            wizardLabeledField(label: "Role ARN:",
                               placeholder: "arn:aws:iam::123456789012:role/parleq-bedrock",
                               text: $model.pendingAwsRoleArn,
                               maxWidth: 380,
                               pinnedKey: "awsRoleArn")
            corporateSignInExplainer
        }
    }

    private var vertexPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Auth mode", selection: $model.pendingVertexAuthMode) {
                Text("gcloud (ADC)").tag("adc")
                Text("Service account JSON").tag("serviceAccount")
                Text("Corporate sign-in").tag("oidcFederation")
                Text("Google account (OAuth)").tag("googleOAuth")
            }

            if model.pendingVertexAuthMode == "oidcFederation" {
                vertexOIDCFields
            } else if model.pendingVertexAuthMode == "googleOAuth" {
                vertexGoogleOAuthFields
            } else if model.pendingVertexAuthMode == "serviceAccount" {
                Text("Paste the JSON key from GCP IAM → Service Accounts → your SA → Keys → Add Key → JSON. The SA needs the `Vertex AI User` role on this project. Stored in the macOS Keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sign in via gcloud (one time): `gcloud auth application-default login` and `gcloud auth application-default set-quota-project <project-id>`. Vertex will use the access token Parleq mints from your CLI session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Vertex AI Gemini docs →",
                     destination: URL(string: "https://cloud.google.com/vertex-ai/generative-ai/docs/start/quickstarts/quickstart-multimodal")!)
                    .font(.callout)
            }

            HStack {
                Text("Project:")
                    .frame(width: 70, alignment: .trailing)
                TextField("my-gcp-project", text: $model.pendingVertexProject)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
            }
            HStack {
                Text("Region:")
                    .frame(width: 70, alignment: .trailing)
                TextField("us-central1", text: $model.pendingVertexRegion)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }

            if model.pendingVertexAuthMode == "serviceAccount" {
                // Phase 7 — when staticApiKeysAllowed=false, service-account
                // JSON entry is blocked at runtime. Hide the paste affordance
                // so a user doesn't waste effort pasting a key that won't work.
                let saBlocked = ManagedConfig.isProviderAuthPathBlocked(provider: "vertex", authMode: "serviceAccount")
                if saBlocked {
                    HStack(spacing: 6) {
                        ManagedIndicator(isManaged: true)
                        Text("Service account JSON entry disabled by your organization.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("Vertex with service-account JSON is a static-credential auth path, which your organization has disabled. Switch this picker to “gcloud (ADC)” to use Application Default Credentials instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Service account JSON:")
                        .font(.callout)
                    TextEditor(text: $model.pendingVertexServiceAccountJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 120)
                        .border(Color.secondary.opacity(0.3))
                }
            }
        }
    }

    /// Corporate-sign-in (OIDC) fields for the Vertex wizard card: the
    /// shared issuer/client-ID config plus the GCP workforce provider,
    /// then the honest restart-then-sign-in explainer. Project + region
    /// are still collected by the unconditional fields below the picker.
    private var vertexOIDCFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            wizardOIDCConfigFields
            wizardLabeledField(label: "Workforce provider:",
                               placeholder: "locations/global/workforcePools/POOL/providers/PROVIDER",
                               text: $model.pendingVertexWorkforceProvider,
                               maxWidth: 420,
                               pinnedKey: "vertexWorkforceProvider")
            corporateSignInExplainer
        }
    }

    /// Native Google sign-in (OAuth) fields for the Vertex wizard card.
    /// Just the shared issuer/client-ID config — NO workforce provider
    /// (there's no federation hop; the Google sign-in's access token is the
    /// Vertex bearer directly, the same trust model as gcloud ADC). Project
    /// + region come from the unconditional fields below the picker. No GCP
    /// organization is required.
    private var vertexGoogleOAuthFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            wizardOIDCConfigFields
            Text("Sign in with your Google account; the resulting OAuth access token (with the `cloud-platform` scope) is used as the Vertex bearer directly — no broker, no Workforce Identity Federation, no GCP organization required. Use an iOS-type OAuth client; request scopes `openid`, `email`, and `https://www.googleapis.com/auth/cloud-platform`. Restart, then sign in under Company Account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared corporate sign-in (OIDC) wizard helpers

    /// Issuer + client ID fields shared by the Bedrock + Vertex corporate
    /// sign-in cards. The wizard may be the FIRST surface to configure
    /// these; they render read-only with the org note when MDM-pinned.
    private var wizardOIDCConfigFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            wizardLabeledField(label: "Issuer URL:",
                               placeholder: "https://example.okta.com/oauth2/default",
                               text: $model.pendingOidcIssuer,
                               maxWidth: 380,
                               pinnedKey: "oidcIssuer")
            wizardLabeledField(label: "Client ID:",
                               placeholder: "0oaXXXXXXXXXXXX",
                               text: $model.pendingOidcClientID,
                               maxWidth: 280,
                               pinnedKey: "oidcClientID")
        }
    }

    /// Honest explainer for the wizard's corporate-sign-in path: the
    /// providers construct the OIDC session at launch, so the actual
    /// sign-in only becomes available after Parleq relaunches. The wizard
    /// saves config; sign-in lands under Settings → Company Account.
    private var corporateSignInExplainer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Parleq will save this configuration. After you finish and restart, open Settings → Company Account to sign in with your organization — that's where the one-time corporate sign-in happens. No keys are stored on this device; access is federated from your sign-in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A labeled wizard text field that disables itself + shows the org
    /// note when its `pinnedKey` is MDM-managed (mirrors the Settings
    /// read-only treatment).
    @ViewBuilder
    private func wizardLabeledField(label: String, placeholder: String,
                                    text: Binding<String>, maxWidth: CGFloat,
                                    pinnedKey: String) -> some View {
        let pinned = model.managedKeys.contains(pinnedKey)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 6) {
                Text(label)
                    .frame(width: 130, alignment: .trailing)
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: maxWidth)
                    .disabled(pinned)
                ManagedIndicator(isManaged: pinned)
            }
            if pinned {
                Text("Set by your organization.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 136)
            }
        }
    }

    private var azurePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Auth mode", selection: $model.pendingAzureAuthMode) {
                Text("API key").tag("apiKey")
                Text("Microsoft Entra ID").tag("azureAd")
            }
            .pickerStyle(.segmented)

            if model.pendingAzureAuthMode == "azureAd" {
                Text("Sign in via Azure CLI (one time): `az login`. Parleq will mint a short-lived OAuth bearer per session — no API key paste needed. Your account needs the `Cognitive Services OpenAI User` role on the resource.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Create an OpenAI resource in your Azure subscription, deploy a model under it (e.g. `gpt-4o-mini`), then paste the resource key + names below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("Azure OpenAI resource setup →",
                 destination: URL(string: "https://learn.microsoft.com/azure/ai-services/openai/how-to/create-resource")!)
                .font(.callout)

            HStack {
                Text("Resource:")
                    .frame(width: 90, alignment: .trailing)
                TextField("my-openai or full hostname", text: $model.pendingAzureResource)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
            }
            HStack {
                Text("Deployment:")
                    .frame(width: 90, alignment: .trailing)
                TextField("gpt-4o-mini", text: $model.pendingAzureDeployment)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
            }
            Text("Azure routes by deployment name. Parleq auto-detects the model family (standard vs. reasoning) from the model name, so `max_completion_tokens` vs `max_tokens` is handled automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.pendingAzureAuthMode == "apiKey" {
                // Phase 7 — when staticApiKeysAllowed=false, Azure apiKey
                // auth is blocked at runtime. Hide the API-key field so the
                // user isn't confused into pasting a key that won't work.
                let azureApiKeyBlocked = ManagedConfig.isProviderAuthPathBlocked(provider: "azure", authMode: "apiKey")
                if azureApiKeyBlocked {
                    HStack(spacing: 6) {
                        ManagedIndicator(isManaged: true)
                        Text("API key entry disabled by your organization.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("Azure with API-key auth is a static-credential path, which your organization has disabled. Switch this picker to “Microsoft Entra ID” to authenticate via your local `az login` session instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Text("API Key:")
                            .frame(width: 90, alignment: .trailing)
                        SecureField("32-character hex string", text: $model.pendingAzureKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                    }
                    Text("Stored in the macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AdvancedModelStep: View {
    @ObservedObject var model: WizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Advanced: vision-capable model for references")
                .font(.system(size: 16, weight: .semibold))

            Text("""
            When you attach windows or files to a dictation, Parleq sends them to a \
            model that can read or see them. By default that's the same model you just \
            configured. If you want, you can pick a more capable model for these \
            reference-aware turns.
            """)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                radioRow(
                    title: "Same as cleanup",
                    subtitle: "Use the model you just set up.",
                    selected: !model.advancedPickEnabled,
                    onSelect: {
                        model.advancedPickEnabled = false
                        model.pickedContextModel = nil
                    }
                )
                radioRow(
                    title: "Pick a different model",
                    subtitle: "Recommended if you'll attach images.",
                    selected: model.advancedPickEnabled,
                    onSelect: {
                        if !model.advancedPickEnabled {
                            model.advancedPickEnabled = true
                            if model.pickedContextModel == nil {
                                model.pickedContextModel = firstVisionModelOrCleanup
                            }
                        }
                    }
                )

                if model.advancedPickEnabled {
                    Picker("Context model", selection: $model.pickedContextModel) {
                        ForEach(configuredEntries, id: \.id) { entry in
                            HStack {
                                Text(entry.displayName)
                                if entry.supportsVision { Text("👁") }
                            }.tag(Optional(entry.id))
                        }
                    }
                    .labelsHidden()
                    .padding(.leading, 24)
                }
            }
        }
    }

    @ViewBuilder
    private func radioRow(
        title: String,
        subtitle: String,
        selected: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? SettingsView.brandAccent : Color.secondary)
                VStack(alignment: .leading) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The default cleanup-model identifier derived from the wizard's
    /// provider choice, mirroring the mapping in `WizardModel.commit()`.
    private var cleanupModelIdentifier: ModelIdentifier {
        let defaultModel: String
        switch model.pickedProvider {
        case "gemini":   defaultModel = "gemini-2.5-flash"
        case "vertex":   defaultModel = "gemini-2.5-flash"
        case "bedrock":  defaultModel = "openai.gpt-oss-120b-1:0"
        case "azure":    defaultModel = "gpt-4o-mini"
        default:         defaultModel = "gemini-2.5-flash"
        }
        return ModelIdentifier(provider: model.pickedProvider, model: defaultModel)
    }

    /// The pool of models the dropdown can offer. Includes the
    /// cleanup model plus every vision-capable model from the same
    /// provider family (deduped so the cleanup model isn't repeated
    /// if it's already one of the vision-capable entries).
    private var configuredEntries: [ModelPicker.ModelEntry] {
        let cleanupId = cleanupModelIdentifier
        var ids: [ModelIdentifier] = [cleanupId]

        // Add vision-capable models from the same provider family.
        // Same-provider auth services all of them — no additional
        // credential flow needed for Phase 2 scope.
        for visionId in VisionCapableCatalog.visionModels(forProvider: cleanupId.provider) {
            if visionId != cleanupId {
                ids.append(visionId)
            }
        }

        return ids.map { id in
            ModelPicker.ModelEntry(
                id: id,
                displayName: id.displayShort,
                supportsVision: ModelCapability.supportsVision(id)
            )
        }
    }

    private var firstVisionModelOrCleanup: ModelIdentifier {
        configuredEntries.first(where: { $0.supportsVision })?.id
            ?? configuredEntries[0].id
    }
}

private struct DoneStep: View {
    @ObservedObject var model: WizardModel
    @ObservedObject var localModelStore: LocalModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're set up.")
                .font(.title)
            Text("Click **Finish & Restart** to save your choices and apply them. The cleanup-provider choice only takes effect at app launch, so a quick relaunch is needed for it to land — Parleq will close, the helper waits for the process to exit, and the app reopens automatically.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("If you'd rather restart later on your own schedule, click **Finish later** — the config is saved either way, you just keep dictating against the previously-running provider until your next relaunch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // On-device cleanup model download status — only shown when the
            // user picked the on-device tier.
            if model.pickedTier == "local" {
                onDeviceStatusRow
                HStack(spacing: 0) {
                    Text("Uses Google Gemma 4 (Apache 2.0). ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Learn more", destination: URL(string: "https://ai.google.dev/gemma/docs/gemma_4_license")!)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("On first run after install, the speech model downloads in the background (~150 MB, 30–60 seconds). The menu-bar icon shows a download glyph until it's ready, then switches to a microphone. After that, dictations run locally — your audio never leaves the Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can change providers, add a custom dictionary, or rebind the hotkey from **Settings…** at any time. This setup is also reachable from **Run Setup…** in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    @ViewBuilder
    private var onDeviceStatusRow: some View {
        switch localModelStore.state {
        case .downloading:
            // Indeterminate (see the Settings card note): the library can't
            // report incremental bytes for the big shards, so a percentage would
            // freeze. Honest activity indicator + Cancel.
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading cleanup model (~4 GB, one-time)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { localModelStore.remove() }
                    .buttonStyle(.bordered)
            }
            Text("Dictation works without cleanup until the model finishes downloading.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("On-device cleanup model ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Download failed: \(message)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Retry download") {
                    localModelStore.remove()
                    localModelStore.download()
                }
                .font(.callout)
                Text("Dictation works without cleanup until the model downloads successfully.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .notDownloaded:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Starting download…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
