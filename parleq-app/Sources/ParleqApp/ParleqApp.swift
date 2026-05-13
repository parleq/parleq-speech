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

        // Kick off a background refresh of the LiteLLM pricing
        // table. No-ops if the on-disk cache is fresh (<24h) or a
        // refresh is already in flight; failure is non-fatal —
        // bundled defaults continue to serve. UI sees the new data
        // on its next read of UsageLedger.aggregate().
        PricingCache.shared.refreshIfStale()

        // Plumb config knobs to the modules that consume them.
        MainActor.assumeIsolated {
            Sounds.enabled = config.acousticFeedback
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
            logStderr("[parleq] ASR: using custom endpoint \(parsed.absoluteString) (bundled FluidAudio will not be initialized)")
        } else {
            // Covers both "URL(string:) returned nil" and "parses but
            // isn't a usable HTTP/HTTPS endpoint with a host" — both
            // get the same fallback treatment because the HTTP code
            // path expects an OpenAI-style /inference server, and a
            // file:// or scheme-typo URL is no more useful than a
            // syntactically-broken one.
            useBundledASR = true
            asrEndpointURL = ASRClient.defaultEndpoint
            logStderr("[parleq] ASR: config has an unusable asr.endpoint (\(config.asrEndpoint)); falling back to bundled in-process FluidAudio")
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
        let llm: (any LLMProvider)? = {
            switch config.llmProvider.lowercased() {
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
                        model: config.llmModel,
                        region: config.awsRegion
                    )
                    logStderr("[parleq] LLM cleanup enabled (bedrock model=\(config.llmModel) region=\(config.awsRegion) auth=bedrock-api-key)")
                    return p
                }
                let mode: BedrockProvider.AuthMode = (config.awsAuthMode.lowercased() == "static")
                    ? .static : .sso
                do {
                    let p = try BedrockProvider(
                        model: config.llmModel,
                        region: config.awsRegion,
                        profileName: config.awsProfile,
                        authMode: mode
                    )
                    let modeLabel = (mode == .static) ? "static-keychain" : "sso"
                    logStderr("[parleq] LLM cleanup enabled (bedrock model=\(config.llmModel) region=\(config.awsRegion) profile=\(config.awsProfile ?? "<default>") auth=\(modeLabel))")
                    return p
                } catch {
                    logStderr("[parleq] LLM cleanup disabled (bedrock init failed): \(error). Will paste raw ASR.")
                    return nil
                }
            case "vertex":
                let project = config.vertexProject.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !project.isEmpty else {
                    logStderr("[parleq] LLM cleanup disabled (vertex provider selected but no GCP project configured — set Settings → LLM → Project). Will paste raw ASR.")
                    return nil
                }
                let mode: VertexProvider.AuthMode = (config.vertexAuthMode == "serviceAccount")
                    ? .serviceAccount : .adc
                if mode == .serviceAccount, !KeychainStore.hasVertexServiceAccountJSON {
                    logStderr("[parleq] vertex: no service-account JSON set yet — set one in Settings → LLM → Set Service Account JSON… (no restart needed)")
                }
                let p = VertexProvider(
                    model: config.llmModel,
                    project: project,
                    region: config.vertexRegion,
                    authMode: mode
                )
                let modeLabel = (mode == .serviceAccount) ? "service-account-jwt" : "gcloud-adc"
                logStderr("[parleq] LLM cleanup enabled (vertex model=\(config.llmModel) project=\(project) region=\(config.vertexRegion) auth=\(modeLabel))")
                return p
            case "azure":
                let resource = config.azureResource.trimmingCharacters(in: .whitespacesAndNewlines)
                let deployment = config.azureDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !resource.isEmpty, !deployment.isEmpty else {
                    logStderr("[parleq] LLM cleanup disabled (azure provider selected but resource or deployment is empty — set Settings → LLM → Azure resource + deployment). Will paste raw ASR.")
                    return nil
                }
                let mode: AzureOpenAIProvider.AuthMode = (config.azureAuthMode == "azureAd")
                    ? .azureAd : .apiKey
                if mode == .apiKey, !KeychainStore.hasAzureAPIKey {
                    logStderr("[parleq] azure: no API key set yet — set one in Settings → LLM → Set Azure API Key… (no restart needed)")
                }
                let family: AzureOpenAIProvider.Family = (config.azureFamily == "reasoning")
                    ? .reasoning : .standard
                let p = AzureOpenAIProvider(
                    model: config.llmModel,
                    family: family,
                    resource: resource,
                    deployment: deployment,
                    apiVersion: config.azureApiVersion,
                    authMode: mode
                )
                let modeLabel = (mode == .azureAd) ? "azure-ad-cli" : "api-key"
                let familyLabel = (family == .reasoning) ? "reasoning" : "standard"
                logStderr("[parleq] LLM cleanup enabled (azure family=\(familyLabel) resource=\(resource) deployment=\(deployment) apiVersion=\(config.azureApiVersion) auth=\(modeLabel))")
                return p
            case "none":
                // Explicit user choice. Don't log this as a problem —
                // it's the configured behavior. AppState already
                // handles llm == nil.
                logStderr("[parleq] LLM cleanup disabled (provider=none — user opted out of cleanup; will paste raw ASR)")
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
                let p = LLMClient(model: config.llmModel)
                logStderr("[parleq] LLM cleanup enabled (gemini model=\(config.llmModel), thinkingBudget=0)")
                if !ProcessInfo.processInfo.environment.keys.contains("GEMINI_API_KEY")
                    && !KeychainStore.hasGeminiAPIKey {
                    logStderr("[parleq] gemini: no API key set yet — set one in Settings → LLM → Set Gemini API Key… (no restart needed)")
                }
                return p
            }
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

        // Menu-bar status item: an LSUIElement app has no Dock icon
        // and no top-of-screen menu, so this is the user's only
        // always-visible handle to confirm the app is running and
        // quit it cleanly. Wired into AppState's phase callback so
        // the icon and "Status: …" line stay in sync.
        let menuBox = MenuBox()
        let settingsBox = SettingsBox()
        let wizardBox = WizardBox()
        MainActor.assumeIsolated {
            logStderr("[parleq] login-item: status=\(LoginItem.statusDescription), supported=\(LoginItem.isSupported), bundle=\(Bundle.main.bundlePath)")
            let menuBar = MenuBar(hotkeyDisplayName: binding.displayName)
            menuBox.value = menuBar
            let settings = SettingsWindowController()
            settingsBox.value = settings
            let wizard = SetupWizardController()
            wizardBox.value = wizard
            menuBar.onOpenSettings = { settings.show() }
            menuBar.onOpenWizard = { wizard.show() }

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
        }

        let soundBox = SoundBox()
        MainActor.assumeIsolated {
            soundBox.value = HotkeySoundDebouncer()
        }
        let listener = HotkeyListener(
            binding: binding,
            onKeyDown: { isDoubleTapHold in
                Task { @MainActor in
                    soundBox.value?.scheduleStart()
                    stateBox.value?.hotkeyDown(isDoubleTapHold: isDoubleTapHold)
                }
            },
            onKeyUp: {
                Task { @MainActor in
                    // In quick mode the visible paste is the end-cue;
                    // skip the Pop so it doesn't collide with the
                    // BT-routing click on engine.stop() and sound
                    // doubled (#6). Snapshot quickMode BEFORE
                    // hotkeyUp runs, since that's the path that
                    // eventually clears it.
                    let suppress = stateBox.value?.quickMode ?? false
                    soundBox.value?.endOrCancel(suppressEnd: suppress)
                    stateBox.value?.hotkeyUp()
                }
            }
        )
        do {
            try listener.start()
        } catch {
            logStderr("[parleq] hotkey listener failed: \(error)")
            exit(1)
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
                menuBox.value?.setASRReady(local.isReady)
                menuBox.value?.setASRLoadFailed(local.loadFailed)
                menuBox.value?.onResetASR = { [weak local] in
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

// SettingsBox holds the SettingsWindowController so it lives for
// the app's whole runtime — needed because the controller's window
// is bound to its instance and we want re-opens to show the same
// window instead of spawning a new one.
private final class SettingsBox: @unchecked Sendable {
    var value: SettingsWindowController?
}

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

private func logStderr(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
