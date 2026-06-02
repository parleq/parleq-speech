// parleq-app entry point — the AppKit App struct lives here so the
// executable target stays as thin as possible; all real types are
// in ParleqAppCore (which is testable from ParleqAppCoreTests).
//
// Parleq M3 entry point. The hotkey listener and the overlay both
// drive a single AppState that owns the per-utterance lifecycle. The
// pipeline (ASR → LLM cleanup → paste, or refine on re-trigger)
// runs through AppState's transitions.
//
// macOS will prompt for Accessibility on first run (CGEventTap +
// CGEvent.post) and for Microphone on first capture (AVAudioEngine).
// During `swift run` development both prompts attribute the request
// to the parent process; M5 wraps as a proper .app bundle with its
// own identity.

import AppKit
import Foundation
import Sparkle
import ParleqAppCore

@main
struct ParleqApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Install a minimal NSApp.mainMenu (App + Edit submenus). The
        // menu bar isn't drawn for an LSUIElement app, but AppKit's
        // key-equivalent matching still walks `mainMenu` to translate
        // ⌘V / ⌘X / ⌘C / ⌘A / ⌘Z into the corresponding `paste:` /
        // `cut:` / `copy:` / `selectAll:` / `undo:` selectors against
        // the focused text view. Without this, those shortcuts don't
        // reach text fields in the wizard or Settings (#24).
        MainActor.assumeIsolated {
            installApplicationMainMenu()
        }

        // Signal handlers for SIGTERM and SIGINT. These cover the
        // cases where an external process (kill, system shutdown,
        // logout) tries to terminate Parleq. Default SIGTERM
        // handling would rip the process down without giving AppKit
        // a chance to tear down windows or in-flight LLM streams a
        // chance to cancel. Routing through `NSApp.terminate(nil)`
        // takes the same path the menu-bar Quit item uses.
        for sig in [SIGTERM, SIGINT] {
            signal(sig) { _ in
                // signal handlers run on a non-main thread; route the
                // shutdown through the main run loop so AppKit
                // teardown runs on its expected actor.
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        }

        // Redirect stderr to ~/.parleq/app.log via dup2. Captures
        // every existing logStderr / log() call without touching
        // individual call sites. No-op when stderr is already a
        // TTY (developer running from terminal — dev sees live
        // output, can still `tail -f ~/.parleq/app.log` from
        // another terminal). Must run before any other logging
        // call so the output goes to the right place.
        LogFile.install()

        // Load runtime config (~/.parleq/config.json). Missing or
        // malformed config falls back silently to defaults; we log
        // which path was taken so a developer can tell.
        let (config, configSource) = Config.load()
        logStderr("[parleq] config: \(configSource)")
        ManagedConfig.logStartupSummary(managedKeys: config.managedKeys)

        // Kick off a background refresh of the LiteLLM pricing
        // table. No-ops if the on-disk cache is fresh (<24h) or a
        // refresh is already in flight; failure is non-fatal —
        // bundled defaults continue to serve. UI sees the new data
        // on its next read of UsageLedger.aggregate().
        PricingCache.shared.refreshIfStale()

        // Plumb config knobs to the modules that consume them.
        MainActor.assumeIsolated {
            Sounds.enabled = config.acousticFeedback
            Sounds.configure(startSound: config.startSound, endSound: config.endSound)
        }

        let recorder = AudioRecorder()
        recorder.continueOtherAudio = config.continueOtherAudio
        recorder.explicitInputDeviceUID = config.audioInputDeviceUID
        let recorderBox = RecorderBox()
        recorderBox.value = recorder
        logStderr("[parleq] audio: continue_other_audio=\(config.continueOtherAudio)")
        // One-shot diagnostic: dump every input device with its
        // identifying properties and which filter (if any) excluded
        // it from the Microphone submenu. Cheap (a few HAL queries),
        // runs once per launch, helps triage "weird mic option
        // showing up" reports without needing a debug build.
        logInputDeviceDiagnostics()
        // Pre-create the input AudioUnit + apply the device override
        // now so the first hotkey press doesn't have to do HAL routing
        // under user pressure (which is what was causing music to
        // briefly pause on the first capture only).
        recorder.prewarm()
        // Resolve the ASR endpoint into a (URL, useBundledPath) pair.
        // Three cases:
        //   1. asrEndpoint == bundledASREndpoint sentinel → bundled
        //      in-process path. The URL is unused but we initialize
        //      it to the sentinel string for log clarity.
        //   2. asrEndpoint is a valid URL → custom HTTP path against
        //      whatever the user pointed at.
        //   3. asrEndpoint is non-default but malformed (someone
        //      hand-edited `~/.parleq/config.json` to garbage) →
        //      route to the bundled path with a clear log warning
        //      instead of POSTing audio to a dead port-8767 fallback
        //      that nobody listens on post-v0.9.0.
        let useBundledASR: Bool
        let asrEndpointURL: URL
        if config.asrEndpoint == Config.bundledASREndpoint {
            useBundledASR = true
            asrEndpointURL = ASRClient.defaultEndpoint
        } else if let parsed = URL(string: config.asrEndpoint),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  parsed.host != nil {
            useBundledASR = false
            asrEndpointURL = parsed
            // Sanitize the endpoint to scheme://host[:port] before
            // logging — a managed asrEndpoint with a tokenized path
            // (e.g. .../inference?token=...) would otherwise leak
            // into ~/.parleq/app.log. Matches the sanitizer applied
            // by `ManagedConfig.logStartupSummary` for the managed
            // startup-summary line (#208).
            let safeHost = "\(scheme)://\(parsed.host ?? "?")" + (parsed.port.map { ":\($0)" } ?? "")
            logStderr("[parleq] ASR: using custom endpoint \(safeHost) (bundled FluidAudio will not be initialized)")
        } else {
            // Covers both "URL(string:) returned nil" and "parses but
            // isn't a usable HTTP/HTTPS endpoint with a host" — both
            // get the same fallback treatment because the HTTP code
            // path expects an OpenAI-style /inference server, and a
            // file:// or scheme-typo URL is no more useful than a
            // syntactically-broken one.
            useBundledASR = true
            asrEndpointURL = ASRClient.defaultEndpoint
            // Fallback path — the value didn't parse as a usable
            // http(s) URL with a host. Don't echo the raw config
            // value in case it contains a token (a tokenized URL
            // with a stray ? or # could still survive URL(string:)
            // but fail the scheme/host check). Log scheme/host only
            // when we have them; elide otherwise.
            let safeFallback: String = {
                if let parsed = URL(string: config.asrEndpoint),
                   let scheme = parsed.scheme {
                    let host = parsed.host ?? "?"
                    let port = parsed.port.map { ":\($0)" } ?? ""
                    return "\(scheme)://\(host)\(port)"
                }
                return "<unparseable>"
            }()
            logStderr("[parleq] ASR: config has an unusable asr.endpoint (\(safeFallback)); falling back to bundled in-process FluidAudio")
        }
        // In-process FluidAudio engine. Constructed only when the
        // user is on the bundled path so a custom `asr.endpoint`
        // configuration doesn't pay the ~1.5 GB resident cost of an
        // unused model load. `local.start()` is called below from
        // MainActor context.
        let local: LocalASR?
        if useBundledASR {
            let engine = MainActor.assumeIsolated { LocalASR() }
            MainActor.assumeIsolated {
                engine.preloadVocab = !config.customDictionary.isEmpty
            }
            local = engine
        } else {
            local = nil
        }
        let asr = ASRClient(endpoint: asrEndpointURL, local: local)
        // LLM cleanup is best-effort. If GEMINI_API_KEY isn't
        // available or any call fails, AppState falls back to
        // pasting the raw ASR transcript. The app must keep working
        // offline.
        //
        // makeProvider — builds a provider for a given ModelIdentifier
        // using the auth config already loaded. Same-provider context
        // models share the cleanup provider's credentials, so we call
        // this once for cleanup (logging "cleanup enabled") and once for
        // the context tier (logging "context-model enabled") when they
        // differ. The `label` parameter appears in log lines only.
        let makeProvider: (ModelIdentifier, String) -> (any LLMProvider)? = { id, label in
            // Phase 5 — runtime auth-path gate. Check BEFORE any provider
            // construction: if staticApiKeysAllowed=false is managed and the
            // provider's currently-configured auth path is static-key-based,
            // return a BlockedProvider sentinel instead of the real provider.
            // BlockedProvider.generateStreaming immediately throws
            // .authPathBlocked, which streamCleanupOrRefine routes through
            // cleanupFailureHint so the overlay shows an actionable message.
            let authModeForGate: String?
            switch id.provider.lowercased() {
            case "vertex":  authModeForGate = config.vertexAuthMode
            case "azure":   authModeForGate = config.azureAuthMode
            case "bedrock": authModeForGate = config.awsAuthMode
            default:        authModeForGate = nil
            }
            if ManagedConfig.isProviderAuthPathBlocked(provider: id.provider, authMode: authModeForGate) {
                let msg = "Your cleanup provider's auth path is disabled by your organization. Open Settings \u{2192} LLM and select a federated-auth provider (Azure with Entra ID, Bedrock with SSO, or Vertex with ADC)."
                logStderr("[parleq] LLM \(label) BLOCKED by staticApiKeysAllowed=false (provider=\(id.provider) authMode=\(authModeForGate ?? "api-key")). Will surface error to user.")
                return BlockedProvider(providerID: id.provider, model: id.model, message: msg)
            }

            switch id.provider.lowercased() {
            case "bedrock":
                if config.awsAuthMode.lowercased() == "bedrockapikey" || config.awsAuthMode == "bedrockApiKey" {
                    // Bearer-auth path bypasses Soto entirely
                    // (#22). Soto can't do bearer auth — it
                    // SigV4-signs every request from a credential
                    // provider — so we have a separate concrete
                    // provider (BedrockBearerProvider) that does
                    // plain HTTPS with the Bedrock API key from
                    // the Keychain.
                    if !KeychainStore.hasBedrockAPIKey {
                        logStderr("[parleq] bedrock: bedrock-api-key auth mode selected but no key set yet — set one in Settings → LLM → Set Bedrock API Key… (no restart needed)")
                    }
                    let p = BedrockBearerProvider(
                        model: id.model,
                        region: config.awsRegion
                    )
                    logStderr("[parleq] LLM \(label) (bedrock model=\(id.model) region=\(config.awsRegion) auth=bedrock-api-key)")
                    return p
                }
                let mode: BedrockProvider.AuthMode = (config.awsAuthMode.lowercased() == "static")
                    ? .static : .sso
                do {
                    let p = try BedrockProvider(
                        model: id.model,
                        region: config.awsRegion,
                        profileName: config.awsProfile,
                        authMode: mode
                    )
                    let modeLabel = (mode == .static) ? "static-keychain" : "sso"
                    logStderr("[parleq] LLM \(label) (bedrock model=\(id.model) region=\(config.awsRegion) profile=\(config.awsProfile ?? "<default>") auth=\(modeLabel))")
                    return p
                } catch {
                    logStderr("[parleq] LLM \(label) failed (bedrock init failed): \(error). Will paste raw ASR.")
                    return nil
                }
            case "vertex":
                let project = config.vertexProject.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !project.isEmpty else {
                    logStderr("[parleq] LLM \(label) disabled (vertex provider selected but no GCP project configured — set Settings → LLM → Project). Will paste raw ASR.")
                    return nil
                }
                let mode: VertexProvider.AuthMode = (config.vertexAuthMode == "serviceAccount")
                    ? .serviceAccount : .adc
                if mode == .serviceAccount, !KeychainStore.hasVertexServiceAccountJSON {
                    logStderr("[parleq] vertex: no service-account JSON set yet — set one in Settings → LLM → Set Service Account JSON… (no restart needed)")
                }
                let p = VertexProvider(
                    model: id.model,
                    project: project,
                    region: config.vertexRegion,
                    anthropicRegion: config.vertexAnthropicRegion,
                    authMode: mode
                )
                let modeLabel = (mode == .serviceAccount) ? "service-account-jwt" : "gcloud-adc"
                logStderr("[parleq] LLM \(label) (vertex model=\(id.model) project=\(project) region=\(config.vertexRegion) anthropic_region=\(config.vertexAnthropicRegion) auth=\(modeLabel))")
                return p
            case "azure":
                let resource = config.azureResource.trimmingCharacters(in: .whitespacesAndNewlines)
                let deployment = config.azureDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !resource.isEmpty, !deployment.isEmpty else {
                    logStderr("[parleq] LLM \(label) disabled (azure provider selected but resource or deployment is empty — set Settings → LLM → Azure resource + deployment). Will paste raw ASR.")
                    return nil
                }
                let authMode: AzureOpenAIProvider.AuthMode = (config.azureAuthMode == "azureAd")
                    ? .azureAd : .apiKey
                if authMode == .apiKey, !KeychainStore.hasAzureAPIKey {
                    logStderr("[parleq] azure: no API key set yet — set one in Settings → LLM → Set Azure API Key… (no restart needed)")
                }
                // Family is auto-detected per-request inside
                // AzureOpenAIProvider.buildRequestBody using
                // isOpenAIReasoningModel, so each tier (cleanup +
                // context) picks the right parameter shape independently
                // from its own model id.
                let p = AzureOpenAIProvider(
                    model: id.model,
                    resource: resource,
                    deployment: deployment,
                    apiVersion: config.azureApiVersion,
                    authMode: authMode
                )
                let authModeLabel = (authMode == .azureAd) ? "azure-ad-cli" : "api-key"
                let familyLabel = isOpenAIReasoningModel(id.model) ? "reasoning" : "standard"
                logStderr("[parleq] LLM \(label) (azure family=\(familyLabel) resource=\(resource) deployment=\(deployment) apiVersion=\(config.azureApiVersion) auth=\(authModeLabel))")
                return p
            case "openai":
                // OpenAI direct (api.openai.com). No resource / deployment
                // indirection — the model field in the body is the routing
                // key. API key is resolved per-request from Keychain inside
                // the provider, matching the Gemini/LLMClient pattern:
                // a key set in Settings takes effect on the next dictation
                // without restart.
                if !KeychainStore.hasOpenAIAPIKey {
                    logStderr("[parleq] openai: no API key set yet — set one in Settings → Cleanup → Set OpenAI API Key… (no restart needed)")
                }
                let p = OpenAIProvider(model: id.model)
                logStderr("[parleq] LLM \(label) (openai model=\(id.model))")
                return p
            case "none":
                // Explicit user choice. Don't log this as a problem —
                // it's the configured behavior. AppState already
                // handles llm == nil.
                logStderr("[parleq] LLM \(label) disabled (provider=none — user opted out of cleanup; will paste raw ASR)")
                return nil
            default:
                // "gemini" and any unknown future tag (e.g. a config
                // written by a newer build) — fall through to the
                // direct Gemini API path. LLMClient.init no longer
                // throws; the API key is resolved per-request, so
                // the user can set the key in Settings after launch
                // and have it pick up on the next dictation. If no
                // key is ever configured, the per-request resolve
                // throws missingAPIKey and AppState's existing
                // best-effort fallback pastes the raw ASR transcript.
                let p = LLMClient(model: id.model)
                logStderr("[parleq] LLM \(label) (gemini model=\(id.model), thinkingBudget=0)")
                if !ProcessInfo.processInfo.environment.keys.contains("GEMINI_API_KEY")
                    && !KeychainStore.hasGeminiAPIKey {
                    logStderr("[parleq] gemini: no API key set yet — set one in Settings → LLM → Set Gemini API Key… (no restart needed)")
                }
                return p
            }
        }

        let cleanupId = ModelIdentifier(provider: config.llmProvider, model: config.llmModel)
        let llm = makeProvider(cleanupId, "cleanup enabled")

        // Context-model tier. Build a second provider only when
        // config.contextModel is set AND differs from the cleanup
        // model. makeProvider switches on ctxId.provider and reads
        // auth for THAT provider from the Keychain, so cross-provider
        // pairs (e.g. Gemini cleanup + Bedrock context) just work —
        // each provider's credentials are resolved independently.
        let contextLLM: (any LLMProvider)? = {
            // When cleanup is disabled ("none") the whole LLM path is
            // off — don't build a context provider either, or it would
            // keep servicing reference-aware turns and defeat the
            // "skip cleanup, paste raw" privacy guarantee. (The routing
            // in Config.modelForInvocation won't select it either; this
            // also avoids instantiating a live cloud provider.)
            guard config.llmProvider != "none" else { return nil }
            guard let ctxId = config.contextModel, ctxId != cleanupId else {
                return nil   // nil → AppState falls back to llm for context turns
            }
            return makeProvider(ctxId, "context-model enabled")
        }()

        let overlay = OverlayWindow()
        let stateBox = StateBox()
        // AppState lives on @MainActor; we have to instantiate it
        // synchronously on the main thread. The closure capture by
        // the listener will dispatch back onto MainActor since
        // AppState's methods are @MainActor.
        MainActor.assumeIsolated {
            stateBox.value = AppState(
                recorder: recorder,
                asr: asr,
                llm: llm,
                contextLLM: contextLLM,
                overlay: overlay,
                autoAcceptSeconds: config.autoAcceptSeconds,
                trailingSpaceEnabled: config.trailingSpace,
                noTrailingSpaceAppBundleIDs: config.noTrailingSpaceAppBundleIDs
            )
        }

        // Resolve the hotkey binding from config. Unknown bindings
        // log a warning and fall back to right-Option so the app
        // doesn't fail to launch on a typo.
        let binding: HotkeyBinding
        if let parsed = HotkeyBinding.parse(config.hotkeyBinding) {
            binding = parsed
            logStderr("[parleq] hotkey: \(binding.displayName) (config: \(config.hotkeyBinding))")
        } else {
            binding = .defaultBinding
            logStderr("[parleq] hotkey config \"\(config.hotkeyBinding)\" not recognized — using default \(binding.displayName)")
        }
        // Reference Windows v2 latched-compose: the overlay's hint
        // strip teaches the gesture using the user's actual hotkey
        // label ("Press ⌥-Right to dictate or release to send …").
        // Set on the overlay's model so SwiftUI re-renders the strip
        // reactively whenever composeState changes.
        MainActor.assumeIsolated {
            overlay.model.hotkeyDisplayName = binding.displayName
        }

        // Menu-bar status item: an LSUIElement app has no Dock icon
        // and no top-of-screen menu, so this is the user's only
        // always-visible handle to confirm the app is running and
        // quit it cleanly. Wired into AppState's phase callback so
        // the icon and "Status: …" line stay in sync.
        let menuBox = MenuBox()
        // SettingsBox removed in 0.14.0 PR 2 (#217) — the legacy
        // SettingsWindowController has been deleted entirely. The
        // canonical SettingsModel now lives in
        // ParleqAppWindowController.shared.settingsModel.
        let wizardBox = WizardBox()
        let updaterBox = UpdaterBox()
        MainActor.assumeIsolated {
            logStderr("[parleq] login-item: status=\(LoginItem.statusDescription), supported=\(LoginItem.isSupported), bundle=\(Bundle.main.bundlePath)")
            let menuBar = MenuBar(hotkeyDisplayName: binding.displayName)
            menuBox.value = menuBar
            // 0.14.0+ : Parleq's primary UI is the new app shell
            // (NavigationSplitView with Recent / Stats / Settings /
            // About). The legacy SettingsWindowController was
            // removed in PR 2 (#217); ParleqAppWindowController
            // is the only window controller for the new shell.
            let wizard = SetupWizardController()
            wizardBox.value = wizard
            // Sparkle auto-update controller. `startingUpdater: true`
            // arms Sparkle's standard background-check loop (default
            // 24h interval) which, on first launch after the user
            // opts in, prompts "Would you like Parleq to check for
            // updates automatically?" The Settings → Updates section
            // and the menu's "Check for Updates…" item both target
            // this same controller. Retained for the app's lifetime
            // via the UpdaterBox @unchecked-Sendable shim so menu /
            // settings closures can capture it without a Swift 6
            // strict-concurrency complaint.
            // MDM autoUpdateEnabled enforcement: when an admin pushes
            // autoUpdateEnabled=false we must apply the policy BEFORE
            // Sparkle starts its background-check loop, otherwise the
            // first periodic-check tick could fire between init and
            // the policy assignment. We init the controller with
            // startingUpdater:false, set automaticallyChecksForUpdates
            // from MDM (or leave Sparkle's default for unmanaged),
            // then start the updater manually. Manual menu-bar
            // "Check for Updates..." still works either way — that
            // path is independent of the automatic-checks setting.
            let managedAutoUpdate = ManagedConfig.managedBool(forKey: "autoUpdateEnabled")
            let updaterController = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            if let managed = managedAutoUpdate {
                updaterController.updater.automaticallyChecksForUpdates = managed
                // Phase 7 hardening — when autoUpdateEnabled=true is
                // pushed by MDM, also clear any user-domain skip-version
                // defaults so a previously-skipped version can't keep
                // the user pinned past the forced-update policy.
                // Sparkle 2.x stores skip state across THREE keys (see
                // `[SPUSkippedUpdate clearSkippedUpdateForHost:]` in
                // Sparkle/SPUSkippedUpdate.m): SUSkippedVersion (legacy
                // / minor-version), SUSkippedMajorVersion, and
                // SUSkippedMajorSubreleaseVersion. Clearing only the
                // legacy key leaves the major-skip vector open — a
                // user can write SUSkippedMajorVersion=99 to silently
                // defeat the forced auto-update across a major
                // transition. Clear all three to match Sparkle's own
                // clear semantics. Clearing on launch costs the user
                // only a re-prompt for any update they legitimately
                // want to skip.
                if managed {
                    UserDefaults.standard.removeObject(forKey: "SUSkippedVersion")
                    UserDefaults.standard.removeObject(forKey: "SUSkippedMajorVersion")
                    UserDefaults.standard.removeObject(forKey: "SUSkippedMajorSubreleaseVersion")
                }
            }
            // MDM sparkleUpdateFeedURL enforcement: when an admin pushes a
            // managed feed URL, we redirect Sparkle's appcast to that URL
            // BEFORE startUpdater() so the very first background check uses
            // the managed URL.
            //
            // CRITICAL SECURITY INVARIANT: SUPublicEDKey in Info.plist
            // still authoritatively gates which Sparkle signatures are
            // valid. The managed feed URL changes WHERE the appcast comes
            // from, not WHO can sign it. An attacker who hosts a fake
            // appcast at the managed URL cannot push an arbitrary binary
            // without the maintainer's Ed25519 private key. The EdDSA
            // signature check cannot be bypassed by an MDM profile.
            //
            // Note on setFeedURL: Sparkle's preferred pattern for dynamic
            // feed URLs is SPUUpdaterDelegate.feedURLStringForUpdater(_:).
            // setFeedURL is technically deprecated, but this is a one-time
            // pre-start configuration call from a known-managed source,
            // not a runtime alternation between multiple feeds — the
            // deprecation warning is not actionable here without adding a
            // persistent delegate class. The API remains functional.
            //
            // IMPORTANT: setFeedURL persists the URL to user defaults.
            // We must explicitly clear the persisted value on every
            // launch where there ISN'T a successfully-validated
            // managed URL — otherwise:
            //   1. An admin who briefly pushed a managed feed URL and
            //      then removed the MDM profile would have the
            //      managed URL stick on every fleet machine forever,
            //      defeating policy removal.
            //   2. A previously-rejected managed value would still
            //      route updates to whatever was last persisted,
            //      contradicting the "using Info.plist SUFeedURL
            //      instead" log message.
            //   3. A developer who ran the local test scenario for
            //      sparkleUpdateFeedURL with a fixture value
            //      (e.g. https://example.com/appcast.xml) would get
            //      perpetual 404s on Check for Updates afterwards
            //      until manually running `defaults delete
            //      com.parleq.app SUFeedURL`.
            // The clearFeedURLFromUserDefaults API is the documented
            // way to drop the persisted URL and fall back to the
            // Info.plist SUFeedURL.
            if let rawFeedURL = ManagedConfig.managedString(forKey: "sparkleUpdateFeedURL") {
                let trimmed = rawFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                // Strict validation (centralized via ManagedConfig.validateFeedURL):
                //   - scheme is exactly "https" (case-insensitive)
                //   - non-empty host
                //   - no embedded userinfo (user:password@) — those would
                //     ship credentials to the appcast server and leak via
                //     logs / URL inspection. An admin pushing such a URL
                //     is misconfiguring; reject and fall back.
                //   - no query / fragment containing token-like params
                //     (we just reject any url with a non-nil query for
                //     simplicity — appcasts are static XML, no query needed).
                if let feedURL = ManagedConfig.validateFeedURL(trimmed) {
                    updaterController.updater.setFeedURL(feedURL)
                    // Log only the scheme+host so any path/query/userinfo
                    // doesn't leak via app.log. The user gets confirmation
                    // that a managed feed is active without exposing the
                    // full URL to anyone who tails the log.
                    let safeOrigin = "\(feedURL.scheme ?? "https")://\(feedURL.host ?? "?")"
                    logStderr("[parleq] sparkleUpdateFeedURL: accepted managed feed at \(safeOrigin) — appcast will be fetched from this origin; EdDSA signature verification remains enforced by Info.plist SUPublicEDKey")
                } else {
                    updaterController.updater.clearFeedURLFromUserDefaults()
                    logStderr("[parleq] sparkleUpdateFeedURL: rejected managed value — must be a valid https:// URL with a non-empty host, no embedded credentials, and no query parameters. Cleared any previously-persisted feed URL; Sparkle will use Info.plist SUFeedURL.")
                }
            } else {
                updaterController.updater.clearFeedURLFromUserDefaults()
            }
            updaterController.startUpdater()
            updaterBox.value = updaterController
            // Make the live updater visible to Settings → Updates so
            // its toggle reads the real `automaticallyChecksForUpdates`
            // state rather than an @AppStorage guess. SparkleHolder
            // is a process-wide write-once shim; ParleqApp.main is
            // the only writer.
            SparkleHolder.controller = updaterController
            // Menu bar's "Show Parleq…" (renamed from "Settings…" in
            // 0.14.0, see MenuBar.swift) opens the new app shell.
            // Defaults to whichever section was last visible
            // (.recent on first open).
            menuBar.onOpenSettings = { ParleqAppWindowController.shared.show() }
            menuBar.onOpenWizard = { wizard.show() }
            menuBar.onCheckForUpdates = { [weak updaterController] in
                updaterController?.checkForUpdates(nil)
            }
            // In 0.13.0 the "View Managed Configuration…" menu item
            // was removed (#213) — the Compliance Audit dialog is now
            // launched from Settings → Privacy & Features. Same
            // shared window controller, just a different entry point.

            // Microphone selector (#25). The menu submenu writes the
            // chosen UID back via this callback; we update the
            // recorder's runtime selection AND persist it to config
            // so the next launch remembers it. Empty string = System
            // Default + auto-route heuristic (the pre-#25 behavior).
            menuBar.currentMicrophoneUID = config.audioInputDeviceUID
            menuBar.onMicrophoneSelected = { uid in
                recorder.explicitInputDeviceUID = uid
                let (existing, _) = Config.load()
                var c = existing
                c.audioInputDeviceUID = uid
                try? Config.save(c)
                logStderr("[parleq] audio: microphone selection → \(uid.isEmpty ? "<system default>" : uid)")
            }
            stateBox.value?.onPhaseChanged = { phase in
                menuBar.setPhase(phase)
            }
            // Surface cleanup failures (or clear them) on the
            // menu-bar status icon and dropdown (#28). Non-nil
            // message → amber bars + dismissable "Cleanup failed —
            // <message>" row; nil → cleared.
            stateBox.value?.onCleanupResult = { message in
                menuBar.setCleanupFailure(message)
            }
            // First-launch wizard auto-show (#21 step 6). Skipping
            // here keeps existing users (config.wizardCompleted ==
            // true) out of the path entirely. Test users who want
            // to re-run the flow can do so from the menu bar or
            // via Settings → "Run Setup Again".
            if !config.wizardCompleted {
                logStderr("[parleq] wizard: launching first-run setup (config.wizardCompleted=false)")
                wizard.show()
            }

            // Settings → "Run Setup Again" posts this notification
            // rather than holding a direct reference to the wizard
            // controller. Forwarding it here keeps the SettingsModel
            // ignorant of the wizard's window lifecycle.
            NotificationCenter.default.addObserver(
                forName: .parleqRunSetupAgain,
                object: nil,
                queue: .main
            ) { [weak wizardBox] _ in
                MainActor.assumeIsolated {
                    wizardBox?.value?.show()
                }
            }

            // Settings → Updates → "Check for Updates Now" posts this
            // notification. Same decoupling rationale as the wizard
            // case: SettingsView doesn't need a reference to the
            // Sparkle controller.
            NotificationCenter.default.addObserver(
                forName: .parleqCheckForUpdates,
                object: nil,
                queue: .main
            ) { [weak updaterBox] _ in
                MainActor.assumeIsolated {
                    updaterBox?.value?.checkForUpdates(nil)
                }
            }

            // Microphone selection changed — fired by either UI
            // surface (menu-bar Microphone submenu OR Settings →
            // Audio picker). Updates the recorder's runtime
            // selection and keeps the menu's checkmark state in
            // sync with whichever surface drove the change. The
            // posting surface is responsible for persisting to
            // Config (menu does it directly via its callback;
            // Settings does it via SettingsModel.save). This
            // listener is purely about reflecting the change in
            // the in-memory state of the OTHER surfaces.
            NotificationCenter.default.addObserver(
                forName: .parleqMicrophoneSelectionChanged,
                object: nil,
                queue: .main
            ) { [weak menuBox, weak recorderBox] note in
                let uid = (note.userInfo?["uid"] as? String) ?? ""
                MainActor.assumeIsolated {
                    recorderBox?.value?.explicitInputDeviceUID = uid
                    menuBox?.value?.currentMicrophoneUID = uid
                }
            }

            // Restart-initiated Settings reopen. ParleqApp_relaunch()
            // sets this flag before NSApp.terminate so the new process
            // knows to show the Settings window on launch. We read +
            // clear the flag here (inside MainActor.assumeIsolated so
            // the show() call is actor-safe) and post the notification
            // that the subscriber below handles. The notification
            // dispatch is deferred to the next runloop pass via an
            // async Task so all other startup wiring (status item,
            // hotkey, etc.) completes first.
            NotificationCenter.default.addObserver(
                forName: .parleqOpenSettings,
                object: nil,
                queue: .main
            ) { _ in
                // 0.14.0+ : go through the app shell controller's
                // singleton directly instead of holding a weak
                // reference to the legacy SettingsBox. The legacy
                // SettingsWindowController is on its way out (PR 2
                // deletes it) and isn't strongly retained anywhere
                // we can rely on under optimized builds — a release
                // could nil out `settingsBox?.value` between
                // observer registration and notification fire,
                // making the restart-reopen path a silent no-op.
                // The shell controller is a process-wide singleton
                // and always reachable.
                MainActor.assumeIsolated {
                    ParleqAppWindowController.shared.show(section: .settings)
                }
            }
            if UserDefaults.standard.bool(forKey: "parleq.reopenSettingsOnLaunch") {
                UserDefaults.standard.removeObject(forKey: "parleq.reopenSettingsOnLaunch")
                Task { @MainActor in
                    // Yield once to let the current MainActor.assumeIsolated
                    // block finish and the runloop cycle complete before
                    // opening the window. Without this, show() runs while
                    // the status item and hotkey listener haven't been
                    // wired yet (they're set up in the outer
                    // MainActor.assumeIsolated block below).
                    await Task.yield()
                    NotificationCenter.default.post(name: .parleqOpenSettings, object: nil)
                }
            }
        }

        let soundBox = SoundBox()
        MainActor.assumeIsolated {
            soundBox.value = HotkeySoundDebouncer()
        }
        let listener = HotkeyListener(
            binding: binding,
            onKeyDown: { event in
                Task { @MainActor in
                    soundBox.value?.scheduleStart()
                    stateBox.value?.hotkeyDown(
                        isDoubleTapHold: event.isDoubleTapHold,
                        isShiftHeld: event.isShiftHeld
                    )
                }
            },
            onKeyUp: { upEvent in
                Task { @MainActor in
                    // In quick mode the visible paste is the end-cue;
                    // skip the Pop so it doesn't collide with the
                    // BT-routing click on engine.stop() and sound
                    // doubled (#6). Snapshot quickMode BEFORE
                    // hotkeyUp runs, since that's the path that
                    // eventually clears it.
                    let suppress = stateBox.value?.quickMode ?? false
                    soundBox.value?.endOrCancel(suppressEnd: suppress)
                    stateBox.value?.hotkeyUp(
                        spaceWasPressedDuringHold: upEvent.spaceWasPressedDuringHold
                    )
                }
            },
            onSpacePressed: {
                // Edge-triggered the first time Space lands during a
                // hotkey hold. Hop to MainActor so AppState can mutate
                // its overlay model — the listener's callback runs on
                // the CGEvent tap thread.
                Task { @MainActor in
                    stateBox.value?.spacePressedDuringHold()
                }
            },
            onPPressed: {
                // 0.14.0 "hold-hotkey + P = Show Parleq" gesture.
                // Edge-triggered the first time P lands during a
                // dictation-hotkey hold; the listener has already
                // consumed the P keyDown + matching keyUp so the
                // focused app doesn't see a stray P character (or
                // π, when the hotkey is Option). AppState cancels
                // the in-flight capture and summons the app window.
                Task { @MainActor in
                    stateBox.value?.pPressedDuringHold()
                }
            },
            onCPressed: {
                // "hold-hotkey + C = attach current window as a
                // reference" gesture. Edge-triggered the first time C
                // lands during a dictation-hotkey hold; the listener
                // has already consumed the C keyDown + matching keyUp
                // so the focused app doesn't see a stray ç. AppState
                // captures the frontmost window as a reference.
                Task { @MainActor in
                    stateBox.value?.cPressedDuringHold()
                }
            }
        )
        do {
            try listener.start()
        } catch {
            logStderr("[parleq] hotkey listener failed: \(error)")
            exit(1)
        }
        // Sync the hold-hotkey+P gesture threshold to the configured
        // overlay-show delay at launch, and keep it live thereafter:
        // SettingsModel.save() posts .parleqOverlayDelayChanged with
        // the new ms value when the user edits the delay, so the
        // gesture threshold tracks the overlay delay without a
        // restart (#56). The observer captures `listener` strongly —
        // intentional: the listener lives for the whole app session.
        // Sync the configurable overlay-show delay (#56) into the two
        // launch-time singletons that can't read it per-dictation the
        // way AppState does: the hotkey listener's P-gesture threshold
        // and the start-sound debouncer's delay. Set at launch from
        // config + kept live via .parleqOverlayDelayChanged (posted by
        // SettingsModel.save). Both fire with the overlay so the
        // audio, visual, and gesture cues engage at one moment.
        let initialDelay = TimeInterval(config.overlayShowDelayMs) / 1000.0
        listener.setPHoldThreshold(initialDelay)
        MainActor.assumeIsolated {
            soundBox.value?.setStartDelay(initialDelay)
        }
        let listenerBox = ListenerBox()
        listenerBox.value = listener
        NotificationCenter.default.addObserver(
            forName: .parleqOverlayDelayChanged,
            object: nil,
            queue: .main
        ) { [listenerBox, weak soundBox] note in
            // listenerBox captured STRONGLY: it has no other strong
            // owner after this registration, and the observer lives
            // for the app session, so a weak capture would let the
            // box deallocate and silently stop live threshold updates.
            // No retain cycle — the box doesn't reference the observer.
            let ms = (note.userInfo?["ms"] as? Int) ?? 200
            let seconds = TimeInterval(ms) / 1000.0
            MainActor.assumeIsolated {
                listenerBox.value?.setPHoldThreshold(seconds)
                soundBox?.value?.setStartDelay(seconds)
            }
        }

        // Kick off in-process FluidAudio model download + load (or
        // skip everything when the user has chosen a custom
        // `asr.endpoint`). The user's first dictation gates on
        // `isReady`; until it flips true, hotkey presses surface the
        // "Initializing…" overlay instead of starting a black-hole
        // capture against an unloaded model.
        MainActor.assumeIsolated {
            if let local {
                stateBox.value?.isSystemReady = { [weak local] in
                    local?.isReady ?? false
                }
                local.onReadyChanged = { ready in
                    menuBox.value?.setASRReady(ready)
                    if ready {
                        // Hide the "Initializing…" overlay if the
                        // user pressed the hotkey during the load
                        // window.
                        stateBox.value?.notifySystemReady()
                    }
                }
                local.onLoadFailedChanged = { failed in
                    menuBox.value?.setASRLoadFailed(failed)
                }
                local.onProgressChanged = { progress in
                    stateBox.value?.notifyDownloadProgress(progress)
                }
                menuBox.value?.setASRReady(local.isReady)
                menuBox.value?.setASRLoadFailed(local.loadFailed)
                stateBox.value?.notifyDownloadProgress(local.downloadProgress)
                // In 0.13.0 the "Reset ASR" menu item moved to
                // Settings → Advanced (#214). Wire the closure
                // directly into the app shell's SettingsModel so the
                // button has work to call. In 0.14.0 PR 2 the legacy
                // SettingsBox forwarding intermediary was removed
                // (#217).
                ParleqAppWindowController.shared.setOnResetASR { [weak local] in
                    local?.reset()
                }
                local.start()
            } else {
                // Custom asr.endpoint: user owns their external
                // server's lifecycle. Mark ready immediately so the
                // hotkey isn't gated; if the server isn't reachable,
                // ASR calls will fail with a connection error that
                // shows in the log.
                stateBox.value?.isSystemReady = { true }
                menuBox.value?.setASRReady(true)
            }
        }

        logStderr("[parleq] running. Press-and-hold \(binding.displayName) to dictate. Ctrl-C to quit.")
        app.run()
        _ = listener
    }
}

// StateBox holds the AppState reference so the hotkey closures can
// reach it. The hotkey listener is created before AppState (because
// AppState construction is @MainActor) and the closures run on the
// main run loop, so a class-typed wrapper sidesteps Swift 6
// sendability without forcing AppState itself to be Sendable.
private final class StateBox: @unchecked Sendable {
    var value: AppState?
}

// SoundBox: same shape as StateBox. The hotkey listener's closures
// are @Sendable, but HotkeySoundDebouncer is @MainActor — wrapping
// it in a class lets the closures capture the box and reach the
// MainActor instance via the main run loop (where the closures
// already execute).
private final class SoundBox: @unchecked Sendable {
    var value: HotkeySoundDebouncer?
}

// MenuBox wraps the @MainActor MenuBar so the closures wired to
// AppState.onPhaseChanged (which runs from a @MainActor didSet) can
// hold a reference without tripping Swift 6 Sendable analysis.
private final class MenuBox: @unchecked Sendable {
    var value: MenuBar?
}

// SettingsBox removed in 0.14.0 PR 2 (#217) — the legacy
// SettingsWindowController has been deleted entirely; the canonical
// SettingsModel now lives on ParleqAppWindowController.shared, which
// is the only window controller for the app shell.

// WizardBox holds the SetupWizardController for the same reason —
// re-opens from the menu bar's "Run Setup…" item should reuse
// the same window instance.
private final class WizardBox: @unchecked Sendable {
    var value: SetupWizardController?
}

// RecorderBox holds the AudioRecorder so observer closures
// (NotificationCenter handlers in particular, which require
// @Sendable closures) can capture a Sendable wrapper instead of
// the non-Sendable recorder directly. The recorder's actual
// state mutations all happen on MainActor at the call sites we
// route through.
private final class RecorderBox: @unchecked Sendable {
    var value: AudioRecorder?
}

// UpdaterBox holds the Sparkle SPUStandardUpdaterController for
// the app's whole runtime. Sparkle's controller is @MainActor and
// would otherwise be eligible for ARC release after the
// `MainActor.assumeIsolated` block returns; pinning it here keeps
// the auto-update background loop alive and gives menu / settings
// closures a Sendable handle to capture.
private final class UpdaterBox: @unchecked Sendable {
    var value: SPUStandardUpdaterController?
}

private final class ListenerBox: @unchecked Sendable {
    var value: HotkeyListener?
}

private func logStderr(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
