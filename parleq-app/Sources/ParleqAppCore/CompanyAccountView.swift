// CompanyAccountView — Enterprise OIDC federation UI surface.
//
// Task 7 seeds this file with ONLY the production
// `OIDCAuthenticator` (ASWebAuthenticationSession bridge) and its
// presentation-anchor provider, so the provider-wiring in
// ParleqApp.main can construct a live `OIDCSession`. Task 8 grows the
// rest of the file into the full Company Account settings section +
// connection doctor view.

import AppKit
import AuthenticationServices
import SwiftUI

/// Production `OIDCAuthenticator`: drives an ASWebAuthenticationSession
/// on the main actor with an always-available presentation anchor.
/// The session itself runs in the system browser-auth surface, so
/// Parleq never sees the user's IdP password — only the redirect
/// callback (`parleq-auth://oidc/callback?...`) comes back here.
@MainActor
private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthPresenter()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

/// Holds the in-flight ASWebAuthenticationSession so the task-cancellation
/// handler can reach it to cancel(). The `session` property is touched ONLY on
/// the main actor (the start Task writes it; onCancel reads it after a MainActor
/// hop) — the box itself is `@unchecked Sendable` so it can be captured by the
/// non-isolated authenticator closure and its onCancel handler, but that
/// MainActor-only discipline is what keeps the non-Sendable session safe.
private final class WebAuthSessionBox: @unchecked Sendable {
    nonisolated(unsafe) var session: ASWebAuthenticationSession?
    init() {}
}

/// One-shot async gate: waiters park until `open()` is called; calls to
/// `open()` are idempotent and waiters that arrive after opening proceed
/// immediately. Used below to let `onCancel` wait until the MainActor start
/// task has actually invoked `session.start()` before attempting to cancel,
/// closing the race where a cancellation that arrives before the task runs
/// would see `box.session == nil` and silently no-op.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        guard !opened else { return }
        opened = true
        let w = waiters; waiters = []
        for c in w { c.resume() }
    }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Build the production `OIDCAuthenticator` closure that `OIDCSession`
/// invokes for interactive sign-in. Returns the redirect callback URL,
/// or throws `OIDCAuthFailure.signInCancelled` when the user dismisses
/// the sheet (rendered silently by the taxonomy).
public func webAuthSessionAuthenticator(ephemeral: Bool = false) -> OIDCAuthenticator {
    { buildAuthorizationURL, scheme in
        // Custom-scheme path: build the authorization URL with the CONFIGURED
        // redirect (no override) and let ASWebAuthenticationSession intercept the
        // custom-scheme callback. signIn captures the same (configured) redirect
        // for the token exchange.
        let url = buildAuthorizationURL(nil)
        // Box the live session so the cancellation handler can reach it to
        // cancel(). MainActor-confined: only the start Task and onCancel hop
        // touch it, both on the main actor. ASWebAuthenticationSession is not
        // Sendable, so the box keeps it off the @Sendable onCancel closure's
        // capture list directly.
        let box = WebAuthSessionBox()
        // Gate that opens after session.start() is invoked on the MainActor.
        // onCancel waits on this gate before attempting cancel() so it can
        // never fire against a nil box.session (the pre-start race).
        let started = AsyncGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // The completion handler is declared OUTSIDE the @MainActor
                // Task and explicitly @Sendable so it does NOT inherit
                // MainActor isolation. AuthenticationServices is documented
                // to call back on the main thread, but in practice (observed
                // live, macOS 15: Google sign-in) the callback can arrive on
                // an XPC reply queue — an inherited-@MainActor closure then
                // trips Swift 6's dynamic isolation check
                // (dispatch_assert_queue crash). Resuming a continuation is
                // thread-agnostic, so nonisolated is correct here.
                let completion: @Sendable (URL?, Error?) -> Void = { cb, err in
                        if let cb {
                            cont.resume(returning: cb)
                        } else if let err = err as? ASWebAuthenticationSessionError,
                                  err.code == .canceledLogin {
                            // The .canceledLogin callback is also how an external
                            // cancel() (from onCancel below) reports back — both a
                            // user dismissal and a programmatic cancel land here.
                            cont.resume(throwing: OIDCAuthFailure.signInCancelled)
                        } else {
                            // The taxonomy requires `code:` to be a machine-readable
                            // token that lands verbatim in logLine — NEVER a
                            // human-readable sentence. Use the framework error's
                            // numeric code rather than its localizedDescription so no
                            // English prose (or framework detail) leaks into the log.
                            let code = (err as? ASWebAuthenticationSessionError)
                                .map { String($0.code.rawValue) } ?? "unknown"
                            cont.resume(throwing: OIDCAuthFailure.sessionExpired(code: code))
                        }
                }
                Task { @MainActor in
                    let session = ASWebAuthenticationSession(
                        url: url, callbackURLScheme: scheme,
                        completionHandler: completion)
                    session.prefersEphemeralWebBrowserSession = ephemeral
                    session.presentationContextProvider = WebAuthPresenter.shared
                    box.session = session
                    // start() returns false when it can't present the sign-in window
                    // (e.g. another ASWebAuthenticationSession is already active). In
                    // that case the completion handler NEVER fires, so the continuation
                    // would leak and the Task would hang forever. We resume with an
                    // error here; the single resume is safe because start()==false means
                    // the handler won't fire — there's no double-resume risk.
                    if !session.start() {
                        cont.resume(throwing: OIDCAuthFailure.signInUnavailable(
                            detail: "couldn't present the sign-in window (another sign-in may be active)"))
                    }
                    // Open the gate unconditionally — box.session is set either way
                    // (start()==false just means the session never transitions to
                    // running, but the reference is there and cancel() on a session
                    // that never started is documented as a no-op per Apple's
                    // ASWebAuthenticationSession docs). This lets onCancel proceed
                    // safely in both the start()==true and start()==false cases.
                    await started.open()
                }
            }
        } onCancel: {
            // Task cancellation → cancel the system sign-in session. We MUST
            // wait for the gate before touching box.session: if the parent task
            // was cancelled before the MainActor start Task ran, box.session is
            // still nil and a direct cancel() call would silently no-op, leaving
            // a ghost session running. After the gate opens, box.session is
            // guaranteed non-nil (set just before start()) so cancel() is safe.
            // cancel() fires the completion handler with .canceledLogin, which is
            // the ONLY resume path reached from here — so this can't double-resume
            // the continuation (the started session has exactly one completion).
            // Double-resume safety: the start()==false branch already resumed with
            // signInUnavailable before the gate opened; calling cancel() on a
            // never-started session is a documented no-op, so no second resume fires.
            Task { await started.wait(); await MainActor.run { box.session?.cancel() } }
        }
    }
}

/// Build the loopback-redirect `OIDCAuthenticator` for the Google "Desktop app"
/// client type (and any OAuth client using an `http://127.0.0.1:<port>/<path>`
/// redirect). ASWebAuthenticationSession cannot intercept a loopback redirect,
/// so this flow instead:
///   1. binds a transient 127.0.0.1-only listener on an EPHEMERAL port,
///   2. builds the authorization URL with the listener's real redirect URI,
///   3. opens the URL in the user's DEFAULT system browser (NSWorkspace.open),
///   4. awaits the single callback the browser delivers to the listener,
///   5. tears the listener down.
///
/// The configured redirect URI's PORT (if any) is IGNORED — the kernel-assigned
/// ephemeral port is always used (Google Desktop clients accept any loopback
/// port). The configured redirect's HOST is also normalized to `127.0.0.1`: the
/// listener always binds that address, so a configured `localhost` or `[::1]`
/// loopback host is replaced with `127.0.0.1` in both the authorization request
/// and the token-exchange redirect_uri. Google accepts any loopback host, so
/// this is transparent there; an IdP with byte-exact redirect matching should be
/// configured with `127.0.0.1` directly. The configured PATH is preserved.
///
/// `prefersEphemeralWebBrowserSession` is an ASWebAuthenticationSession-only
/// feature; the loopback flow uses the real default browser, so when ephemeral
/// mode is requested for a loopback redirect we emit a one-line code-only notice
/// and proceed (don't fail). The notice is emitted by the selector below.
public func loopbackRedirectAuthenticator(redirectPath: String) -> OIDCAuthenticator {
    { buildAuthorizationURL, _ in
        // Bind FIRST — the redirect URI (and thus the authorization URL) isn't
        // known until we have an ephemeral port.
        let server = try await LoopbackRedirectServer.start(path: redirectPath)
        // Provably close the listener no matter how we leave (success, browser
        // open failure, callback timeout/cancellation).
        return try await withTaskCancellationHandler {
            let authURL = buildAuthorizationURL(server.redirectURI)
            let opened = await MainActor.run { NSWorkspace.shared.open(authURL) }
            guard opened else {
                server.cancel()
                throw OIDCAuthFailure.signInUnavailable(detail: "couldn't open the default browser")
            }
            return try await server.awaitCallback()
        } onCancel: {
            server.cancel()
        }
    }
}

/// Select the interactive authenticator for the configured redirect URI. An
/// `http://` loopback redirect → the loopback-listener flow; any custom scheme
/// → ASWebAuthenticationSession. The decision mirrors the config validator,
/// which now ACCEPTS http+loopback redirects (and still rejects https / non-
/// loopback http).
///
/// Loopback control surface (no dedicated disable key exists or is needed):
/// the loopback listener is selected SOLELY by the redirect_uri — and only
/// when its scheme is `http` AND its host is loopback (`isLoopbackHost`:
/// 127.0.0.1 / ::1 / localhost). EVERY other redirect_uri — a custom scheme
/// (`parleq-auth://oidc/callback`), a reversed-client-ID scheme
/// (`com.googleusercontent.apps...:`), etc. — falls through to
/// `webAuthSessionAuthenticator`, which binds NO socket. The redirect_uri is
/// therefore the complete control: an org that wants the no-local-listener
/// guarantee on managed Macs pins `oidcRedirectURI` via MDM to its
/// custom-scheme value — once pinned the user can't change it, so a loopback
/// redirect can never be configured and this branch can never run. There is
/// intentionally no separate "disable loopback" MDM key because the
/// `oidcRedirectURI` pin already fully controls it.
public func makeOIDCAuthenticator(redirectURI: String, ephemeral: Bool) -> OIDCAuthenticator {
    if let url = URL(string: redirectURI), url.scheme?.lowercased() == "http",
       isLoopbackHost(url) {
        if ephemeral {
            // Ephemeral browser is an ASWebAuthenticationSession feature; the
            // loopback flow uses the real default browser. Code-only notice.
            logStderrOIDC("oidc ephemeral-browser ignored for loopback redirect")
        }
        // Preserve the configured PATH (default "/" when absent); the PORT is
        // always the kernel's ephemeral choice, never the configured one.
        let path = url.path.isEmpty ? "/" : url.path
        return loopbackRedirectAuthenticator(redirectPath: path)
    }
    return webAuthSessionAuthenticator(ephemeral: ephemeral)
}

// MARK: - Company Account settings section

/// The Settings → Company Account pane. Renders the org sign-in state,
/// the signed-in identity, a per-hop connection doctor, and (when not
/// MDM-pinned) a collapsed self-configuration group for issuer +
/// client ID.
///
/// This view is content INSIDE the Settings shell's ScrollView (the
/// shell supplies the scroll container, the section title, and the
/// horizontal padding — see SettingsView.detailPane), so it renders as
/// a flat VStack of cards exactly like the neighboring Settings
/// sections. It deliberately does NOT add its own ScrollView or a
/// GeometryReader height-pin: the NavigationSplitView height-pinning
/// gotcha (CLAUDE.md) applies to panes whose root is a fixed-header
/// VStack resolved at ideal height; flat content riding the shared
/// ScrollView is immune, the same way every other card-based section
/// here is.
///
/// SECURITY: identity (name / email) renders in the UI only — it is
/// never logged. Doctor `lastError` / `doctorDetail` strings are
/// IT-facing detail surfaced in the tooltip, also never logged (the
/// taxonomy's log discipline lives in the exchangers / session, which
/// emit count-and-code lines only).
/// Cached relative-time formatter for `CompanyAccountView.relative(_:)`.
/// Hoisted to file scope because a `static let` can't live on the generic
/// view type; MainActor-isolated so the non-Sendable formatter stays
/// confined to the UI actor.
@MainActor private let companyAccountRelativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
}()

@MainActor
public struct CompanyAccountView<ConfigContent: View>: View {
    @ObservedObject var sessionModel: OIDCSessionModel
    /// Org display name, derived: URL(string: config.oidcIssuer)?.host.
    let issuerHost: String
    /// True when oidcIssuer is MDM-pinned (managedKeys contains it):
    /// the org configured this centrally, so we show a note instead of
    /// the self-configuration group.
    let isPinned: Bool
    /// AWS federation leg is configured (awsAuthMode == "oidc" && role
    /// ARN set). Gates the "AWS access" doctor row.
    let awsConfigured: Bool
    /// GCP federation leg is configured (vertexAuthMode ==
    /// "oidcFederation" && workforce provider set). Gates the "Google
    /// Cloud access" doctor row.
    let gcpConfigured: Bool

    /// Sign in. Wired to the session's interactive sign-in; the ONLY
    /// path that opens the browser sheet. Cancellation is swallowed
    /// silently upstream (OIDCSessionModel.signIn).
    let onSignIn: () -> Void
    /// Sign out. Clears the refresh token + identity, revokes
    /// best-effort, flips the session to signedOut.
    let onSignOut: () -> Void
    /// Run the connection doctor: token-free discovery → silent refresh
    /// → each configured exchange's warm(), then re-read the hop
    /// statuses. Returns the fresh (aws, gcp) hop snapshots so the view
    /// can fold them into @State.
    let onTestConnection: () async -> (FederationHopStatus, FederationHopStatus)
    /// Self-configuration content (issuer + client ID fields) shown
    /// below the cards when NOT MDM-pinned. Injected by the Settings
    /// host so the fields bind to its SettingsModel without this view
    /// depending on the (module-internal) model type. Empty when
    /// pinned (the host passes EmptyView).
    @ViewBuilder let configContent: () -> ConfigContent

    @State private var awsHop = FederationHopStatus()
    @State private var gcpHop = FederationHopStatus()
    @State private var testing = false
    /// Monotonic token identifying the current Test-connection run. The
    /// watchdog captures it at launch and only acts if it's still the live
    /// run when the 20s timer fires — so a finished (or superseded) run can't
    /// be clobbered by a stale watchdog. Bumped on every runTest().
    @State private var testRunID = 0

    public init(
        sessionModel: OIDCSessionModel,
        issuerHost: String,
        isPinned: Bool,
        awsConfigured: Bool,
        gcpConfigured: Bool,
        onSignIn: @escaping () -> Void,
        onSignOut: @escaping () -> Void,
        onTestConnection: @escaping () async -> (FederationHopStatus, FederationHopStatus),
        @ViewBuilder configContent: @escaping () -> ConfigContent
    ) {
        self.sessionModel = sessionModel
        self.issuerHost = issuerHost
        self.isPinned = isPinned
        self.awsConfigured = awsConfigured
        self.gcpConfigured = gcpConfigured
        self.onSignIn = onSignIn
        self.onSignOut = onSignOut
        self.onTestConnection = onTestConnection
        self.configContent = configContent
    }

    /// Org display name — the issuer host, or a neutral fallback when
    /// the issuer URL has no host (e.g. mid-configuration).
    private var orgName: String {
        issuerHost.isEmpty ? "your organization" : issuerHost
    }

    public var body: some View {
        // One body-local switch over the session state so every state
        // renders a concrete card (no placeholder branches).
        Group {
            switch sessionModel.state {
            case .signedOut:
                signedOutCard(failure: nil)
            case .signedIn(let identity):
                signedInCard(identity: identity)
            case .needsInteractive(let failure):
                // needsInteractive renders the signed-out card PLUS the
                // failure's user-facing copy as a banner. signInCancelled
                // never reaches here as a surfaced banner (it's silent),
                // but guard anyway so an empty userCopy can't paint a
                // blank banner.
                signedOutCard(failure: failure.isSilent ? nil : failure)
            }
        }
    }

    // MARK: signed-out

    @ViewBuilder
    private func signedOutCard(failure: OIDCAuthFailure?) -> some View {
        if let failure, !failure.userCopy.isEmpty {
            failureBanner(failure)
        }
        SettingsCard {
            HStack(spacing: 10) {
                Image(systemName: "building.2")
                    .font(.system(size: 22))
                    .foregroundStyle(SettingsView.brandAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(orgName)
                        .font(.headline)
                    Text("Sign in with your company account to use your organization's cloud AI access.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button {
                onSignIn()
            } label: {
                Label("Sign in with your company account", systemImage: "person.badge.key")
            }
            .buttonStyle(.borderedProminent)
            .tint(SettingsView.brandAccent)
            if isPinned {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Sign-in is configured by your organization.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        configurationGroup
    }

    private func failureBanner(_ failure: OIDCAuthFailure) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.userCopy)
                    .font(.callout.weight(.medium))
                if !failure.doctorDetail.isEmpty {
                    Text(failure.doctorDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
    }

    // MARK: signed-in

    private func signedInCard(identity: OIDCIdentity) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 24))
                        .foregroundStyle(SettingsView.brandAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.displayName)
                            .font(.headline)
                        if let email = identity.email, !email.isEmpty,
                           email != identity.displayName {
                            Text(email)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Text("Signed in to \(orgName) · \(Self.relative(identity.obtainedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Sign out") { onSignOut() }
                }
                if isPinned {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Sign-in is configured by your organization.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            doctorCard
            configurationGroup
        }
    }

    // MARK: connection doctor

    private var doctorCard: some View {
        SettingsCard {
            Text("Connection")
                .font(.headline)
            // Hop 1: organization sign-in — derived from the session
            // state itself (no separate hop status: the session IS the
            // org-sign-in leg).
            organizationSignInRow
            if awsConfigured {
                hopRow(title: "AWS access", hop: awsHop)
            }
            if gcpConfigured {
                hopRow(title: "Google Cloud access", hop: gcpHop)
            }
            HStack {
                Button {
                    runTest()
                } label: {
                    if testing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                        }
                    } else {
                        Text("Test connection")
                    }
                }
                .disabled(testing)
                Spacer()
            }
            SettingsCaption("Checks sign-in and each configured cloud without using your credentials for anything else. Runs entirely in the background.")
        }
    }

    private var organizationSignInRow: some View {
        // Only rendered from signedInCard — the outer switch in `body`
        // guarantees the session is .signedIn here, so this hop is always green.
        statusRow(title: "Organization sign-in", ok: true,
                  detail: "Signed in", help: "Signed in to \(orgName).",
                  timestamp: nil)
    }

    /// A doctor row driven by a `FederationHopStatus`. ok when there's
    /// a recorded success and no error newer than it; warn otherwise.
    private func hopRow(title: String, hop: FederationHopStatus) -> some View {
        // A hop is healthy when it has succeeded and no error happened
        // AFTER the last success. A brand-new hop (no success, no error)
        // reads as "not checked yet" — rendered as a neutral warn so the
        // user knows to run the test, not as a false green.
        let hasError = hop.lastError != nil &&
            (hop.lastErrorAt ?? .distantPast) >= (hop.lastSuccess ?? .distantPast)
        let ok = hop.lastSuccess != nil && !hasError
        let detail: String
        let help: String
        if hasError, let err = hop.lastError {
            detail = err
            help = err
        } else if ok {
            detail = "Connected"
            help = "Last verified \(Self.relative(hop.lastSuccess ?? Date()))."
        } else {
            detail = "Not checked yet"
            help = "Run Test connection to verify access."
        }
        return statusRow(title: title, ok: ok, detail: detail, help: help,
                         timestamp: ok ? hop.lastSuccess : nil)
    }

    private func statusRow(title: String, ok: Bool, detail: String, help: String,
                           timestamp: Date?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .help(help)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(help)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let timestamp {
                Text(Self.relative(timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func runTest() {
        guard !testing else { return }
        testing = true
        testRunID &+= 1
        let runID = testRunID
        // Watchdog: if the doctor hasn't finished 20s after launch, mark the
        // configured hops as timed out and clear `testing` so a wedged network
        // hop (DNS black-hole, hung TLS handshake) can't pin the button on
        // "Testing…" forever. Both this and the doctor task run on the
        // MainActor, so the runID guard (not a lock) keeps them from clobbering
        // each other: whichever resolves first wins, the other no-ops.
        let doctor = Task {
            let (aws, gcp) = await onTestConnection()
            // If the watchdog already fired (or another run superseded us), don't
            // overwrite its result with a late doctor reply.
            guard runID == testRunID, testing else { return }
            awsHop = aws
            gcpHop = gcp
            testing = false
        }
        Task {
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            guard testing, runID == testRunID else { return }
            // Cancel the still-running doctor task so it stops awaiting a wedged
            // hop instead of lingering until the underlying request's own
            // timeout. Its result guard (runID/testing) then no-ops if it
            // resolves late.
            doctor.cancel()
            let now = Date()
            let timedOut = "Timed out after 20s — check your network and try again."
            if awsConfigured { awsHop.lastError = timedOut; awsHop.lastErrorAt = now }
            if gcpConfigured { gcpHop.lastError = timedOut; gcpHop.lastErrorAt = now }
            testing = false
        }
    }

    // MARK: self-configuration

    /// Issuer + client ID self-configuration. Always rendered — the injected
    /// `configContent` (CompanyAccountConfigCard) now tracks pin state
    /// per-field: it disables + lock-notes each managed field individually and
    /// hides the whole card only when BOTH issuer and client ID are pinned. A
    /// single `isPinned` gate here would wrongly hide the card (and the still-
    /// editable field) whenever just one of the two was centrally managed.
    @ViewBuilder
    private var configurationGroup: some View {
        configContent()
    }

    /// Relative-time formatter shared by identity + doctor rows. Backed by a
    /// file-private cached instance so we don't allocate a formatter on every
    /// row render. (A `static let` can't live on this generic view type.)
    private static func relative(_ date: Date) -> String {
        companyAccountRelativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Settings host bridge

/// Bridges the module-internal `SettingsModel` to the public
/// `CompanyAccountView`. Lives next to the view (same module) so it can
/// read the model's OIDC handles; the view itself stays free of the
/// model dependency so it could be hosted elsewhere (Setup Wizard).
///
/// Two top-level cases:
///  - The model has a live `oidcSessionModel` (main.swift wired a
///    session at launch) → render the full Company Account view fed by
///    that session + the model's closures.
///  - No session was constructed even though the section is visible —
///    an OIDC auth mode is selected but the issuer / client ID aren't
///    configured yet (or the app hasn't been relaunched since they
///    were). Render an "inactive" explainer plus the self-configuration
///    group so the user can fix it without leaving the section.
@MainActor
struct CompanyAccountSectionContent: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let pinned = model.managedKeys.contains("oidcIssuer")
        let host = URL(string: model.oidcIssuer)?.host ?? ""
        if let sessionModel = model.oidcSessionModel {
            CompanyAccountView(
                sessionModel: sessionModel,
                issuerHost: host,
                isPinned: pinned,
                awsConfigured: model.oidcAWSConfigured,
                gcpConfigured: model.oidcGCPConfigured,
                onSignIn: { model.oidcSignIn?() },
                onSignOut: { model.oidcSignOut?() },
                onTestConnection: {
                    guard let test = model.oidcTestConnection else {
                        return (FederationHopStatus(), FederationHopStatus())
                    }
                    return await test()
                },
                configContent: { CompanyAccountConfigCard(model: model) }
            )
        } else {
            inactiveCard(pinned: pinned)
        }
    }

    /// Rendered when the section is visible but no live session exists —
    /// the federation isn't fully configured yet, or the app needs a
    /// relaunch to pick up freshly-entered issuer / client ID.
    @ViewBuilder
    private func inactiveCard(pinned: Bool) -> some View {
        SettingsCard {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Company sign-in isn't active yet")
                        .font(.headline)
                    Text("A corporate sign-in auth mode is selected, but the connection isn't set up. Enter your organization's issuer and client ID below, then restart Parleq.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if pinned {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Sign-in is configured by your organization.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        CompanyAccountConfigCard(model: model)
    }
}

/// The self-configuration group: issuer + client ID fields a non-MDM
/// org can edit. Collapsed by default (a DisclosureGroup) so the cards
/// above stay the focus. Pin state is derived per-field from
/// `model.managedKeys` (issuer vs client ID can be pinned independently);
/// the card hides itself only when BOTH fields are MDM-managed.
@MainActor
struct CompanyAccountConfigCard: View {
    @ObservedObject var model: SettingsModel
    @State private var expanded = false
    /// In-flight Client secret entry. Holds ONLY what the user is currently
    /// typing — never the stored value (the stored secret is write-only from
    /// the UI's perspective). Cleared on save / cancel / remove.
    @State private var pendingSecret = ""
    /// True while replacing an already-saved secret: swaps the "stored"
    /// indicator for the entry SecureField without first removing the old value.
    @State private var replacingSecret = false

    /// Issuer / client ID are managed independently: each disables and
    /// lock-notes per its OWN managed key, and the card hides only when BOTH
    /// are pinned (a half-pinned org still needs to edit the unpinned field,
    /// so the card must stay visible).
    private var issuerPinned: Bool { model.managedKeys.contains("oidcIssuer") }
    private var clientIDPinned: Bool { model.managedKeys.contains("oidcClientID") }

    var body: some View {
        // Hide only when BOTH fields are centrally managed — otherwise the
        // unpinned field would be unreachable.
        if !(issuerPinned && clientIDPinned) {
            SettingsCard {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        field(label: "Issuer URL",
                              placeholder: "https://example.okta.com/oauth2/default",
                              text: bind(\.oidcIssuer),
                              isManaged: issuerPinned)
                        field(label: "Client ID",
                              placeholder: "0oaXXXXXXXXXXXX",
                              text: bind(\.oidcClientID),
                              isManaged: clientIDPinned)
                        clientSecretField
                        SettingsCaption("Your identity provider's OIDC issuer and the public client ID for Parleq. Changing these requires a restart to take effect.")
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Configuration")
                        .font(.callout.weight(.medium))
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { expanded.toggle() } }
                }
            }
        }
    }

    /// Optional Client secret, entered via a SecureField. The stored value is
    /// NEVER displayed back (matches every other Keychain secret in Settings):
    /// once saved, the field collapses to a "saved" indicator + Replace/Remove,
    /// and the entry SecureField only ever holds what the user is currently
    /// typing. A non-empty entry → Keychain set; Remove → Keychain delete.
    @ViewBuilder
    private var clientSecretField: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Client secret")
                    .frame(minWidth: 90, alignment: .leading)
                if model.oidcClientSecretSet && !replacingSecret {
                    Text("•••• stored in Keychain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Replace") { replacingSecret = true }
                    Button("Remove") {
                        model.removeOIDCClientSecret()
                        pendingSecret = ""
                    }
                    .foregroundColor(.red)
                } else {
                    SecureField("(optional)", text: $pendingSecret)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(true)
                        .onSubmit { saveSecret() }
                    Button("Save") { saveSecret() }
                        .disabled(pendingSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.oidcClientSecretSet {
                        Button("Cancel") { replacingSecret = false; pendingSecret = "" }
                    }
                }
            }
            SettingsCaption("Only needed for Google \u{201C}Desktop app\u{201D} clients — installed-app secrets are not confidential, but Parleq keeps it in the Keychain.")
        }
    }

    private func saveSecret() {
        let trimmed = pendingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.setOIDCClientSecret(trimmed)
        pendingSecret = ""
        replacingSecret = false
    }

    private func field(label: String, placeholder: String, text: Binding<String>,
                       isManaged: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .frame(minWidth: 90, alignment: .leading)
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .disabled(isManaged)
                ManagedIndicator(isManaged: isManaged)
            }
            ManagedCaption(isManaged: isManaged)
        }
    }

    /// Save-on-change binding mirroring SettingsView.bind — writes the
    /// edited value back to the model and persists immediately, the same
    /// auto-save contract every other Settings field follows.
    private func bind(_ keyPath: ReferenceWritableKeyPath<SettingsModel, String>) -> Binding<String> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0; model.save() }
        )
    }
}
