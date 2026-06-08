import Foundation

public struct OIDCClientConfig: Sendable, Equatable {
    public let issuer: String
    public let clientID: String
    public let scopes: [String]
    public let ephemeralBrowser: Bool
    /// The OAuth redirect URI sent in the authorization request and the
    /// token-exchange `redirect_uri`. Either a custom scheme (browser callback
    /// scheme derived from the URL scheme component; intercepted by
    /// ASWebAuthenticationSession) or an http:// loopback redirect (Google
    /// "Desktop app"; answered by a transient 127.0.0.1-only listener — the
    /// configured port is ignored, an ephemeral one is bound). Defaults to the
    /// fixed custom scheme `parleq-auth://oidc/callback`; generic OPs (e.g. a
    /// Google native client) set their own value via `oidc.redirect_uri`.
    public let redirectURI: String
    /// Extra query parameters appended to the authorization request (e.g.
    /// `access_type=offline`, `prompt=consent` so a refresh token is granted
    /// on every interactive sign-in). Reserved OIDC params are protected and
    /// ignored if present here. Defaults to empty.
    public let extraAuthParams: [String: String]
    public init(issuer: String, clientID: String, scopes: [String],
                ephemeralBrowser: Bool,
                redirectURI: String = OIDCSession.redirectURI,
                extraAuthParams: [String: String] = [:]) {
        self.issuer = issuer; self.clientID = clientID
        self.scopes = scopes; self.ephemeralBrowser = ephemeralBrowser
        self.redirectURI = redirectURI; self.extraAuthParams = extraAuthParams
    }
}

/// Keychain seam (real impl in KeychainStore; recording fake in tests).
public protocol OIDCTokenStore: Sendable {
    func loadRefreshToken() -> String?
    @discardableResult func saveRefreshToken(_ token: String) -> Bool
    func loadIdentity() -> OIDCIdentity?
    @discardableResult func saveIdentity(_ identity: OIDCIdentity) -> Bool
    func clear()
    /// The OPTIONAL OAuth client secret to include on the token exchange and
    /// refresh grant. Needed only for Google "Desktop app" clients, which
    /// REQUIRE a client_secret even with PKCE; nil for every other client type
    /// (custom-scheme / iOS-type clients have no secret). It is CLIENT config,
    /// not a user credential, so `clear()` (sign-out) does NOT remove it.
    /// Defaulted to nil so existing conformers (test fakes) need no change.
    func oidcClientSecret() -> String?
}

public extension OIDCTokenStore {
    func oidcClientSecret() -> String? { nil }
}

/// Browser seam. The authenticator drives the interactive sign-in and returns
/// the redirect callback URL.
///
/// It receives a `buildAuthorizationURL` closure (NOT a finished URL) because
/// the EFFECTIVE redirect URI may not be known until the authenticator has run:
/// the loopback flow binds an ephemeral 127.0.0.1 port and only then knows the
/// real `http://127.0.0.1:<port>/...` redirect. Pass `nil` to build with the
/// CONFIGURED redirect (custom-scheme / ASWebAuthenticationSession path); pass a
/// concrete override to build with the loopback redirect. signIn captures the
/// effective redirect the closure was invoked with and uses it (port included)
/// for the token-exchange `redirect_uri` — so the two always match.
///
/// `callbackScheme` is the custom URL scheme ASWebAuthenticationSession should
/// intercept (derived from the configured redirect). It is `nil`/unused for the
/// loopback authenticator, which uses the system default browser instead.
public typealias OIDCAuthenticator =
    @Sendable (_ buildAuthorizationURL: @Sendable (_ redirectOverride: String?) -> URL,
               _ callbackScheme: String?) async throws -> URL

public enum OIDCSessionState: Sendable {
    case signedOut
    case signedIn(OIDCIdentity)
    case needsInteractive(OIDCAuthFailure)
}

/// Thread-safe one-slot box recording the redirect URI the authorization URL
/// was built with. The build closure runs synchronously inside the (possibly
/// off-actor) authenticator, so signIn can't read an actor-isolated var from
/// it; this NSLock-backed box bridges the value back. Falls back to the
/// configured redirect if the closure is never invoked.
private final class EffectiveRedirectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(default value: String) { self.stored = value }
    func set(_ v: String) { lock.lock(); stored = v; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return stored }
}

public actor OIDCSession {
    public static let callbackScheme = "parleq-auth"
    public static let redirectURI = "parleq-auth://oidc/callback"

    private let config: OIDCClientConfig
    private let httpClient: OIDCHTTPClient
    private let tokenStore: OIDCTokenStore
    private let authenticator: OIDCAuthenticator

    private var discovery: OIDCDiscovery?
    private var cachedIDToken: (token: String, exp: Date)?
    /// The access token from the SAME token response that produced
    /// `cachedIDToken`. Cached alongside the id_token but with its OWN
    /// expiry: the access expiry is `receiptTime + expires_in` (the OAuth
    /// access-token lifetime), whereas the id expiry is the id_token's `exp`
    /// claim. Those can diverge (an OP may issue a long-lived id_token with a
    /// short-lived access token, or vice versa), so `accessToken()` checks
    /// THIS expiry and `idToken()` checks the id expiry — both share the one
    /// single-flight refresh. Memory-only, never persisted (same as the
    /// id_token). Cleared at every site that clears `cachedIDToken`.
    private var cachedAccessToken: (token: String, exp: Date)?
    private var inFlightRefresh: Task<String, Error>?
    /// Monotonic id tagging each in-flight refresh `Task`. `Task` is a value
    /// type (no `===` identity), so sharedRefresh's `defer` compares this id to
    /// confirm it's clearing ITS OWN task and not a newer one a concurrent
    /// signOut()→new-refresh sequence installed while the old continuation was
    /// suspended. Without it the stale defer would wipe the newer task's
    /// reference and break single-flight for a third caller.
    private var inFlightRefreshID: Int = 0
    /// Bumped by signOut(). A refresh/sign-in that began before a sign-out
    /// captures the generation and refuses to write state after the await
    /// resumes — otherwise a token call completing post-sign-out would
    /// resurrect `.signedIn` over the user's explicit logout (and re-cache
    /// a token we just cleared). See applyIfCurrent / refreshNow.
    private var generation: Int = 0
    public private(set) var state: OIDCSessionState
    /// UI observers (OIDCSessionModel) register here; fired on every transition.
    private var stateObservers: [@Sendable (OIDCSessionState) -> Void] = []

    public init(config: OIDCClientConfig, httpClient: @escaping OIDCHTTPClient,
                tokenStore: OIDCTokenStore, authenticator: @escaping OIDCAuthenticator) {
        self.config = config; self.httpClient = httpClient
        self.tokenStore = tokenStore; self.authenticator = authenticator
        if let id = tokenStore.loadIdentity(), tokenStore.loadRefreshToken() != nil {
            self.state = .signedIn(id)
        } else {
            // .signedOut on this branch covers the normal pre-login case AND a
            // self-heal case: if a refresh token exists but the identity snapshot
            // is missing or corrupt (e.g. a prior saveIdentity failure), init
            // lands here as .signedOut. The first silent refresh (idToken()) will
            // succeed — re-deriving and re-persisting the identity — and flip the
            // session to .signedIn. One-launch cosmetic degradation, not a lockout.
            self.state = .signedOut
        }
    }

    /// Register a UI observer. Append-only: observers must capture `[weak self]`
    /// to avoid retaining their owner, and there is no deregistration — so
    /// re-binding the *same* session must be a no-op (enforced by the identity
    /// guard in OIDCSessionModel.bind) to avoid stacking duplicate observers.
    public func observeState(_ observer: @escaping @Sendable (OIDCSessionState) -> Void) {
        stateObservers.append(observer); observer(state)
    }
    /// Test seam: whether a valid-ish ID token is currently cached.
    /// Lets tests assert the cache is cleared after sign-out without exposing
    /// the token value. `internal` so it's reachable only via @testable import.
    var debugHasCachedToken: Bool { cachedIDToken != nil }
    /// Test seam: whether an access token is currently cached. Mirrors
    /// `debugHasCachedToken` for the googleOAuth path's access-token cache.
    var debugHasCachedAccessToken: Bool { cachedAccessToken != nil }
    private func setState(_ s: OIDCSessionState) {
        state = s; for o in stateObservers { o(s) }
    }

    /// Surface an interactive sign-in failure as `.needsInteractive`.
    /// `signIn()` deliberately doesn't flip state mid-flow (the caller owns
    /// the error surface), so the UI model calls this from its sign-in catch
    /// to paint the failure banner. Generation-guarded the same way as the
    /// silent path: a sign-out/sign-in that superseded the failed attempt
    /// must not be clobbered by a stale failure resolving afterwards.
    ///
    /// No-op when state is ALREADY `.needsInteractive(f)` for the SAME failure
    /// kind: the epoch-ending teardown paths (rotationLost / refreshTokenMissing)
    /// self-surface from inside the actor AFTER bumping the generation, so the
    /// model's catch — which captured the PRE-bump generation — would otherwise
    /// either no-op on the stale gen or double-paint the same banner. Treating an
    /// identical already-surfaced failure as a no-op lets the model blindly call
    /// this on every catch without special-casing the self-surfacing kinds.
    func surfaceInteractiveFailure(_ f: OIDCAuthFailure, gen: Int) {
        if case .needsInteractive(let existing) = state, existing.sameKind(as: f) { return }
        if gen == generation { setState(.needsInteractive(f)) }
    }

    /// End the current credential epoch and surface an interactive failure —
    /// the shared teardown for the two "this session can no longer renew
    /// itself" cases (`rotationLost`, `refreshTokenMissing`). Mirrors signOut's
    /// local block ordering: bump the generation FIRST (so any cached/in-flight
    /// cloud creds minted under the prior epoch are rejected by CachedExchange's
    /// generation checks — and so a pre-teardown CachedExchange hit can't keep
    /// serving creds), THEN clear the token store, drop the cached id_token, and
    /// publish `.needsInteractive(failure)`.
    ///
    /// Unlike signOut, this self-surfaces `.needsInteractive` rather than
    /// `.signedOut`: the teardown is a forced re-auth, not a user-initiated
    /// logout, so the banner must render. Because it bumps the generation, the
    /// model's pre-captured generation no longer matches — so the model must NOT
    /// also try to surface (it would no-op on the stale gen anyway); the
    /// `sameKind` short-circuit in surfaceInteractiveFailure makes a redundant
    /// model-side call a harmless no-op.
    private func tearDownLocalSession(surfacing failure: OIDCAuthFailure) {
        generation &+= 1
        inFlightRefresh?.cancel(); inFlightRefresh = nil
        tokenStore.clear()
        cachedIDToken = nil
        cachedAccessToken = nil
        setState(.needsInteractive(failure))
    }

    /// The current generation, so an interactive sign-in caller can capture
    /// it before the flow and pass it back to `surfaceInteractiveFailure`.
    func currentGeneration() -> Int { generation }

    // MARK: discovery
    private func discover() async throws -> OIDCDiscovery {
        if let d = discovery { return d }
        let base = config.issuer.hasSuffix("/") ? String(config.issuer.dropLast()) : config.issuer
        guard let issuerURL = URL(string: base) else {
            throw OIDCAuthFailure.discoveryFailed(detail: "invalid issuer URL")
        }
        // Apply the same HTTPS-or-loopback-HTTP rule to the issuer itself as we
        // do to the discovered endpoints. A plain-HTTP non-loopback issuer would
        // let a network attacker substitute a discovery document and redirect
        // every subsequent token exchange — block it here, before the fetch.
        guard issuerURL.scheme == "https" || (issuerURL.scheme == "http" && isLoopbackHost(issuerURL)) else {
            throw OIDCAuthFailure.discoveryFailed(detail: "issuer must use HTTPS")
        }
        guard let url = URL(string: base + "/.well-known/openid-configuration") else {
            throw OIDCAuthFailure.discoveryFailed(detail: "invalid issuer URL")
        }
        do {
            let (data, resp) = try await httpClient(URLRequest(url: url))
            guard resp.statusCode == 200 else {
                throw OIDCAuthFailure.discoveryFailed(detail: "HTTP \(resp.statusCode) from discovery")
            }
            let d = try OIDCDiscovery.parse(data); discovery = d; return d
        } catch let f as OIDCAuthFailure { throw f }
        catch { throw OIDCAuthFailure.discoveryFailed(detail: error.localizedDescription) }
    }

    // MARK: interactive sign-in
    @discardableResult
    public func signIn() async throws -> OIDCIdentity {
        let gen = generation
        let d = try await discover()
        let pkce = PKCE.generate()
        let oidcState = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64URLEncoded()
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64URLEncoded()
        // Derive the redirect URI and its callback scheme from config. The
        // browser-interception scheme is the URL scheme component of the
        // redirect (e.g. "parleq-auth", or a Google reversed-client-ID scheme).
        // Fall back to the static defaults if the configured redirect is
        // unparseable — validation at the config layer keeps that from
        // happening, but a defaulted OIDCClientConfig (tests, callers that omit
        // the field) deliberately carries the static redirect/scheme.
        let configuredRedirect = config.redirectURI
        let callbackScheme = URL(string: configuredRedirect)?.scheme ?? Self.callbackScheme
        // RESERVED params are protected — Parleq controls them and an override
        // would break the flow's security properties (PKCE / state / nonce
        // binding) or its identity (client_id / scope / redirect_uri).
        let reservedAuthParams: Set<String> = [
            "response_type", "client_id", "redirect_uri", "scope",
            "state", "nonce", "code_challenge", "code_challenge_method",
        ]
        let authConfig = config  // capture for the @Sendable build closure
        // The build closure produces the authorization URL for whatever redirect
        // the authenticator chooses. `redirectOverride == nil` → the configured
        // redirect (custom-scheme path); a concrete value → the loopback
        // redirect (ephemeral port). The closure records the redirect it used so
        // the token exchange below can send the SAME value as `redirect_uri`.
        let effectiveRedirectBox = EffectiveRedirectBox(default: configuredRedirect)
        let authEndpoint = d.authorizationEndpoint
        let buildAuthorizationURL: @Sendable (String?) -> URL = { redirectOverride in
            let redirectURI = redirectOverride ?? configuredRedirect
            effectiveRedirectBox.set(redirectURI)
            var comps = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
            comps.queryItems = (comps.queryItems ?? []) + [
                .init(name: "response_type", value: "code"),
                .init(name: "client_id", value: authConfig.clientID),
                .init(name: "redirect_uri", value: redirectURI),
                .init(name: "scope", value: authConfig.scopes.joined(separator: " ")),
                .init(name: "state", value: oidcState),
                .init(name: "nonce", value: nonce),
                .init(name: "code_challenge", value: pkce.challenge),
                .init(name: "code_challenge_method", value: "S256"),
            ]
            // Append configured extra auth params (e.g. Google's
            // access_type=offline + prompt=consent). Drop any reserved key with
            // a count-only log line; the remainder are appended in deterministic
            // key order for a stable URL.
            for key in authConfig.extraAuthParams.keys.sorted() {
                guard !reservedAuthParams.contains(key) else {
                    logStderrOIDC("oidc extra-auth-param ignored (reserved)")
                    continue
                }
                comps.queryItems?.append(.init(name: key, value: authConfig.extraAuthParams[key]))
            }
            return comps.url!
        }
        let callback = try await authenticator(buildAuthorizationURL, callbackScheme)
        // The redirect the authorization URL was actually built with — the
        // loopback flow's ephemeral-port value, or the configured redirect on
        // the custom-scheme path. The token exchange MUST echo this exact value.
        let redirectURI = effectiveRedirectBox.value
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // STATE VALIDATION FIRST — a forged/CSRF redirect must NOT be able to
        // dress itself up as a diagnosable IdP error. A mismatched (or absent)
        // state stays callbackInvalid regardless of any error/code params it
        // carries; only a state-matched callback proceeds to interpret the rest.
        guard items.first(where: { $0.name == "state" })?.value == oidcState else {
            throw OIDCAuthFailure.callbackInvalid
        }
        // The IdP error-redirected to our callback (OAuth 2.0 §4.1.2.1): surface
        // it as the diagnosable idpRejected rather than the misleading
        // callbackInvalid copy. error is the machine code; error_description is
        // IdP prose (doctor/UI only, never logged — see idpRejected).
        if let error = items.first(where: { $0.name == "error" })?.value {
            // `error` is IdP-controlled and lands in idpRejected.code, which is
            // logged verbatim. A nonconforming IdP could put prose / sensitive
            // text / log-breaking chars there, so accept it for `.code` only if
            // it matches the RFC 6749 §4.1.2.1 error-code charset (the spec
            // forbids space, '"', and '\'); we bound it further to a log-safe
            // token. Otherwise use a fixed code and keep the raw value ONLY in
            // the doctor-only `detail` (never logged — see idpRejected.logLine).
            let code = Self.isLogSafeErrorCode(error) ? error : "nonstandard_error"
            var detail = items.first(where: { $0.name == "error_description" })?.value ?? ""
            if code != error && detail.isEmpty { detail = error }
            throw OIDCAuthFailure.idpRejected(code: code, detail: detail)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw OIDCAuthFailure.callbackInvalid
        }
        // Interactive sign-in: a non-200 here throws (it does NOT flip the
        // session to needsInteractive — the user is mid-flow and the caller
        // owns the error surface). The generation guard drops a result that
        // a concurrent signOut() superseded mid-exchange.
        let resp = try await tokenCall(d, body: [
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": redirectURI, "client_id": config.clientID,
            "code_verifier": pkce.verifier,
        ])
        // OIDC §3.1.3.7: the interactive token response's id_token MUST echo the
        // exact `nonce` we sent in the authorization request. A mismatch (or a
        // missing nonce) means the id_token isn't bound to this flow — reject as
        // callbackInvalid. This check is ONLY done on the interactive path: a
        // refresh_token response doesn't carry the original nonce on all IdPs
        // (Keycloak echoes it, Okta may not), so refreshNow() must not verify it.
        guard OIDCIdentity.claim("nonce", idToken: resp.idToken) == nonce else {
            throw OIDCAuthFailure.callbackInvalid
        }
        // GRANTED-SCOPE VERIFICATION (RFC 6749 §5.1). The token response MAY
        // echo the granted `scope`; Google ALWAYS does, even when it differs
        // from the request — which is exactly the granular-consent downgrade we
        // need to catch (user signs in but doesn't tick the cloud-platform box,
        // so the access token can't reach Vertex and 403s). If the response
        // carries a granted set, fail the INTERACTIVE sign-in when a required
        // scope is missing — BEFORE the epoch bump / commit, so nothing is
        // persisted and the model's pre-captured generation still matches (the
        // banner renders). Silent refresh stays lenient and never runs this.
        // No `scope` field → can't verify → proceed (handled by the nil guard).
        if let granted = resp.grantedScopes {
            let missing = Self.unmetRequiredScopes(requested: config.scopes, granted: granted)
            if !missing.isEmpty {
                throw OIDCAuthFailure.scopeNotGranted(missing: missing)
            }
        }
        // CRITICAL ORDERING — all THROWING work happens BEFORE the epoch bump.
        // The bump opens a new credential epoch and is observed by
        // CachedExchange's generation checks and by surfaceInteractiveFailure
        // (the UI model captures the PRE-bump generation before this flow). If a
        // throw landed AFTER the bump, the UI model's pre-captured generation
        // would no longer match the (already-bumped) value, so its
        // surfaceInteractiveFailure call would no-op — leaving NO failure banner
        // AND a bumped epoch that invalidated the prior session's cloud creds.
        // So we re-anchor, then do every throwing step (validate: id_token parse
        // + rotated-RT persistence), and only THEN bump and run the non-throwing
        // commit. Any failure leaves the generation untouched, so the model's
        // pre-captured generation still matches and the banner renders.
        //
        // The `gen` captured at the top of this flow guarded the in-flight token
        // exchange against a signOut() landing mid-await; re-anchor here BEFORE
        // validate so a concurrent signOut() is honored (we don't re-persist a
        // rotated RT over a store the sign-out just cleared).
        guard gen == generation else { throw OIDCAuthFailure.signInCancelled }
        // validate() is identity-agnostic w.r.t. the epoch: it parses the
        // id_token and persists the rotated refresh token (both throwing). It's
        // safe to do pre-bump — the RT belongs to whatever session is current,
        // and the re-anchor guard above already confirmed that's still us.
        //
        // requireRefreshToken: true — interactive auth-code sign-in REJECTS a
        // response with no refresh_token (offline_access not granted). NOTE: that
        // rejection, like the rotationLost rejection, self-tears-down (bumps the
        // epoch + self-surfaces .needsInteractive) from INSIDE validate before
        // throwing — so for those two kinds the "generation untouched on throw"
        // invariant the comment above describes deliberately does NOT hold. The
        // model's catch still calls surfaceInteractiveFailure, but it no-ops:
        // the session already painted the banner (sameKind short-circuit), and
        // the model's pre-captured generation is now stale anyway. Every OTHER
        // throw from validate (e.g. id_token parse) leaves the generation intact,
        // so the model surfaces those as before.
        let prepared = try validate(resp, requireRefreshToken: true)
        // A successful interactive sign-in opens a NEW credential epoch: re-auth
        // may be an ACCOUNT SWITCH — pre-existing cloud credentials must not
        // outlive it. Bump AFTER all throwing work so any cached or in-flight
        // cloud credentials minted under the PRIOR identity are rejected by
        // CachedExchange's generation checks (cache-hit / in-flight-join /
        // exchangeNow). commit() is non-throwing.
        generation &+= 1
        commit(prepared)
        guard case .signedIn(let id) = state else { throw OIDCAuthFailure.sessionExpired(code: "no identity") }
        return id
    }

    // MARK: silent path
    /// Valid (≥60 s remaining) ID token, refreshing silently if needed.
    public func idToken() async throws -> String {
        if let c = cachedIDToken, c.exp.timeIntervalSinceNow > 60 { return c.token }
        _ = try await sharedRefresh()
        guard let c = cachedIDToken else {
            throw OIDCAuthFailure.sessionExpired(code: "no id token after refresh")
        }
        return c.token
    }

    /// Valid (≥60 s remaining) OAuth ACCESS token, refreshing silently if
    /// needed. Used by the Vertex `googleOAuth` mode, where the access token
    /// is a direct Vertex bearer (what gcloud ADC produces, in-app). Mirrors
    /// `idToken()` exactly — same single-flight refresh, same ≥60 s freshness
    /// gate, same error taxonomy — but checks the access token's OWN expiry,
    /// which can diverge from the id_token's. A refresh repopulates BOTH
    /// caches via commit(), so concurrent `idToken()` + `accessToken()`
    /// callers share the one in-flight refresh (a single network call).
    public func accessToken() async throws -> String {
        if let c = cachedAccessToken, c.exp.timeIntervalSinceNow > 60 { return c.token }
        _ = try await sharedRefresh()
        guard let c = cachedAccessToken else {
            throw OIDCAuthFailure.sessionExpired(code: "no access token after refresh")
        }
        return c.token
    }

    /// Drop ONLY the cached access token, forcing the next `accessToken()` call
    /// to mint a fresh one via a silent refresh. Used by the Vertex
    /// `googleOAuth` 401-retry path: a token revoked server-side but still
    /// cached here would otherwise 401 twice and fail closed until natural
    /// expiry (~59 min). This is a pure cache-drop (mirrors
    /// `CachedExchange.invalidate()`): the id_token and refresh token stay put
    /// and the generation is NOT bumped — the session is still validly signed
    /// in, it just needs to re-derive its access token on the next read.
    public func invalidateAccessToken() {
        cachedAccessToken = nil
    }

    /// RFC 6749 §4.1.2.1 error codes are restricted to a small charset (the
    /// spec forbids space, double-quote, and backslash). We accept a bounded
    /// token of letters/digits/underscore/dot/hyphen so the value is safe to
    /// log verbatim in idpRejected.logLine.
    static func isLogSafeErrorCode(_ s: String) -> Bool {
        guard (1...64).contains(s.count) else { return false }
        return s.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "." || c == "-")
        }
    }

    /// Standard OIDC scopes that IdPs normalize/echo INCONSISTENTLY — Cognito,
    /// Okta, etc. drop or rename these in the granted set even when they were
    /// honored, so a strict requested-vs-granted diff would false-positive on
    /// them. We deliberately do NOT enforce these; only scopes OUTSIDE this set
    /// (e.g. Google's `cloud-platform`) gate the sign-in.
    static let unenforcedScopes: Set<String> = [
        "openid", "profile", "email", "offline_access",
    ]

    /// The requested scopes that the granted set didn't include, EXCLUDING the
    /// standard OIDC scopes (see `unenforcedScopes`). Order-preserving on the
    /// requested list for a stable doctor/log rendering. An empty result means
    /// every enforceable requested scope was granted.
    static func unmetRequiredScopes(requested: [String], granted: [String]) -> [String] {
        let grantedSet = Set(granted)
        return requested.filter { !unenforcedScopes.contains($0) && !grantedSet.contains($0) }
    }

    /// The single-flight silent refresh shared by `idToken()` and
    /// `accessToken()`. Both accessors check their own cache first, then call
    /// this on a miss; the actor serializes entry, so concurrent callers join
    /// the same in-flight `Task` and trigger exactly one network round-trip.
    /// The refresh's `commit()` repopulates BOTH the id and access caches, so
    /// each accessor reads its freshly-cached token after this returns.
    @discardableResult
    private func sharedRefresh() async throws -> String {
        if let inflight = inFlightRefresh { return try await inflight.value }
        let task = Task<String, Error> { try await self.refreshNow() }
        inFlightRefreshID &+= 1
        let myID = inFlightRefreshID
        inFlightRefresh = task
        // Identity-checked clear: if signOut() (or a teardown) cancelled this
        // refresh and a NEW refresh task was installed before this one's
        // continuation resumed on the actor, clearing unconditionally would
        // wipe the newer task's reference and break single-flight for a third
        // caller. Only clear if we're still the in-flight task (Task is a value
        // type with no `===`, so compare the per-task id).
        defer { if inFlightRefreshID == myID { inFlightRefresh = nil } }
        return try await task.value
    }
    private func refreshNow() async throws -> String {
        let gen = generation
        guard let rt = tokenStore.loadRefreshToken() else {
            if gen == generation { setState(.signedOut) }
            throw OIDCAuthFailure.sessionExpired(code: "no refresh token")
        }
        // INTENTIONAL ASYMMETRY: a discovery failure here (network
        // unreachable, DNS, captive portal) throws WITHOUT flipping the
        // session to .needsInteractive — the refresh token is still
        // valid and the next refresh may simply succeed. Transient
        // connectivity loss must not paint "Signed out of your
        // organization"; the dictation-level fail-closed notice covers
        // the moment. Only an IdP REJECTION (tokenCall's catch below)
        // ends the session's claim to be signed in.
        let d = try await discover()
        do {
            // Deliberately OMIT `scope` on the refresh grant (RFC 6749 §6): an
            // absent scope means "the same scope as originally granted", which
            // is strictly safer than re-sending the full configured list. Sending
            // it risks an `invalid_scope` rejection when the originally-GRANTED
            // set was narrower than configured (e.g. the user skipped Google's
            // cloud-platform granular-consent box) — which the silent path would
            // map to sessionExpired and tear the session down. Let the IdP reissue
            // exactly what it granted.
            let resp = try await tokenCall(d, body: [
                "grant_type": "refresh_token", "refresh_token": rt,
                "client_id": config.clientID,
            ])
            try applyIfCurrent(resp, gen: gen)
            return resp.idToken
        } catch let f as OIDCAuthFailure {
            // Silent path: a failed refresh means the session can no longer
            // renew itself, so surface needsInteractive — but only if no
            // sign-out/sign-in superseded this refresh while it was in flight.
            if gen == generation { setState(.needsInteractive(f)) }
            throw f
        }
    }
    /// Issues the token request. Maps non-200 to `.sessionExpired(code:)` and
    /// throws — it deliberately does NOT mutate session state. Whether a failure
    /// should flip the session (silent refresh → needsInteractive) or leave it
    /// untouched (interactive sign-in → just propagate) is the caller's call.
    private func tokenCall(_ d: OIDCDiscovery, body: [String: String]) async throws -> OIDCTokenResponse {
        var req = URLRequest(url: d.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Add the OPTIONAL client_secret to BOTH the authorization-code exchange
        // and the refresh grant (the only two callers): Google "Desktop app"
        // clients reject a token request without it (invalid_request) even though
        // PKCE is in use. When the store returns nil (the common case) the key is
        // omitted entirely — the form body is byte-identical to before. The secret
        // is percent-encoded by formEncode (conservative `.alphanumerics`) exactly
        // like every other field, so arbitrary chars round-trip safely; it is
        // never logged (the body is never logged).
        var fullBody = body
        if let secret = tokenStore.oidcClientSecret() {
            fullBody["client_secret"] = secret
        }
        req.httpBody = fullBody.map { k, v in "\(k)=\(formEncode(v))" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await httpClient(req)
        guard resp.statusCode == 200 else {
            // The server's JSON `error` is IdP-controlled and lands in
            // sessionExpired.code, which is logged verbatim. A nonconforming
            // IdP could put prose / sensitive text / log-breaking chars there,
            // so accept it only if it matches the log-safe error-code charset
            // (mirrors the interactive idpRejected gate); otherwise fall back
            // to the status-only code. sessionExpired has no doctor-only detail
            // slot, so the raw value is simply dropped.
            let raw = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                .flatMap { $0["error"] as? String })
            let code: String
            if let raw, Self.isLogSafeErrorCode(raw) {
                code = raw
            } else {
                code = "HTTP \(resp.statusCode)"
            }
            throw OIDCAuthFailure.sessionExpired(code: code)
        }
        return try OIDCTokenResponse.parse(data)
    }
    /// Apply a token response only if no sign-out/sign-in happened while the
    /// token call was in flight. Without the generation guard, a refresh that
    /// resolves after signOut() would re-persist a token and resurrect
    /// `.signedIn` over the user's logout (TOCTOU on the actor's awaits).
    private func applyIfCurrent(_ resp: OIDCTokenResponse, gen: Int) throws {
        guard gen == generation else { throw OIDCAuthFailure.signInCancelled }
        try apply(resp)
    }
    /// Run the full apply on the SILENT refresh path: all throwing work
    /// (validate) followed by the non-throwing state commit. The interactive
    /// sign-in path does NOT call this — it interleaves the epoch bump between
    /// validate() and commit() (see signIn) so the bump happens only after every
    /// throwing step has succeeded.
    private func apply(_ resp: OIDCTokenResponse) throws {
        let prepared = try validate(resp)
        commit(prepared)
    }

    /// The fully-validated, ready-to-commit result of a token response: the
    /// parsed identity, the id_token to cache, and its computed expiry. Produced
    /// by validate() (which has already done every throwing step, including
    /// persisting the rotated refresh token); consumed by commit() (which only
    /// does non-throwing state mutation under the current epoch).
    private struct Prepared {
        let identity: OIDCIdentity
        let idToken: String
        let exp: Date
        /// The access token from the same response and its expiry
        /// (`receiptTime + expires_in`). Cached by commit() for the
        /// googleOAuth Vertex path (`accessToken()`).
        let accessToken: String
        let accessExp: Date
    }

    /// ALL throwing work for a token response. Splitting this out from
    /// commit() lets signIn() complete every fallible step BEFORE bumping
    /// the epoch — so an ORDINARY failure here never leaves a bumped epoch
    /// behind, and the only session-state mutation on the happy path is
    /// the (identity-agnostic) rotated-RT persistence.
    ///
    /// TWO EXCEPTION PATHS mutate session state fully before throwing:
    /// `rotationLost` (the rotated RT couldn't be persisted) and
    /// `refreshTokenMissing` (interactive path, no RT granted) both call
    /// tearDownLocalSession — bumping the generation, cancelling in-flight
    /// refresh, clearing the cached token + token store, and publishing
    /// .needsInteractive. Those sessions are unrecoverable locally, so the
    /// teardown IS the correct terminal state; every other throw site
    /// leaves generation and state untouched.
    ///
    /// CRITICAL ORDERING: the rotated refresh token is persisted IMMEDIATELY on
    /// receipt, before parsing the id_token — Okta-style rotation
    /// replay-detection means losing the new RT costs a re-login.
    private func validate(_ resp: OIDCTokenResponse, requireRefreshToken: Bool = false) throws -> Prepared {
        if let rotated = resp.refreshToken {
            // A rotation whose new RT couldn't be persisted is a lost session:
            // the IdP has already invalidated the OLD refresh token (Okta-style
            // replay detection), and the NEW one didn't reach the Keychain — so
            // the next silent refresh would present a dead token. Fail loudly NOW
            // rather than surfacing a confusing failure on the next refresh.
            //
            // Tear down ALL local state before throwing: the OLD refresh token +
            // identity are still persisted and a cachedIDToken may still be live,
            // so a restart would rehydrate .signedIn with a refresh token the IdP
            // has already rotated away — deferring the same failure to a more
            // confusing place (a silent refresh that 400s with invalid_grant).
            // The old RT is dead at the IdP under rotation; keeping it buys
            // nothing. The teardown also BUMPS the generation (epoch end) so a
            // CachedExchange hit minted under the prior epoch can't keep serving
            // cloud creds, and self-surfaces .needsInteractive(.rotationLost) so
            // the banner renders without a model-side surface (which would no-op
            // on its now-stale pre-bump generation). See tearDownLocalSession.
            guard tokenStore.saveRefreshToken(rotated) else {
                tearDownLocalSession(surfacing: .rotationLost)
                throw OIDCAuthFailure.rotationLost
            }
        } else if requireRefreshToken {
            // Interactive auth-code sign-in MUST be granted a refresh_token: with
            // none, Parleq has no offline persistence (the session dies on the
            // next relaunch) AND a stale previous-account RT left in the store
            // could later resurrect the old identity on a silent refresh. Tear
            // down the local session — clearing ANY prior account's RT is the
            // account-switch hygiene that prevents that resurrection — bump the
            // epoch, self-surface .needsInteractive(.refreshTokenMissing), and
            // reject the sign-in. Silent refresh passes requireRefreshToken=false
            // (non-rotating IdPs reissue the same RT and may omit it on refresh).
            tearDownLocalSession(surfacing: .refreshTokenMissing)
            throw OIDCAuthFailure.refreshTokenMissing
        }
        let exp = OIDCIdentity.claimDates(idToken: resp.idToken).exp
            ?? Date().addingTimeInterval(resp.expiresIn)
        // Access-token expiry rides the OAuth `expires_in` lifetime measured
        // from receipt — NOT the id_token's `exp` claim. The two can diverge
        // (a long-lived id_token alongside a short-lived access token, common
        // with Google), so the access cache carries its own expiry that
        // `accessToken()` checks independently of `idToken()`.
        let accessExp = Date().addingTimeInterval(resp.expiresIn)
        let id = try OIDCIdentity.from(idToken: resp.idToken,
                                       issuer: config.issuer, clientID: config.clientID)
        return Prepared(identity: id, idToken: resp.idToken, exp: exp,
                        accessToken: resp.accessToken, accessExp: accessExp)
    }

    /// Non-throwing state commit for a validated token response. Caches the
    /// id_token, best-effort-persists the identity, and publishes .signedIn.
    /// Caller is responsible for the epoch/generation guard: the silent path
    /// guards via applyIfCurrent before apply(); the interactive path bumps the
    /// epoch immediately before calling commit().
    private func commit(_ prepared: Prepared) {
        // cache only a fully-accepted response — a malformed id_token can't reach
        // here (validate threw), so this never leaves a usable token behind with
        // no state transition.
        cachedIDToken = (prepared.idToken, prepared.exp)
        cachedAccessToken = (prepared.accessToken, prepared.accessExp)
        if !tokenStore.saveIdentity(prepared.identity) {
            // count-only: identity save failed (e.g. Keychain unavailable)
            logStderrOIDC("oidc identity-save failed")
        }
        setState(.signedIn(prepared.identity))
    }
    /// `application/x-www-form-urlencoded` value encoding. `.alphanumerics` is
    /// deliberately conservative — it encodes every reserved/sub-delim byte,
    /// so PKCE verifiers, rotated refresh tokens, scopes with spaces, etc. all
    /// round-trip safely. Shared by token and revocation requests.
    nonisolated static func formEncode(_ v: String) -> String {
        v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v
    }
    private func formEncode(_ v: String) -> String { Self.formEncode(v) }

    /// Sign out. Local state is cleared SYNCHRONOUSLY and FIRST — there must be
    /// NO await before the clear block below, so a stalled or slow IdP can never
    /// leave the user "signed in" locally with reusable cloud creds, and an app
    /// exit mid-sign-out can never leave the refresh token in the Keychain.
    /// Revocation is best-effort (RFC 7009) and FIRE-AND-FORGET: it runs in a
    /// detached Task with the captured token + httpClient, so signOut() RETURNS
    /// the instant local state is cleared. The caller's post-sign-out work
    /// (cloud-credential cache invalidation in main.swift) therefore runs
    /// immediately instead of waiting on a network round-trip.
    public func signOut() {
        // (1) Capture the refresh token BEFORE clearing — the detached
        // revocation needs it, and clear() is about to wipe it.
        let rt = tokenStore.loadRefreshToken()
        // Capture cached discovery if we already have it, so the detached task
        // can revoke without an extra round-trip; otherwise it discovers itself.
        let cachedDiscovery = discovery

        // (2) Clear local state IMMEDIATELY — no awaits before this block.
        // Bump first so any refresh/sign-in still awaiting a token call bails
        // out (applyIfCurrent) instead of resurrecting state after we clear.
        generation &+= 1
        inFlightRefresh?.cancel(); inFlightRefresh = nil
        tokenStore.clear()
        cachedIDToken = nil
        cachedAccessToken = nil
        setState(.signedOut)

        // (3) Best-effort revocation AFTER, fire-and-forget. `rt`, `config`,
        // `httpClient`, and `cachedDiscovery` are all Sendable, so this detaches
        // cleanly under Swift 6. signOut() does not await it.
        guard let rt else { return }
        let httpClient = self.httpClient
        let config = self.config
        Task.detached { [weak self] in
            // Use cached discovery if present; otherwise resolve it through the
            // actor (discover() only populates the cache — safe post-sign-out).
            let d: OIDCDiscovery?
            if let cachedDiscovery { d = cachedDiscovery }
            else { d = try? await self?.discover() }
            guard let revoke = d?.revocationEndpoint else { return }
            var req = URLRequest(url: revoke); req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            // RFC 7009 form body: token + client_id MUST be percent-encoded
            // (refresh tokens routinely contain '/', '+', '=' that would
            // otherwise corrupt the body and silently fail revocation).
            req.httpBody = "token=\(Self.formEncode(rt))&client_id=\(Self.formEncode(config.clientID))"
                .data(using: .utf8)
            _ = try? await httpClient(req)  // best-effort (RFC 7009)
        }
    }
}

/// SwiftUI-facing mirror of the actor's state. Views observe this;
/// the session pushes transitions via observeState. Once `bind(to:)`
/// has run, the model also retains the session so the Company Account
/// view can drive sign-in / sign-out / silent-refresh through the
/// model without re-plumbing the actor handle through every closure.
@MainActor
public final class OIDCSessionModel: ObservableObject {
    @Published public private(set) var state: OIDCSessionState = .signedOut
    /// Retained after bind(to:) so signIn/signOut/idToken passthroughs
    /// reach the actor. Weak would drop the session AppState/main own —
    /// but those owners outlive this model, so a strong ref is fine and
    /// avoids a nil-after-bind footgun in the UI closures.
    private var session: OIDCSession?
    public init() {}
    public func bind(to session: OIDCSession) async {
        // observeState is append-only with no deregistration, so re-binding the
        // same session would stack a duplicate observer. Identity-guard it: a
        // repeat bind to the already-bound session is a no-op.
        if self.session === session { return }
        self.session = session
        await session.observeState { [weak self] s in
            Task { @MainActor in self?.state = s }
        }
    }

    /// Interactive sign-in. The ONLY trigger of the browser sheet —
    /// never called automatically. `signInCancelled` is swallowed
    /// silently (the user dismissed the sheet); every other failure
    /// propagates so the caller can decide whether to surface it (the
    /// session itself already flips to `.needsInteractive` on a failed
    /// *silent* refresh, but interactive sign-in leaves the surface to
    /// the caller). No token or identity content is logged here.
    public func signIn() async {
        guard let session else { return }
        // Capture the generation before the flow so a sign-out/sign-in that
        // supersedes this attempt mid-exchange suppresses a stale failure
        // banner (surfaceInteractiveFailure is generation-guarded).
        let gen = await session.currentGeneration()
        do { _ = try await session.signIn() }
        catch let f as OIDCAuthFailure where f.isSilent { /* user cancelled — silent */ }
        catch let f as OIDCAuthFailure {
            // signIn() doesn't flip state mid-flow — without this the failure
            // would be invisible. Ask the session to surface it as a banner.
            await session.surfaceInteractiveFailure(f, gen: gen)
        }
        catch {
            // Non-OIDC error (e.g. a thrown URLError from the browser bridge):
            // wrap as discoveryFailed so the UI still gets a banner.
            await session.surfaceInteractiveFailure(
                .discoveryFailed(detail: error.localizedDescription), gen: gen)
        }
    }
    public func signOut() async {
        await session?.signOut()
    }
    /// Token-free connection check: forces a silent refresh (which
    /// re-validates the refresh token against the IdP and updates the
    /// session state) without returning the token to the UI. Throwing
    /// is swallowed — the doctor reads the resulting state, not the
    /// throw — so callers can `try? await`.
    public func refreshSession() async {
        _ = try? await session?.idToken()
    }
}
