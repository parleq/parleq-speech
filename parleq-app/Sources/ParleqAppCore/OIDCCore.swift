import CryptoKit
import Foundation

/// Injected HTTP seam for everything OIDC/STS-shaped. Unit tests supply
/// canned responses; production uses URLSession (wired in ParleqApp).
public typealias OIDCHTTPClient = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// URLErrors (network, TLS, timeout) propagate unwrapped; callers are responsible
/// for mapping them into OIDCAuthFailure before surfacing to the UI layer.
public func urlSessionOIDCHTTPClient() -> OIDCHTTPClient {
    // Dedicated ephemeral session for all OIDC/STS traffic. Defense-in-depth:
    // token / STS responses are POST and not cacheable today, but an ephemeral
    // config (no persistent cache, cookies, or credential store) plus an
    // explicitly-nulled urlCache and a cache-bypassing request policy guarantee
    // a cacheable token response can never land in ~/Library/Caches. Built once
    // and captured so every request reuses the same connection pool.
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let session = URLSession(configuration: config)
    return { request in
        var request = request
        // Bound every OIDC/STS HTTP request. Without this a hung connection
        // (DNS black-hole, stalled TLS handshake) would never resolve, wedging
        // the single-flight in-flight task it backs (discovery, token refresh,
        // STS/STS-token exchange) indefinitely. With a 30s cap no request can
        // hang past 30s, so those single-flight tasks self-heal — the next
        // caller starts a fresh attempt rather than awaiting a dead one.
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OIDCAuthFailure.discoveryFailed(detail: "non-HTTP response")
        }
        return (data, http)
    }
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public static func generate() -> PKCE {
        var rng = SystemRandomNumberGenerator()
        // `UInt8.random(in:using:)` rather than `rng.next() as UInt8`: both
        // type-check (RandomNumberGenerator has a generic
        // `next<T: FixedWidthInteger & UnsignedInteger>() -> T`), but the
        // typed-random spelling reads unambiguously as "a random byte".
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        let verifier = Data(bytes).base64URLEncoded()
        return PKCE(verifier: verifier, challenge: challenge(forVerifier: verifier))
    }
    public static func challenge(forVerifier verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func base64URLDecoded(_ s: String) -> Data? {
        // A base64 string with length % 4 == 1 is structurally impossible — reject early.
        guard s.count % 4 != 1 else { return nil }
        var b = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

/// Returns true when the URL's host is a loopback address (localhost, 127.0.0.1,
/// or ::1). Plain HTTP is permitted for loopback only — the in-repo Keycloak dev
/// rig; every non-loopback OIDC URL must be HTTPS. Used by both
/// `OIDCDiscovery.parse` (endpoint guard) and `OIDCSession.discover` (issuer guard)
/// so the rule is defined once and reused rather than duplicated.
func isLoopbackHost(_ url: URL) -> Bool {
    url.host == "localhost" || url.host == "127.0.0.1" || url.host == "::1"
}

public struct OIDCDiscovery: Sendable {
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let revocationEndpoint: URL?
    public static func parse(_ data: Data) throws -> OIDCDiscovery {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = (obj["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (obj["token_endpoint"] as? String).flatMap(URL.init(string:))
        else { throw OIDCAuthFailure.discoveryFailed(detail: "missing endpoints in discovery document") }
        // Enforce HTTPS on the auth/token endpoints. Plain HTTP is permitted for
        // loopback only — the in-repo Keycloak dev rig; every non-loopback issuer
        // must be HTTPS.
        for endpoint in [auth, token] {
            guard endpoint.scheme == "https" || (endpoint.scheme == "http" && isLoopbackHost(endpoint)) else {
                throw OIDCAuthFailure.discoveryFailed(detail: "endpoints must use HTTPS")
            }
        }
        let revoke = (obj["revocation_endpoint"] as? String).flatMap(URL.init(string:))
        // Revocation endpoint carries a live refresh token — apply the same
        // HTTPS-or-loopback-HTTP guard as auth/token so a tampered discovery
        // document can't redirect it to a plain-HTTP exfiltration host.
        if let revoke {
            guard revoke.scheme == "https" || (revoke.scheme == "http" && isLoopbackHost(revoke)) else {
                throw OIDCAuthFailure.discoveryFailed(detail: "endpoints must use HTTPS")
            }
        }
        return OIDCDiscovery(authorizationEndpoint: auth, tokenEndpoint: token, revocationEndpoint: revoke)
    }
}

public struct OIDCTokenResponse: Sendable {
    public let accessToken: String
    public let idToken: String
    public let refreshToken: String?   // present when the IdP rotates
    public let expiresIn: TimeInterval
    /// The GRANTED scope set (RFC 6749 §5.1), space-delimited in the wire
    /// response. OPTIONAL per the spec ("if identical to the requested scope
    /// … OPTIONAL"), but Google ALWAYS includes it — and includes it even when
    /// it differs from the request, which is exactly the granular-consent
    /// downgrade signIn() verifies. nil when the response omitted it (we then
    /// can't verify and proceed). Split on spaces here so callers compare sets.
    public let grantedScopes: [String]?
    public static func parse(_ data: Data) throws -> OIDCTokenResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = obj["access_token"] as? String,
              let idt = obj["id_token"] as? String
        else { throw OIDCAuthFailure.sessionExpired(code: "malformed token response") }
        let granted = (obj["scope"] as? String).map {
            $0.split(separator: " ").map(String.init)
        }
        return OIDCTokenResponse(
            accessToken: at, idToken: idt,
            refreshToken: obj["refresh_token"] as? String,
            expiresIn: (obj["expires_in"] as? Double) ?? 3600,
            grantedScopes: granted)
    }
}

public struct OIDCIdentity: Codable, Sendable, Equatable {
    public let issuer: String
    public let clientID: String
    public let sub: String
    public let email: String?
    public let name: String?
    public let obtainedAt: Date

    /// Prefer the IdP-provided display name; fall back to the email,
    /// then the subject. Always non-empty — UI labels render this so
    /// no signed-in state can show blank.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let email, !email.isEmpty { return email }
        return sub
    }

    /// Decode the (unvalidated) JWT payload for display/attribution only.
    /// Parleq NEVER trusts these claims for security decisions — the
    /// clouds validate the token themselves.
    public static func from(idToken: String, issuer: String, clientID: String,
                            now: Date = Date()) throws -> OIDCIdentity {
        // omittingEmptySubsequences: false prevents index shifting on degenerate
        // tokens like ".payload.sig" where a leading dot would eat index 0.
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let payload = Data.base64URLDecoded(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sub = obj["sub"] as? String
        else { throw OIDCAuthFailure.sessionExpired(code: "unreadable id_token") }
        return OIDCIdentity(issuer: issuer, clientID: clientID, sub: sub,
                            email: obj["email"] as? String, name: obj["name"] as? String,
                            obtainedAt: now)
    }
    /// A single string claim off the (unvalidated) JWT payload. Used for the
    /// OIDC §3.1.3.7 nonce check on interactive sign-in — comparing the
    /// id_token's `nonce` against the value we sent in the authorization
    /// request. Returns nil when the token is unreadable or the claim is
    /// absent / non-string. NEVER trust this for a security decision beyond
    /// the nonce echo check; the clouds validate the token themselves.
    public static func claim(_ name: String, idToken: String) -> String? {
        // omittingEmptySubsequences: false prevents index shifting on degenerate
        // tokens like ".payload.sig" where a leading dot would eat index 0.
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let payload = Data.base64URLDecoded(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return obj[name] as? String
    }
    /// Expiry + iat straight off the JWT payload (display/cache use only).
    public static func claimDates(idToken: String) -> (iat: Date?, exp: Date?) {
        // omittingEmptySubsequences: false prevents index shifting on degenerate
        // tokens like ".payload.sig" where a leading dot would eat index 0.
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let payload = Data.base64URLDecoded(String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return (nil, nil) }
        let iat = (obj["iat"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let exp = (obj["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return (iat, exp)
    }
}

/// Taxonomy-disciplined stderr logger for all OIDC log lines.
/// Taxonomy logLine strings / fixed count-only strings ONLY — never details,
/// identity, or token content; all OIDC log lines flow through here so audits
/// can grep one symbol.
internal func logStderrOIDC(_ message: String) {
    FileHandle.standardError.write(("[parleq] " + message + "\n").data(using: .utf8) ?? Data())
}

public enum FederationLeg: String, Sendable { case aws, gcp }

/// The spec's failure taxonomy. Three renderings per state:
/// userCopy (overlay/doctor headline), doctorDetail (IT-facing),
/// logLine (count/code-only — NEVER identity, NEVER token contents).
public enum OIDCAuthFailure: Error, Sendable {
    case discoveryFailed(detail: String)
    case signInCancelled
    /// `code` must be a machine-readable error token (e.g. "invalid_grant"),
    /// never a human-readable description; it appears verbatim in logLine.
    case sessionExpired(code: String)
    case rotationLost
    case exchangeDenied(leg: FederationLeg, detail: String)
    case providerDenied(detail: String)
    /// The authorization callback failed state/code validation — either a
    /// CSRF-tampered redirect or a misconfigured redirect URI. Distinct from
    /// sessionExpired (which implies the user was already signed in).
    case callbackInvalid
    /// The IdP itself rejected the authorization request and error-redirected to
    /// our callback (OAuth 2.0 §4.1.2.1: `?error=<code>&error_description=<prose>`).
    /// A diagnosable misconfiguration (e.g. a requested scope the app client
    /// doesn't enable), distinct from callbackInvalid (a missing/forged callback).
    /// `code` is the OAuth machine error token (e.g. "invalid_request",
    /// "invalid_scope") — log-safe, appears verbatim in logLine. `detail` is the
    /// IdP-controlled human-readable `error_description` prose — surfaced to the
    /// doctor/UI ONLY, NEVER logged (it could carry identity-shaped or otherwise
    /// sensitive IdP text).
    case idpRejected(code: String, detail: String)
    /// The interactive sign-in window couldn't be presented (e.g.
    /// ASWebAuthenticationSession.start() returned false — another sign-in
    /// is already active, or there's no presentation anchor). Distinct from
    /// discoveryFailed (which is a network/IdP-reachability problem).
    case signInUnavailable(detail: String)
    /// An interactive auth-code sign-in succeeded at the IdP but the token
    /// response carried NO refresh_token — the client wasn't granted offline
    /// access (the `offline_access` scope is missing/not approved for it).
    /// Parleq keeps no offline persistence without a refresh token, so the
    /// session can't survive a relaunch; reject the sign-in rather than land
    /// a non-renewable session (and so a stale prior-account RT can't later
    /// resurrect the old identity). Silent refresh tolerates a missing RT
    /// (non-rotating IdPs reissue the same token), so this is interactive-only.
    case refreshTokenMissing
    /// An interactive sign-in succeeded but the token response's granted
    /// `scope` (RFC 6749 §5.1) omitted one or more REQUIRED scopes Parleq
    /// requested — the classic case being a user who signed in but didn't tick
    /// Google's granular-consent checkbox for `cloud-platform`, yielding an
    /// access token that 403s at Vertex. We reject the sign-in NOW rather than
    /// persist a token that can't do its job (and whose next silent refresh
    /// would re-request the full scope set, get `invalid_scope`, and tear the
    /// session down with a confusing "Signed out" banner). `missing` is the
    /// configured-but-not-granted scope list — these are config-derived scope
    /// strings (NOT user data), so they're safe to render in logLine. Normalized
    /// OIDC scopes (openid/profile/email/offline_access) are excluded upstream
    /// (IdPs echo those inconsistently), so only enforceable scopes land here.
    case scopeNotGranted(missing: [String])

    public var isSilent: Bool { if case .signInCancelled = self { return true }; return false }
    /// Same case, ignoring associated values. Used by OIDCSession to suppress a
    /// redundant model-side surface of a failure the session already self-surfaced
    /// (see surfaceInteractiveFailure). Compared on logLine (the case-discriminant
    /// rendering minus the per-instance `code` payload, which sessionExpired alone
    /// carries) so two instances of the same case match regardless of detail.
    public func sameKind(as other: OIDCAuthFailure) -> Bool {
        switch (self, other) {
        case (.sessionExpired, .sessionExpired): return true
        default: return self.logLine == other.logLine
        }
    }
    public var userCopy: String {
        switch self {
        case .discoveryFailed: return "Can't reach your organization's sign-in service"
        case .signInCancelled: return ""
        case .sessionExpired, .rotationLost: return "Signed out of your organization"
        case .exchangeDenied(let leg, _):
            return leg == .aws ? "AWS didn't accept your sign-in" : "Google Cloud didn't accept your sign-in"
        case .providerDenied: return "Your account isn't authorized for this model"
        case .callbackInvalid: return "The sign-in response couldn't be verified — try again"
        case .idpRejected: return "Your organization's sign-in service rejected the request — see Company Account for details"
        case .signInUnavailable: return "Couldn't open the sign-in window — try again"
        case .refreshTokenMissing:
            return "Your organization's sign-in didn't grant offline access — ask IT to enable the offline_access scope"
        case .scopeNotGranted(let missing):
            return "Your account didn't grant Parleq all required access (\(missing.joined(separator: ", "))). Sign in again and check every permission box."
        }
    }
    public var doctorDetail: String {
        switch self {
        case .discoveryFailed(let d): return d
        case .signInCancelled: return ""
        case .sessionExpired(let code): return "IdP error: \(code)"
        case .rotationLost: return "token rotation interrupted — sign in again"
        case .exchangeDenied(_, let d): return d
        case .providerDenied(let d): return d
        case .callbackInvalid: return "authorization callback failed state/code validation (possible tampering or a misconfigured redirect URI)"
        // detail is IdP-controlled prose — fine for the doctor/UI, never logged.
        case .idpRejected(let code, let detail): return detail.isEmpty ? code : "\(code): \(detail)"
        case .signInUnavailable(let d): return d
        case .refreshTokenMissing:
            return "token response carried no refresh_token (offline_access scope not granted to this client)"
        case .scopeNotGranted(let missing):
            return "the token response granted scope omitted required scope(s): \(missing.joined(separator: ", ")). With Google, re-run sign-in and tick every granular-consent checkbox (e.g. the cloud-platform box) so the access token carries the scope."
        }
    }
    public var logLine: String {
        switch self {
        case .discoveryFailed: return "oidc state=discoveryFailed"
        case .signInCancelled: return "oidc state=signInCancelled"
        case .sessionExpired(let code): return "oidc state=sessionExpired code=\(code)"
        case .rotationLost: return "oidc state=rotationLost"
        case .exchangeDenied(let leg, _): return "oidc state=exchangeDenied leg=\(leg.rawValue)"
        case .providerDenied: return "oidc state=providerDenied"
        case .callbackInvalid: return "oidc state=callbackInvalid"
        // Only the machine-readable `code` is logged; `detail` (IdP prose) is omitted.
        case .idpRejected(let code, _): return "oidc state=idpRejected code=\(code)"
        case .signInUnavailable: return "oidc state=signInUnavailable"
        case .refreshTokenMissing: return "oidc state=refreshTokenMissing"
        // Scope names are config-derived (the scopes Parleq requested), not user
        // data, so they're safe to render verbatim in the log code line.
        case .scopeNotGranted(let missing): return "oidc state=scopeNotGranted missing=\(missing.joined(separator: ","))"
        }
    }
    /// Positive when the token's iat is in the local future (clock behind).
    public static func clockSkewSeconds(tokenIat: Date, now: Date = Date()) -> Int {
        max(0, Int(tokenIat.timeIntervalSince(now).rounded()))
    }
}
