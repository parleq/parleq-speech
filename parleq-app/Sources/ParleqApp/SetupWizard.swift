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
//   - We do NOT block on STT model download. The sidecar takes
//     care of downloading on first /inference request; the menu
//     bar icon already surfaces "Initializing speech model…" via
//     #11. The wizard mentions the download is happening but
//     doesn't drive it explicitly.
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
    static let parleqRunSetupAgain = Notification.Name("ParleqRunSetupAgain")

    /// Posted whenever the user changes their microphone selection
    /// from any UI surface (today: the menu-bar Microphone submenu
    /// and Settings → Audio). userInfo carries `["uid": String]` —
    /// empty string for "System Default", otherwise a Core Audio
    /// device UID. ParleqApp subscribes and updates the
    /// AudioRecorder's runtime selection + the menu's checkmark
    /// state on receipt. Letting both UI surfaces fire the same
    /// notification keeps the two pickers in sync automatically.
    static let parleqMicrophoneSelectionChanged = Notification.Name("ParleqMicrophoneSelectionChanged")
}

/// Controller that owns the wizard NSWindow + SwiftUI hosting.
/// Mirrors SettingsWindowController's pattern.
@MainActor
final class SetupWizardController {
    private var window: NSWindow?

    /// Show the wizard, creating it on first call. Always re-centers
    /// on the active screen — this is a one-shot focused flow that
    /// should grab attention each time it opens, not restore wherever
    /// the user dragged it last.
    func show() {
        if window == nil {
            let view = SetupWizardView(onFinish: { [weak self] in
                self?.window?.close()
            })
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
    case done

    /// Short label used in the wizard's step-pill indicator.
    /// Three-or-fewer words so the five pills + dividers fit on
    /// one line at the wizard's standard width.
    var displayName: String {
        switch self {
        case .welcome:           return "Welcome"
        case .permissions:       return "Permissions"
        case .pickProvider:      return "Pick provider"
        case .configureProvider: return "Configure"
        case .done:              return "Done"
        }
    }
}

@MainActor
private final class WizardModel: ObservableObject {
    @Published var step: WizardStep = .welcome
    @Published var pickedProvider: String = "gemini"

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
    /// "standard" (gpt-4o family, default) or "reasoning" (gpt-5,
    /// o-series). Drives the request-shape branching in
    /// `AzureOpenAIProvider.buildRequestBody`. Azure routes by
    /// deployment name, not model name, so this has to be declared
    /// rather than inferred.
    @Published var pendingAzureFamily = "standard"
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

    /// Persist the wizard's choices to ~/.parleq/config.json + the
    /// macOS Keychain. Called when the user clicks Finish on the
    /// done screen. Skip-cleanup ("none") still writes the provider
    /// choice so the next launch knows the user picked it.
    func commit() {
        let (existing, _) = Config.load()
        var c = existing
        c.llmProvider = pickedProvider
        // Sensible default model per provider — matches Settings'
        // defaultModelByProvider table so the user gets a working
        // model id without typing one.
        switch pickedProvider {
        case "gemini": c.llmModel = "gemini-2.5-flash"
        case "vertex":
            c.llmModel = "gemini-2.5-flash"
            c.vertexProject = pendingVertexProject.trimmingCharacters(in: .whitespacesAndNewlines)
            c.vertexRegion = pendingVertexRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.vertexRegion.isEmpty { c.vertexRegion = "us-central1" }
            c.vertexAuthMode = ["adc", "serviceAccount"].contains(pendingVertexAuthMode)
                ? pendingVertexAuthMode : "adc"
        case "bedrock":
            c.llmModel = "openai.gpt-oss-120b-1:0"
            c.awsRegion = pendingAwsRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.awsRegion.isEmpty { c.awsRegion = "us-east-2" }
            let trimmed = pendingAwsProfile.trimmingCharacters(in: .whitespacesAndNewlines)
            c.awsProfile = trimmed.isEmpty ? nil : trimmed
            // Wizard hardcodes Bedrock to SSO. Bedrock API keys
            // (Bearer-token path) and static IAM creds need
            // explicit secret-paste sheets that don't fit the
            // wizard's flow well — those live in the Settings
            // window. New users get the SSO path here.
            c.awsAuthMode = "sso"
        case "azure":
            c.llmModel = "gpt-4o-mini"
            c.azureResource = pendingAzureResource.trimmingCharacters(in: .whitespacesAndNewlines)
            c.azureDeployment = pendingAzureDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
            c.azureAuthMode = ["apiKey", "azureAd"].contains(pendingAzureAuthMode)
                ? pendingAzureAuthMode : "apiKey"
            c.azureFamily = ["standard", "reasoning"].contains(pendingAzureFamily)
                ? pendingAzureFamily : "standard"
        default:
            break
        }
        c.wizardCompleted = true
        do {
            try Config.save(c)
        } catch {
            FileHandle.standardError.write(
                "[parleq] wizard: save failed: \(error)\n".data(using: .utf8) ?? Data()
            )
        }

        // Secrets land in the Keychain via KeychainStore — never in
        // the JSON config file. Each branch only writes if the
        // user actually picked the matching provider AND filled
        // the field; that way switching providers in the wizard
        // doesn't leave stale secrets behind for the unpicked
        // ones.
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

        // Drop in-memory secret state on commit so it doesn't sit in
        // a SwiftUI debug surface for the rest of the session.
        pendingGeminiKey = ""
        pendingAzureKey = ""
        pendingVertexServiceAccountJSON = ""
    }
}

private struct SetupWizardView: View {
    let onFinish: () -> Void
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
                        PickProviderStep(model: model)
                    case .configureProvider:
                        ConfigureProviderStep(model: model)
                    case .done:
                        DoneStep(model: model)
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
                Button("Skip Setup") {
                    let (existing, _) = Config.load()
                    var c = existing
                    c.wizardCompleted = true
                    try? Config.save(c)
                    onFinish()
                }
                .buttonStyle(.bordered)
                Spacer()
                if model.step != .welcome {
                    Button("Back") {
                        if let prev = WizardStep(rawValue: model.step.rawValue - 1) {
                            model.step = prev
                        }
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

    private var canAdvance: Bool {
        switch model.step {
        case .welcome: return true
        case .permissions:
            // Mic + Accessibility are load-bearing — Parleq's hotkey
            // does nothing useful without them. Open at Login stays
            // optional (the row is in the step but doesn't gate).
            let snap = permissionsModel.snapshot
            return snap.microphone == .granted && snap.accessibility == .granted
        case .pickProvider: return !model.pickedProvider.isEmpty
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
                return projectOK
            case "azure":
                return !model.pendingAzureResource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !model.pendingAzureDeployment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return true
            }
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
            // For "none" provider, skip the per-provider config screen.
            if model.pickedProvider == "none" {
                model.step = .done
            } else {
                model.step = .configureProvider
            }
        case .configureProvider:
            model.step = .done
        case .done:
            model.commit()
            onFinish()
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

    private struct Option: Identifiable {
        var id: String
        var title: String
        var blurb: String
    }
    private let options: [Option] = [
        .init(id: "gemini", title: "Google Gemini (recommended for personal use)",
              blurb: "Free tier covers most personal dictation. One API key from Google AI Studio. Fastest setup."),
        .init(id: "bedrock", title: "AWS Bedrock",
              blurb: "Anthropic Claude or OpenAI GPT-OSS, hosted in your AWS account. Use when your org blocks Google API calls. Auth via your existing AWS CLI session."),
        .init(id: "vertex", title: "Google Vertex AI",
              blurb: "Same Gemini models as the direct API but on the GCP control plane — IAM, audit logs, data residency. Auth via gcloud."),
        .init(id: "azure", title: "Azure OpenAI",
              blurb: "OpenAI GPT-4o family hosted in your Azure subscription. Use on Microsoft contracts (BAA, EU residency). Resource API key."),
        .init(id: "none", title: "None — skip cleanup, paste raw ASR",
              blurb: "Local dictation only. No cloud calls. Faster, fully private. Output won't be punctuated or polished — best when transcript content cannot leave the device."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a cleanup approach.")
                .font(.title2)
            Text("Parleq's local speech recognition gets the words; an LLM polishes them — adds punctuation, drops fillers, fixes obvious misrecognitions. You can swap providers later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(options) { opt in
                    providerRow(opt)
                }
            }
        }
    }

    private func providerRow(_ opt: Option) -> some View {
        let isPicked = (model.pickedProvider == opt.id)
        return Button {
            model.pickedProvider = opt.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isPicked ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isPicked ? SettingsView.brandAccent : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(opt.title)
                        .font(.body)
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
        VStack(alignment: .leading, spacing: 10) {
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

    private var bedrockPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in via the AWS CLI (one time): `aws configure sso` then `aws sso login --profile <name>`. Make sure you've enabled Bedrock model access in the AWS console for the region you're using.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("Bedrock setup walkthrough →",
                 destination: URL(string: "https://parleq.app/docs/bedrock/")!)
                .font(.callout)
            HStack {
                Text("Region:")
                    .frame(width: 70, alignment: .trailing)
                TextField("us-east-2", text: $model.pendingAwsRegion)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
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

    private var vertexPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Auth mode", selection: $model.pendingVertexAuthMode) {
                Text("gcloud (ADC)").tag("adc")
                Text("Service account JSON").tag("serviceAccount")
            }
            .pickerStyle(.segmented)

            if model.pendingVertexAuthMode == "serviceAccount" {
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
                Text("Service account JSON:")
                    .font(.callout)
                TextEditor(text: $model.pendingVertexServiceAccountJSON)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 120)
                    .border(Color.secondary.opacity(0.3))
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
            HStack {
                Text("Family:")
                    .frame(width: 90, alignment: .trailing)
                Picker("", selection: $model.pendingAzureFamily) {
                    Text("Standard (gpt-4o, gpt-4)").tag("standard")
                    Text("Reasoning (gpt-5, o-series)").tag("reasoning")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)
            }
            Text("Azure routes by deployment name; Parleq needs to know whether the underlying model is a reasoning model so it can build the correct request shape (`max_completion_tokens` vs `max_tokens`).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.pendingAzureAuthMode == "apiKey" {
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

private struct DoneStep: View {
    @ObservedObject var model: WizardModel

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
}
