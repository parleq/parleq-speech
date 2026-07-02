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

        // Advanced LLM-request tuning (#55) is launch-read: publish it to
        // the process-global BEFORE any provider is constructed so every
        // provider + the TTFT watchdog see the same values. Restart
        // required to change. Log key NAMES only (the values are
        // non-sensitive numbers, but key names keep the line terse and
        // consistent with the count-only logging convention).
        LLMTuning.current = config.llmTuning
        let tuningOverrides = config.llmTuning.overriddenKeys
        if !tuningOverrides.isEmpty {
            logStderr("[parleq] llm tuning: \(tuningOverrides.count) override(s) active — \(tuningOverrides.joined(separator: ", "))")
        }

        // Eval-gate mode: PARLEQ_EVAL_CASES_FILE is set → this is a batch
        // quality re-gate run, not a live dictation session. Detect it HERE,
        // before any provider is constructed, so:
        //   1. The cleanup provider is ALWAYS local (on-device MLX), regardless
        //      of what config.llmProvider says — the eval gate is exclusively
        //      for the on-device path; it must not depend on user provider
        //      config, must not touch any cloud credentials, and must not
        //      require config edits before running.
        //   2. The OIDC session block is skipped entirely — it has no role on
        //      the local path and its OIDCSession.init reads the Keychain
        //      (refresh token + identity) which triggers re-auth prompts on
        //      every ad-hoc-signed rebuild.
        // The rest of the eval logic lives at the PARLEQ_EVAL_CASES_FILE
        // check below (after localModelStore / makeProvider are wired up).
        let evalMode = ProcessInfo.processInfo.environment["PARLEQ_EVAL_CASES_FILE"] != nil

        // Kick off a background refresh of the LiteLLM pricing
        // table. No-ops if the on-disk cache is fresh (<24h) or a
        // refresh is already in flight; failure is non-fatal —
        // bundled defaults continue to serve. UI sees the new data
        // on its next read of UsageLedger.aggregate().
        //
        // Skipped in eval mode: a batch quality re-gate is intended to be
        // network-free except for the on-device model download — no cloud
        // pricing fetch should fire.
        if !evalMode {
            PricingCache.shared.refreshIfStale()
        }

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

        // Enterprise OIDC federation: one shared OIDCSession serves
        // every configured cloud exchange (AWS + GCP). Constructed only
        // when an active provider (cleanup OR context tier) uses an OIDC
        // auth mode AND the issuer + client ID are configured — so
        // non-enterprise users pay nothing (no session, no Keychain
        // read, no exchangers). The auth mode is per-provider
        // (config.awsAuthMode / config.vertexAuthMode), shared across
        // tiers, so a context tier pointing at the same provider rides
        // the same cache.
        //
        // In eval mode this entire block is skipped: the eval gate uses
        // the local (on-device) provider only, which needs no OIDC
        // session. OIDCSession.init reads the Keychain (refresh token +
        // identity), so skipping it is what keeps eval runs credential-
        // free on ad-hoc-signed debug builds.
        // Enterprise-OIDC launch wiring, derived purely from config (see
        // OIDCLaunchPlan). Decoupled from which tier is active: the shared
        // session — and therefore the Settings → Company Account sign-in
        // button — is built whenever corporate sign-in is configured (an OIDC
        // auth mode is selected + issuer/client ID set), INCLUDING when only
        // the refine or context tier uses the federated provider. The earlier
        // gate keyed on the cleanup/context provider and ignored the refine
        // tier, which let the user reach "section visible but no sign-in
        // button". A signed-out federated cleanup still fails closed to raw.
        let plan = OIDCLaunchPlan(config: config, evalMode: evalMode)
        // Prewarm the Vertex googleOAuth bearer only when a tier actually uses
        // Vertex (cleanup/context/refine). The session is built regardless (so
        // the user can sign in), but there's no point fetching a token no tier
        // will consume. Unlike the old gate, this includes the refine tier.
        let vertexIsActiveTier = !evalMode && (
            config.llmProvider.lowercased() == "vertex"
            || config.contextModel?.provider.lowercased() == "vertex"
            || config.refineModel?.provider.lowercased() == "vertex")
        var oidcSession: OIDCSession? = nil
        var awsExchange: CachedExchange<AWSWebIdentityExchanger>? = nil
        var gcpExchange: CachedExchange<GCPWorkforceExchanger>? = nil
        if plan.buildSession {
            let session = OIDCSession(
                config: OIDCClientConfig(
                    issuer: config.oidcIssuer,
                    clientID: config.oidcClientID,
                    scopes: config.oidcScopes,
                    ephemeralBrowser: config.oidcEphemeralBrowser,
                    redirectURI: config.oidcRedirectURI,
                    extraAuthParams: config.oidcExtraAuthParams
                ),
                httpClient: urlSessionOIDCHTTPClient(),
                // Scope the OPTIONAL client secret to this client_id + issuer
                // (fix #57): a secret saved for a different client is not read.
                tokenStore: KeychainOIDCTokenStore(
                    clientID: config.oidcClientID, issuer: config.oidcIssuer),
                authenticator: makeOIDCAuthenticator(
                    redirectURI: config.oidcRedirectURI,
                    ephemeral: config.oidcEphemeralBrowser)
            )
            if plan.wireAWSExchange {
                awsExchange = CachedExchange(
                    exchanger: AWSWebIdentityExchanger(
                        roleArn: config.awsRoleArn,
                        region: config.awsRegion,
                        // Read the signed-in email live at each STS call so
                        // CloudTrail attribution reflects whoever is signed in
                        // at exchange time, not a stale snapshot from launch.
                        userEmailProvider: { KeychainOIDCTokenStore().loadIdentity()?.email },
                        durationSeconds: config.awsSessionDurationSeconds
                    ),
                    session: session, leg: .aws
                )
                logStderr("[parleq] oidc: AWS web-identity exchange wired (region=\(config.awsRegion))")
            }
            if plan.wireGCPExchange {
                gcpExchange = CachedExchange(
                    exchanger: GCPWorkforceExchanger(
                        workforceProvider: config.vertexWorkforceProvider,
                        userProject: config.vertexProject,
                        httpClient: urlSessionOIDCHTTPClient()
                    ),
                    session: session, leg: .gcp
                )
                logStderr("[parleq] oidc: GCP workforce exchange wired (project=\(config.vertexProject))")
            }
            if plan.vertexGoogleOAuth {
                // No exchanger: the session's access token is the Vertex
                // bearer directly. VertexProvider reads session.accessToken().
                logStderr("[parleq] oidc: Vertex googleOAuth wired (no exchanger; project=\(config.vertexProject))")
            }
            oidcSession = session
        } else if plan.oidcModeSelected {
            logStderr("[parleq] oidc: an OIDC auth mode is selected but oidc.issuer/client_id are not configured — Company Account is inactive; cleanup will fail closed until configured")
        }

        // On-device LLM tier: one shared LocalModelStore + ResidencyManager for
        // the whole process. Created here (before makeProvider) so the factory
        // closure can capture the same instances that wizard/Settings will later
        // reference. Both inits are @MainActor; main.swift's startup block runs
        // inside MainActor.assumeIsolated, so the synchronous read is safe.
        //
        let localModelStore = MainActor.assumeIsolated { LocalModelStore() }
        let localResidency = MainActor.assumeIsolated {
            ResidencyManager(
                store: localModelStore,
                policy: ResidencyPolicy.effective(
                    residency: config.localResidency,
                    tier: RAMTier.current,
                    configMinutes: config.localIdleUnloadMinutes))
        }

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
                let mode: BedrockProvider.AuthMode
                switch config.awsAuthMode.lowercased() {
                case "static": mode = .static
                case "oidc":   mode = .oidc
                default:       mode = .sso
                }
                do {
                    let p = try BedrockProvider(
                        model: id.model,
                        region: config.awsRegion,
                        profileName: config.awsProfile,
                        authMode: mode,
                        oidcExchange: mode == .oidc ? awsExchange : nil
                    )
                    let modeLabel: String
                    switch mode {
                    case .static: modeLabel = "static-keychain"
                    case .oidc:   modeLabel = "oidc-federation"
                    case .sso:    modeLabel = "sso"
                    }
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
                let mode: VertexProvider.AuthMode
                switch config.vertexAuthMode {
                case "serviceAccount":  mode = .serviceAccount
                case "oidcFederation":  mode = .oidcFederation
                case "googleOAuth":     mode = .googleOAuth
                default:                mode = .adc
                }
                if mode == .serviceAccount, !KeychainStore.hasVertexServiceAccountJSON {
                    logStderr("[parleq] vertex: no service-account JSON set yet — set one in Settings → LLM → Set Service Account JSON… (no restart needed)")
                }
                let p = VertexProvider(
                    model: id.model,
                    project: project,
                    region: config.vertexRegion,
                    anthropicRegion: config.vertexAnthropicRegion,
                    authMode: mode,
                    oidcExchange: mode == .oidcFederation ? gcpExchange : nil,
                    // googleOAuth sources the bearer from the session's access
                    // token directly (no exchanger). The session is the same
                    // shared OIDCSession AppState pre-warms.
                    oidcSession: mode == .googleOAuth ? oidcSession : nil
                )
                let modeLabel: String
                switch mode {
                case .serviceAccount:  modeLabel = "service-account-jwt"
                case .oidcFederation:  modeLabel = "oidc-federation"
                case .googleOAuth:     modeLabel = "google-oauth"
                case .adc:             modeLabel = "gcloud-adc"
                }
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
            case "concord":
                // "Lightweight (on-device)" 2nd-pass cleanup — the private
                // Concord deterministic + confidence-gated corrector. Runs
                // in-process, ~0 ms, no network, no auth, no model download.
                // id.model is ignored (Concord has its own fixed phase id).
                // AppState feeds it per-word confidence + the dictionary via
                // a per-utterance side-channel just before each cleanup.
                #if Concord
                let p = ConcordCleanupProvider()
                logStderr("[parleq] LLM \(label) (concord — lightweight on-device 2nd-pass, no network)")
                return p
                #else
                // This build was compiled without the proprietary Concord tier
                // (public open-source build). A config that still selects it
                // falls back to raw paste rather than crashing; the option is
                // also hidden from Settings in this build.
                logStderr("[parleq] LLM \(label): 'concord' (Lightweight) is unavailable in this build — pasting raw ASR")
                return nil
                #endif
            case "none":
                // Explicit user choice. Don't log this as a problem —
                // it's the configured behavior. AppState already
                // handles llm == nil.
                logStderr("[parleq] LLM \(label) disabled (provider=none — user opted out of cleanup; will paste raw ASR)")
                return nil
            case "local":
                // RAM gate (mirrors the Setup Wizard + Settings picker): on
                // machines below the 12 GB floor the on-device model (~6 GB
                // resident, ~4 GB download) would thrash the machine, so it's
                // not selectable unless the user sets the explicit config-file
                // override llm.local.allow_unsupported_ram=true. Honoring the
                // override means we do NOT block when it's set. Without it we
                // fail closed to raw paste rather than kicking off a multi-GB
                // download on an unsupported machine (a config.json hand-edit or
                // an upgrade from a build that predated the gate can reach here).
                if RAMTier.current == .unsupported && !config.localAllowUnsupportedRAM {
                    let gb = Int((Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)).rounded())
                    logStderr("[parleq] LLM \(label): on-device requires 12 GB+ RAM (have \(gb)GB); set llm.local.allow_unsupported_ram=true to override. Falling back to no cleanup (raw paste).")
                    return nil
                }
                // id.model is ignored on the local path: the store only ever serves
                // LocalModelDefaults.checkpoint, and a stale cloud model id left in
                // config.llm.model would otherwise pollute logs and the UsageLedger
                // (and hit cloud pricing tables in the Usage UI).
                let p = LocalLLMProvider(
                    model: LocalModelDefaults.checkpoint,
                    store: localModelStore,
                    residency: localResidency)
                logStderr("[parleq] LLM \(label) (local model=\(p.model) — on-device via MLX, no network)")
                return p
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

        // In eval mode, force the cleanup provider to "local" regardless of what
        // config.llmProvider says. The eval gate is exclusively for the on-device
        // path; it must not depend on user provider config, must not touch any
        // cloud credentials, and must not require config edits before running.
        // Any Keychain-touching cloud provider branch inside makeProvider is
        // therefore never reached in eval mode.
        let cleanupId = evalMode
            ? ModelIdentifier(provider: "local", model: config.llmModel)
            : ModelIdentifier(provider: config.llmProvider, model: config.llmModel)
        if evalMode {
            logStderr("[parleq] eval mode: cleanup provider overridden to 'local' (config says '\(config.llmProvider)'); no cloud credentials will be accessed")
        }
        let llm = makeProvider(cleanupId, "cleanup enabled")

        // PARLEQ_EVAL_CASES_FILE / PARLEQ_EVAL_OUTPUT_FILE — debug-only batch
        // eval: run the cleanup suite through the real provider path and exit.
        // Powers the pre-merge quality re-gate; logs counts only — no
        // transcript content (house invariant).
        if let evalCasesPath = ProcessInfo.processInfo.environment["PARLEQ_EVAL_CASES_FILE"] {
            let evalOutputPath = ProcessInfo.processInfo.environment["PARLEQ_EVAL_OUTPUT_FILE"]
                ?? "/tmp/parleq-eval.json"

            // DATA HYGIENE: the cases file (PARLEQ_EVAL_CASES_FILE) MUST contain
            // ONLY synthetic / fixture transcripts — never real user dictations.
            // Both the input cases and the generated cleanup output land on disk
            // (the input file is read from its given path; output is written to
            // PARLEQ_EVAL_OUTPUT_FILE, default /tmp/parleq-eval.json). Real
            // dictation content has no business in either file.
            struct EvalInputCase: Decodable {
                let id: String
                let system: String
                let user: String
            }

            // Swift 6 strict concurrency: the onEvent closure is @Sendable, so
            // var captures are rejected. Accumulate streaming events via a
            // final-class box that each case constructs fresh; the closure
            // captures the box (a reference type), which is Sendable as
            // @unchecked. The accumulator is only ever written from the
            // streaming closure (called serially by the provider) and read
            // after the await returns — no actual concurrent mutation occurs.
            final class EvalAccumulator: @unchecked Sendable {
                var output = ""
                var ttftApproxMs: Double = -1.0
                var promptTokens = 0
                var genTokens = 0
                let genStart: Date
                init() { genStart = Date() }
            }

            guard let casesData = try? Data(contentsOf: URL(fileURLWithPath: (evalCasesPath as NSString).expandingTildeInPath)),
                  let cases = try? JSONDecoder().decode([EvalInputCase].self, from: casesData) else {
                logStderr("[eval] ERROR: could not read or parse PARLEQ_EVAL_CASES_FILE=\(evalCasesPath)")
                exit(1)
            }

            guard let evalProvider = llm else {
                logStderr("[eval] ERROR: no cleanup provider available (provider=\(config.llmProvider)); cannot run eval")
                exit(1)
            }

            logStderr("[eval] starting \(cases.count) cases via \(evalProvider.providerName)/\(evalProvider.model)")

            // Bridge sync main() → async generateStreaming using a semaphore.
            // We're still on the main thread before app.run(), so we spin a
            // Task on the cooperative pool, block the main thread on the
            // semaphore, and let the RunLoop drain during the wait so the
            // cooperative executor can progress.
            let semaphore = DispatchSemaphore(value: 0)
            var evalResults: [[String: Any]] = []

            Task {
                defer { semaphore.signal() }
                for c in cases {
                    let wallStart = Date()
                    let acc = EvalAccumulator()
                    var caseError: String? = nil
                    do {
                        try await evalProvider.generateStreaming(
                            systemPrompt: c.system,
                            messages: [LLMMessage(role: "user", content: c.user)]
                        ) { event in
                            switch event {
                            case .chunk(let text):
                                if acc.ttftApproxMs < 0 {
                                    acc.ttftApproxMs = Date().timeIntervalSince(acc.genStart) * 1000.0
                                }
                                acc.output += text
                            case .done(let summary):
                                acc.promptTokens = summary.inputTokens
                                acc.genTokens = summary.outputTokens
                                if acc.ttftApproxMs < 0 {
                                    acc.ttftApproxMs = summary.ttft * 1000.0
                                }
                            }
                        }
                    } catch {
                        caseError = "\(error)"
                    }
                    let totalMs = Date().timeIntervalSince(wallStart) * 1000.0
                    let truncated = acc.genTokens >= 1024
                    let metrics: [String: Any] = [
                        "total_duration_ms": (totalMs * 100).rounded() / 100,
                        "ttft_approx_ms": (acc.ttftApproxMs * 100).rounded() / 100,
                        "prompt_eval_count": acc.promptTokens,
                        "eval_count": acc.genTokens,
                    ]
                    evalResults.append([
                        "id": c.id,
                        "output": acc.output,
                        "metrics": metrics,
                        "truncated": truncated,
                        "error": caseError as Any? ?? NSNull(),
                    ])
                    // Progress line: id + timing + token counts only — never output text.
                    let truncTag = truncated ? " [TRUNCATED]" : ""
                    let errTag = caseError != nil ? " ERROR" : ""
                    logStderr(String(format: "[eval] %@  %.0fms  prompt=%d gen=%d%@%@",
                                     c.id, totalMs, acc.promptTokens, acc.genTokens, truncTag, errTag))
                }

                // Write results JSON.
                do {
                    let json = try JSONSerialization.data(
                        withJSONObject: evalResults,
                        options: [.prettyPrinted, .sortedKeys])
                    let outURL = URL(fileURLWithPath: (evalOutputPath as NSString).expandingTildeInPath)
                    try FileManager.default.createDirectory(
                        at: outURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try json.write(to: outURL)
                    logStderr("[eval] wrote \(evalResults.count) results to \(evalOutputPath)")
                } catch {
                    // Fail loud: a CI gate keys off the exit code, so a failed
                    // output write must NOT fall through to exit(0) below (which
                    // would report success with no results file written).
                    logStderr("[eval] ERROR writing output: \(error)")
                    exit(1)
                }
            }

            // Drain the RunLoop while waiting so the cooperative executor
            // (which runs Task bodies) can make progress on the main thread.
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }

            let errors = evalResults.filter { !($0["error"] is NSNull) }.count
            logStderr("[eval] done. \(evalResults.count)/\(cases.count) completed, \(errors) error(s)")
            exit(0)
        }

        // KV prefix-cache warm-up (Task 9). When the cleanup provider is the
        // on-device tier and the model is downloaded, prefill the current
        // cleanup system prompt's KV prefix in the background so the FIRST
        // dictation already hits a warm cache (TTFT win). Low priority and fully
        // best-effort: it must never block startup or a dictation. Cache miss =
        // plain uncached prefill, exactly as before. The transform is nil here
        // (per-app preset variants warm lazily on first use); the dictionary
        // mirrors the dictation path's enabled-gating.
        if cleanupId.provider == "local" && localModelStore.state == .ready {
            let warmDictionary = config.customDictionaryEnabled ? config.customDictionary : []
            let warmCheckpoint = LocalModelDefaults.checkpoint
            Task(priority: .utility) {
                await localResidency.warmCleanupPrefix(
                    checkpoint: warmCheckpoint, dictionary: warmDictionary)
            }
            logStderr("[parleq] local cleanup: warming KV system-prefix cache in background")
        }

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

        // Refine-model tier — the shared Polished provider for REFINEMENT
        // (reframe v2). Build it whenever `config.refineModel` is set and
        // differs from the cleanup model, INDEPENDENT of the cleanup provider:
        // refinement is now orthogonal to cleanup, so a user can pick Raw
        // cleanup ("none") + Polished refinement and this must instantiate the
        // provider. (Contrast contextLLM below/above, which stays gated on
        // cleanup != "none" — references remain a sub-feature of cleanup.)
        // nil → AppState's routing falls refine turns back to append-only.
        let refineLLM: (any LLMProvider)? = {
            guard let rfnId = config.refineModel, rfnId != cleanupId else {
                return nil
            }
            // Reuse the already-built context provider ONLY when it points at
            // the same identifier AND was actually built (contextLLM is nil for
            // a "none"-cleanup user) — otherwise build a fresh client.
            if let ctxId = config.contextModel, rfnId == ctxId, let ctx = contextLLM {
                return ctx
            }
            return makeProvider(rfnId, "refine-model enabled")
        }()

        // Standing on-device Concord provider for per-app **Instant** mode.
        // Built unconditionally (trait-gated), INDEPENDENT of the global
        // cleanup provider, so an Instant-mode target can FORCE literal
        // on-device cleanup even when the user's global cleanup is a cloud
        // LLM. The instance is cheap — ConcordCleanupProvider.init just
        // stores a default engine (no network/auth/RAM/model download). In a
        // no-Concord (public source) build this is nil and Instant falls back
        // to RAW paste, not Polished (see AppState's mode routing).
        #if Concord
        let instantLLM: (any LLMProvider)? = ConcordCleanupProvider()
        logStderr("[parleq] Instant tier ready (standing Concord — on-device, no network)")
        #else
        let instantLLM: (any LLMProvider)? = nil
        #endif

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
                refineLLM: refineLLM,
                instantLLM: instantLLM,
                overlay: overlay,
                autoAcceptSeconds: config.autoAcceptSeconds,
                trailingSpaceEnabled: config.trailingSpace,
                noTrailingSpaceAppBundleIDs: config.noTrailingSpaceAppBundleIDs,
                oidcSession: oidcSession,
                oidcAWSExchange: awsExchange,
                oidcGCPExchange: gcpExchange,
                oidcPrewarmSessionAccessToken: plan.vertexGoogleOAuth && vertexIsActiveTier
            )
            // Record the provider this process actually launched with, so the
            // on-device restart affordance can detect "config says local + model
            // ready, but the live process predates that" (see onDeviceActivationPending).
            LaunchInfo.cleanupProvider = cleanupId.provider
        }

        // Enterprise OIDC: wire the Company Account section. Only when a
        // session was actually constructed (OIDC mode active AND issuer/
        // client configured). The SwiftUI session model mirrors the
        // actor's state; the closures are the UI's only channel to drive
        // sign-in / sign-out / connection-test against the SAME session +
        // exchange caches AppState pre-warms — no token or identity
        // content crosses into the Settings layer (state + closures only).
        if let session = oidcSession {
            MainActor.assumeIsolated {
                let sessionModel = OIDCSessionModel()
                // bind(to:) is async (it registers an observer on the
                // actor). Kick it off; the observer fires the current
                // state immediately on registration, so the UI reflects
                // reality as soon as the bind completes.
                Task { await sessionModel.bind(to: session) }
                let awsCfg = awsExchange != nil
                let gcpCfg = gcpExchange != nil
                ParleqAppWindowController.shared.setOIDCCompanyAccount(
                    sessionModel: sessionModel,
                    signIn: {
                        // The ONLY trigger of the browser sheet — never
                        // automatic. Cancellation is swallowed silently
                        // inside OIDCSessionModel.signIn().
                        Task { await sessionModel.signIn() }
                    },
                    signOut: {
                        // Sign-out must revoke cloud-credential ACCESS, not
                        // just the IdP session: after the session signs out
                        // (which bumps its generation and clears tokens), drop
                        // every cloud exchange's cached credentials so the next
                        // dictation can't reuse a still-warm federated/STS
                        // credential. invalidate() also cancels any in-flight
                        // exchange; the generation re-check in exchangeNow()
                        // discards a late result so it can't repopulate.
                        //
                        // signOut() now clears local IdP state SYNCHRONOUSLY and
                        // fires revocation off in a detached Task, so it returns
                        // immediately — these cache invalidations no longer wait
                        // on a (possibly stalled) IdP revocation round-trip.
                        Task {
                            await sessionModel.signOut()
                            if let aws = awsExchange { await aws.invalidate() }
                            if let gcp = gcpExchange { await gcp.invalidate() }
                        }
                    },
                    testConnection: {
                        // Token-free: force a silent refresh (re-validates
                        // the session against the IdP, updates state), then
                        // warm each configured exchange so its hopStatus
                        // reflects a fresh exchange attempt. warm() swallows
                        // errors — the doctor reads the resulting hopStatus,
                        // not a throw. Read the per-leg status back for the UI.
                        await sessionModel.refreshSession()
                        if let aws = awsExchange { await aws.warm() }
                        if let gcp = gcpExchange { await gcp.warm() }
                        let awsHop = await awsExchange?.hopStatus ?? FederationHopStatus()
                        let gcpHop = await gcpExchange?.hopStatus ?? FederationHopStatus()
                        return (awsHop, gcpHop)
                    },
                    awsConfigured: awsCfg,
                    gcpConfigured: gcpCfg
                )
                // Overlay clickable re-auth: the overlay drives the SAME
                // interactive sign-in the Company Account button does
                // (shared sessionModel → one session + exchange-cache
                // lifecycle). Returns whether the session ended signed in
                // so the overlay can offer its opt-in re-clean affordance.
                stateBox.value?.oidcInteractiveSignIn = {
                    await sessionModel.signIn()
                }
            }
            logStderr("[parleq] oidc: Company Account section wired")
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
            // Inject the shared on-device model store into Settings so the
            // Cleanup → on-device card can surface live download state.
            // Task 11 fulfills the Settings side of TODO(local-ui).
            ParleqAppWindowController.shared.setLocalModelStore(localModelStore)
            let wizard = SetupWizardController(localModelStore: localModelStore)
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
            // B3: enable the "Recover last dictation" menu item once a fresh
            // capture has been retained this session.
            menuBar.onRecoverLastDictation = {
                Task { @MainActor in stateBox.value?.recoverLastDictation() }
            }
            stateBox.value?.onRecoverableDictationChanged = { available in
                menuBar.canRecoverLastDictation = available
            }

            // On-device LLM model download progress → menu-bar status line.
            // Mirrors the LocalASR onReadyChanged pattern for the speech engine.
            // Show "Downloading cleanup model… N%" while in-flight; hide when
            // done (ready or failed). The initial state fires once to sync the
            // menu on launch (handles the case where a download was in progress
            // from a previous session that ended mid-download — unlikely today
            // since a fresh init always starts in .notDownloaded or .ready, but
            // defensive).
            let applyLocalModelState: (LocalModelStore.State) -> Void = { [weak menuBox] state in
                switch state {
                case .downloading(let p):
                    menuBox?.value?.setLocalModelDownloadProgress(p)
                    menuBox?.value?.setOnDeviceRestartPending(false)
                case .notDownloaded:
                    menuBox?.value?.setLocalModelDownloadProgress(nil)
                    menuBox?.value?.setOnDeviceRestartPending(false)
                    // "Remove downloaded model" sets state to .notDownloaded.
                    // Also release the ~6 GB of resident GPU/ANE memory
                    // immediately so the user sees the benefit right away
                    // rather than waiting for the idle-unload timer to fire.
                    Task { await localResidency.unloadNow() }
                case .ready:
                    menuBox?.value?.setLocalModelDownloadProgress(nil)
                    // Restart-after-download (wizard OR Settings): if config now
                    // says local and the model is ready but THIS process launched
                    // with a different provider, surface the menu-bar restart
                    // prompt so the wizard path is covered even when Settings is
                    // closed. Config re-read is cheap (fires once on .ready).
                    let pending = onDeviceActivationPending(
                        launchProvider: cleanupId.provider,
                        configProvider: Config.load().config.llmProvider,
                        modelReady: true)
                    menuBox?.value?.setOnDeviceRestartPending(pending)
                default:
                    menuBox?.value?.setLocalModelDownloadProgress(nil)
                    menuBox?.value?.setOnDeviceRestartPending(false)
                }
            }
            localModelStore.onStateChanged = applyLocalModelState
            applyLocalModelState(localModelStore.state)

            // Re-evaluate the on-device restart-to-activate prompt when the
            // cleanup provider changes in Settings — the model-state observer
            // above only fires on download-state transitions, so switching
            // local→other (or other→local) while the model is already ready
            // would otherwise leave the menu-bar item stale. Together the two
            // keep it correct across both axes (model readiness AND provider).
            NotificationCenter.default.addObserver(
                forName: .parleqCleanupProviderChanged, object: nil, queue: .main
            ) { [weak menuBox] _ in
                MainActor.assumeIsolated {
                    let pending = onDeviceActivationPending(
                        launchProvider: cleanupId.provider,
                        configProvider: Config.load().config.llmProvider,
                        modelReady: localModelStore.state == .ready)
                    menuBox?.value?.setOnDeviceRestartPending(pending)
                }
            }

            // "Finish setup…" prompt — shown when the wizard hasn't been
            // completed yet. Disappears once the wizard saves
            // config.wizardCompleted=true (next launch after finishing).
            // Clicking posts .parleqRunSetupAgain (same as "Run Setup…").
            menuBar.setNeedsSetupPrompt(!config.wizardCompleted)

            // First-launch wizard auto-show (#21 step 6). Skipping
            // here keeps existing users (config.wizardCompleted ==
            // true) out of the path entirely. Test users who want
            // to re-run the flow can do so from the menu bar or
            // via Settings → "Run Setup Again".
            let accessGrantedAtLaunch = LaunchPermissions.accessibilityGranted
            let showWizardAtLaunch = LaunchPermissions.shouldShowWizardAtLaunch(
                wizardCompleted: config.wizardCompleted,
                accessibilityGranted: accessGrantedAtLaunch)
            if showWizardAtLaunch {
                if !config.wizardCompleted {
                    logStderr("[parleq] wizard: launching first-run setup (config.wizardCompleted=false)")
                    wizard.show()
                } else {
                    // #82: returning user whose Accessibility was revoked — show
                    // the permissions step only (no full re-flow, no config reset).
                    logStderr("[parleq] wizard: Accessibility missing — showing permissions re-grant (#82)")
                    wizard.show(permissionsOnly: true)
                }
            }

            // Per-app cleanup modes (per-target feature): a one-time heads-up so
            // an EXISTING user's dictation into terminals/editors/spreadsheets
            // doesn't silently switch to Instant without explanation. New installs
            // (wizard not yet completed) onboard WITH the feature and are marked
            // seen silently. When the permissions wizard is up, defer to the next
            // launch so we don't stack two modals.
            if !UserDefaults.standard.bool(forKey: PerAppModesNotice.seenKey) {
                if !config.wizardCompleted {
                    UserDefaults.standard.set(true, forKey: PerAppModesNotice.seenKey)
                } else if !showWizardAtLaunch {
                    // Defer to after launch settles so a synchronous modal doesn't
                    // block the remaining app setup below.
                    DispatchQueue.main.async {
                        PerAppModesNotice.show()
                        UserDefaults.standard.set(true, forKey: PerAppModesNotice.seenKey)
                    }
                }
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
                        spaceWasPressedDuringHold: upEvent.spaceWasPressedDuringHold,
                        wasDoubleTapRelease: upEvent.wasDoubleTapRelease
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
            },
            onRPressed: {
                // B3 "hold-hotkey + R = recover last dictation" gesture.
                // Edge-triggered the first time R lands during a
                // dictation-hotkey hold; the listener has already
                // consumed the R keyDown + matching keyUp so the focused
                // app doesn't see a stray r. AppState aborts the in-flight
                // capture and re-runs the retained last-dictation audio.
                Task { @MainActor in
                    stateBox.value?.rPressedDuringHold()
                }
            }
        )
        // #82: arm the global hotkey listener if Accessibility is already
        // granted; otherwise do NOT exit(1) — Parleq stays alive and arms once
        // the user grants access (via the wizard's explained prompt or System
        // Settings). The didBecomeActive observer below re-attempts on return.
        switch LaunchPermissions.armingDecision(
            armed: listener.isArmed,
            accessibilityGranted: LaunchPermissions.accessibilityGranted
        ) {
        case .arm:
            do {
                try listener.start()
            } catch {
                logStderr("[parleq] hotkey listener failed to arm: \(error)")
            }
        case .waitForAccessibility:
            logStderr("[parleq] hotkey: Accessibility not granted — listener will arm once granted (#82)")
        case .alreadyArmed:
            break
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
        // #82 + keyboard-lockout fix: reconcile the event tap with Accessibility
        // trust whenever Parleq becomes active (e.g. returning from System
        // Settings after granting OR revoking). reconcileWithAccessibility()
        // arms on grant and TEARS THE TAP DOWN on revoke — so a revoked, keyboard-
        // intercepting tap can never linger and lock the keyboard.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [listenerBox] _ in
            MainActor.assumeIsolated { listenerBox.value?.reconcileWithAccessibility() }
        }
        // Periodic safety reconciler (~1s): catches an Accessibility revoke even
        // when Parleq isn't activated and even if no tap-disabled callback fires,
        // guaranteeing the keyboard is freed within ~1s of losing trust. Cheap
        // (AXIsProcessTrusted is a fast probe). Also re-arms when trust returns.
        let accessibilityReconciler = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [listenerBox] _ in
            MainActor.assumeIsolated { listenerBox.value?.reconcileWithAccessibility() }
        }
        accessibilityReconciler.tolerance = 0.5   // let the OS coalesce; not time-critical
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
            #if Concord
            // SI-2 (7034): enforce the clip-storage kill-switch on EVERY launch
            // path, not just the bundled-ASR ready path where the coordinator is
            // built. A custom asr.endpoint (no bundled coordinator) or an ASR load
            // failure (onReadyChanged never fires) must still erase any stored
            // enrollment audio when clip storage is resolved OFF. The erase only
            // needs the store + the resolved flag — independent of the coordinator.
            if !Config.load().config.voiceprintClipStorageEnabled {
                do {
                    try EnrollmentAudioStore().deleteAll()
                    logStderr("[voiceprint-audio] clip storage disabled — stored clips erased")
                } catch {
                    logStderr("[voiceprint-audio] clip storage disabled — erase FAILED (\(type(of: error)))")
                }
            }
            #endif
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
                        // Voice-enrollment acoustic disambiguation. The coordinator
                        // is ALWAYS constructed (productized): assigning it to
                        // AppState wires the self-gating acoustic gate into Concord
                        // (a no-op until a term is enrolled via the wizard). Under
                        // PARLEQ_VOICEPRINT_DEMO=1 it additionally runs the one-time
                        // programmatic flywheel enrollment (debug path).
                        // ONE-SHOT: build the voiceprint coordinator only on the first
                        // ready. A later ASR reset (Settings → reset / degraded reload)
                        // re-fires onReadyChanged; rebuilding would orphan an open
                        // enrollment wizard's coordinator.
                        #if Concord
                        if stateBox.value?.voiceprint == nil {
                        let coordinator = VoiceprintCoordinator()
                        // Encrypted-at-rest persistence (biometric data; AES-GCM +
                        // device-only Keychain key). Set BEFORE assigning to AppState
                        // so loadPersisted's gate install lands on the wired callback.
                        coordinator.persistence = EncryptedVoiceprintStore()
                        // Enrollment-audio persistence: raw WAV clips for future
                        // re-derivation across encoder changes. Set before loadPersisted.
                        coordinator.audioPersistence = EnrollmentAudioStore()
                        // Harvested-negatives persistence: correction-harvested
                        // negative-prototype rings (embeddings only, same shared
                        // device key). Set BEFORE loadPersisted so the rings load
                        // with the templates.
                        coordinator.harvestPersistence = EncryptedHarvestStore()
                        // SI-2: the clip-storage kill-switch erase now fires
                        // UNCONDITIONALLY at the top of this MainActor block (7034),
                        // covering every launch path (custom endpoint / load failure),
                        // so no per-coordinator enforce call is needed here.
                        stateBox.value?.voiceprint = coordinator
                        coordinator.loadPersisted()
                        // Auto-migrate any voiceprints parked under an unknown encoder
                        // stamp by re-deriving them from the stored enrollment audio
                        // under the CURRENT encoder. Non-destructive (R1/SI-1): bails
                        // without writing if the audio store can't load; inert terms
                        // keep their old stamp on disk.
                        Task { @MainActor [weak local] in
                            await coordinator.migrateIfNeeded { wav in
                                try await local?.transcribeRawForVoiceprint(wav: wav)
                            }
                        }
                        // Bundle the wizard's dependencies and hand them to Settings.
                        let vpServices = VoiceprintServices(
                            coordinator: coordinator,
                            makeRecorder: {
                                let r = AudioRecorder()
                                let cfg = Config.load().config
                                r.continueOtherAudio = cfg.continueOtherAudio
                                r.explicitInputDeviceUID = cfg.audioInputDeviceUID
                                return r
                            },
                            transcribe: { [weak local] wav in
                                try await local?.transcribeRawForVoiceprint(wav: wav)
                            },
                            llmText: { prompt in
                                await stateBox.value?.generateCarrierText(prompt: prompt)
                            },
                            clipStoragePolicy: {
                                let cfg = Config.load().config
                                return (enabled: cfg.voiceprintClipStorageEnabled,
                                        consented: cfg.voiceClipStorageConsented)
                            })
                        // 7089: always wire the services so Settings keeps its
                        // management handle (view/delete voiceprints) regardless of
                        // whether enrollment is offered. The enroll entry points are
                        // gated individually — enrollmentHero in SettingsWindow (~3999)
                        // and startEnroll (~4238) each guard on enrollmentOffered —
                        // so the enrollment SURFACE stays off when the master switch is
                        // off, while existing prints remain viewable and deletable.
                        ParleqAppWindowController.shared.setVoiceprintServices(vpServices)
                        // 7033: gate only the enrollment-triggering code paths.
                        if VoiceprintServices.enrollmentOffered(Config.load().config) {
                            if VoiceprintDemo.isEnabled {
                                // Debug flywheel enrollment. The coordinator's
                                // onStoreChanged callback (wired in AppState's didSet)
                                // re-installs the gate factory after it enrolls Keavi.
                                Task { @MainActor [weak local] in
                                    await coordinator.runStartupEnrollment { wav in
                                        try await local?.transcribeRawForVoiceprint(wav: wav)
                                    }
                                }
                            }
                        }
                        }   // one-shot guard
                        #endif
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
