import Foundation
import SotoCore
import SotoSTS

/// Turns a freshly-minted OIDC ID token into per-cloud credentials. One
/// conforming type per federation leg (AWS AssumeRoleWithWebIdentity, GCP
/// Workforce Identity Federation). The associated `Credentials` is the
/// cloud-shaped result the provider's auth seam consumes.
public protocol CloudCredentialExchanger: Sendable {
    associatedtype Credentials: Sendable
    func exchange(idToken: String) async throws -> (credentials: Credentials, expiresAt: Date)
}

/// Doctor-facing per-hop status (Company Account view reads these).
/// Strings here are IT-facing detail; they are never written to logs.
public struct FederationHopStatus: Sendable {
    public var lastSuccess: Date?
    public var lastError: String?
    public var lastErrorAt: Date?

    public init(lastSuccess: Date? = nil, lastError: String? = nil, lastErrorAt: Date? = nil) {
        self.lastSuccess = lastSuccess
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
    }
}

/// TTL cache around one exchanger. 5-minute refresh-ahead margin;
/// single-flight; `warm()` is the hotkey-down pre-warm (never throws).
public actor CachedExchange<E: CloudCredentialExchanger> {
    private let exchanger: E
    private let session: OIDCSession
    private let leg: FederationLeg
    private let refreshAheadSeconds: TimeInterval = 300
    // The cached entry carries the session generation it was minted under, so a
    // cache hit can confirm it still belongs to the current (not signed-out)
    // session before serving it. See credentials() for the gap this closes.
    private var cached: (credentials: E.Credentials, expiresAt: Date, generation: Int)?
    // The in-flight exchange carries the generation it was minted under, so a
    // late joiner can confirm that result still belongs to the current session
    // before returning it. See credentials() for the gap this closes.
    private var inFlight: (task: Task<E.Credentials, Error>, generation: Int)?
    // Monotonically increasing ID identifying the most recent in-flight exchange;
    // guards the defer-clear in credentials() (see comment there).
    private var inFlightID: Int = 0
    public private(set) var hopStatus = FederationHopStatus()
    /// Count of callers that have joined the in-flight task (i.e. entered the
    /// `try await inflight.task.value` wait). Internal, tests only — count-only,
    /// no credential or identity content.
    var debugWaiterCount: Int = 0
    /// True once at least one caller has joined (waited on) an in-flight task.
    /// Used by tests to spin-wait until the join path is definitely taken before
    /// releasing the in-flight exchange, making the join assertion deterministic.
    var debugWaiterJoined: Bool { debugWaiterCount > 0 }

    public init(exchanger: E, session: OIDCSession, leg: FederationLeg) {
        self.exchanger = exchanger; self.session = session; self.leg = leg
    }
    public func credentials() async throws -> E.Credentials {
        if let c = cached, c.expiresAt.timeIntervalSinceNow > refreshAheadSeconds {
            // A fresh-enough cache entry isn't enough: in the async gap between
            // session.signOut() (which bumps the generation) and the signOut
            // closure's invalidate() call, a concurrent dictation could hit this
            // line and be served pre-logout cloud credentials. Confirm the entry
            // was minted under the CURRENT generation; if signOut() has bumped it,
            // drop the entry and fall through to a fresh exchange (which fails
            // closed with sessionExpired, since the refresh token is gone).
            //
            // Hot-path cost: a cache hit now awaits one actor hop
            // (session.currentGeneration()) — nanoseconds-class, no network. The
            // "zero added latency" guarantee is about network round-trips, which
            // this preserves: a valid cache hit still does no IdP/cloud calls.
            if await session.currentGeneration() == c.generation {
                return c.credentials
            }
            cached = nil
        }
        if let inflight = inFlight {
            // Join the single-flight exchange already running. The fresh-exchange
            // path (exchangeNow) generation-guards its OWN write, but a caller
            // that *joins* an in-flight task minted before a signOut() would
            // otherwise receive that pre-logout result directly — the join never
            // touches `cached`, so the cache-hit guard above can't catch it.
            // Re-check the generation after the await resumes: if signOut() bumped
            // it while we waited, this result belongs to a signed-out session —
            // fail closed instead of handing back pre-logout credentials.
            debugWaiterCount += 1
            let creds = try await inflight.task.value
            guard await session.currentGeneration() == inflight.generation else {
                throw OIDCAuthFailure.sessionExpired(code: "signed out")
            }
            return creds
        }
        let gen = await session.currentGeneration()
        let task = Task<E.Credentials, Error> { try await self.exchangeNow() }
        // Monotonic-ID guard on the clear, mirroring OIDCSession.sharedRefresh():
        // if invalidate() cancels this task and a NEWER exchange starts before our
        // continuation resumes on the actor, an unguarded `inFlight = nil` here
        // would clear the newer task's reference and a third caller would launch
        // a duplicate exchange (extra STS/IdP calls; generation checks already
        // prevent any stale credential from being served).
        inFlightID &+= 1
        let myID = inFlightID
        inFlight = (task: task, generation: gen)
        defer { if inFlightID == myID { inFlight = nil } }
        return try await task.value
    }
    private func exchangeNow() async throws -> E.Credentials {
        // Capture the session generation at the START of the exchange. If a
        // signOut() bumps the generation while we're awaiting the IdP token
        // mint or the cloud exchange, the credentials we're about to produce
        // belong to a session the user has explicitly signed out of — caching
        // them would resurrect cloud-credential ACCESS past the logout. So we
        // re-check the generation before writing `cached` and, if superseded,
        // discard the result and fail closed as a signed-out session.
        let gen = await session.currentGeneration()
        do {
            let idToken = try await session.idToken()
            let result = try await exchanger.exchange(idToken: idToken)
            guard await session.currentGeneration() == gen else {
                throw OIDCAuthFailure.sessionExpired(code: "signed out")
            }
            cached = (credentials: result.credentials, expiresAt: result.expiresAt, generation: gen)
            hopStatus.lastSuccess = Date(); hopStatus.lastError = nil
            return result.credentials
        } catch let f as OIDCAuthFailure {
            hopStatus.lastError = f.doctorDetail; hopStatus.lastErrorAt = Date()
            logStderrOIDC(f.logLine)
            throw f
        } catch {
            hopStatus.lastError = error.localizedDescription; hopStatus.lastErrorAt = Date()
            logStderrOIDC("oidc state=exchangeDenied leg=\(leg.rawValue)")
            throw OIDCAuthFailure.exchangeDenied(leg: leg, detail: error.localizedDescription)
        }
    }
    /// Hotkey-down pre-warm: refresh-if-needed, swallow errors (they
    /// surface fail-closed when cleanup actually runs).
    public func warm() async { _ = try? await credentials() }
    /// Drop the cached credentials AND cancel any in-flight exchange. Called
    /// from the signOut closure (after `session.signOut()` completes) so a
    /// sign-out revokes cloud-credential ACCESS, not just the IdP session: an
    /// exchange already running when the user signs out is cancelled, and its
    /// result — if it still lands — is dropped by the generation re-check in
    /// exchangeNow(), so it can never repopulate this cache.
    public func invalidate() {
        cached = nil
        inFlight?.task.cancel(); inFlight = nil
    }
}

// MARK: - AWS AssumeRoleWithWebIdentity

public struct AWSTemporaryCredentials: Sendable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

/// AssumeRoleWithWebIdentity — an UNAUTHENTICATED STS call (any valid
/// OIDC token from a trusted IdP can call it; the role trust policy is
/// the gate). RoleSessionName carries the user's email for CloudTrail
/// attribution.
public struct AWSWebIdentityExchanger: CloudCredentialExchanger {
    let roleArn: String
    let region: String
    /// Called inside exchange() on every STS call so CloudTrail attribution
    /// reflects the email of whoever is signed in at call time, not at init
    /// time. This matters when the user signs in after the exchanger is
    /// constructed at launch.
    let userEmailProvider: @Sendable () -> String?
    let durationSeconds: Int
    /// Seam: tests replace the live Soto call.
    let callSTS: @Sendable (_ roleArn: String, _ sessionName: String,
                            _ token: String, _ duration: Int, _ region: String)
        async throws -> (AWSTemporaryCredentials, Date)

    public init(roleArn: String, region: String, userEmailProvider: @escaping @Sendable () -> String?,
                durationSeconds: Int,
                callSTS: (@Sendable (String, String, String, Int, String) async throws
                          -> (AWSTemporaryCredentials, Date))? = nil) {
        self.roleArn = roleArn; self.region = region
        self.userEmailProvider = userEmailProvider
        self.durationSeconds = durationSeconds
        self.callSTS = callSTS ?? Self.liveSotoCall
    }
    public func exchange(idToken: String) async throws
        -> (credentials: AWSTemporaryCredentials, expiresAt: Date) {
        // Compute the session name live so CloudTrail attribution picks up
        // the email of whoever signed in most recently (not a snapshot from
        // launch time before any sign-in has occurred).
        let name = Self.sanitizeSessionName(userEmailProvider() ?? "")
        do {
            let (creds, exp) = try await callSTS(roleArn, name, idToken, durationSeconds, region)
            return (creds, exp)
        } catch let f as OIDCAuthFailure { throw f }
        catch {
            throw OIDCAuthFailure.exchangeDenied(leg: .aws, detail: shortSTSError(error))
        }
    }
    /// IAM session-name charset: [\w+=,.@-], max 64; empty → fallback.
    public static func sanitizeSessionName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+=,.@-")
        let cleaned = String(raw.unicodeScalars.filter { allowed.contains($0) }.prefix(64))
        return cleaned.isEmpty ? "parleq-user" : cleaned
    }
    /// Keep the leading clause of a Soto error. Soto error descriptions
    /// describe the STS *response* (error code + message), never the
    /// request body — so the webIdentityToken can't leak through here.
    private func shortSTSError(_ error: Error) -> String {
        let s = String(describing: error)
        return String(s.prefix(200))
    }
    static let liveSotoCall: @Sendable (String, String, String, Int, String)
        async throws -> (AWSTemporaryCredentials, Date) = { roleArn, name, token, duration, region in
        // AssumeRoleWithWebIdentity is unauthenticated: no signing creds.
        // HTTPClient.shared backs the AWSClient, so shutdown() releases
        // only the client wrapper, not a NIO event-loop group. The async
        // shutdown() can't run in a `defer`, so we bracket the call and
        // shut down on both the success and error paths.
        let client = AWSClient(credentialProvider: .empty)
        let sts = STS(client: client, region: .init(rawValue: region))
        let resp: STS.AssumeRoleWithWebIdentityResponse
        do {
            resp = try await sts.assumeRoleWithWebIdentity(.init(
                durationSeconds: duration, roleArn: roleArn,
                roleSessionName: name, webIdentityToken: token))
        } catch {
            try? await client.shutdown()
            throw error
        }
        try? await client.shutdown()
        guard let c = resp.credentials else {
            throw OIDCAuthFailure.exchangeDenied(leg: .aws, detail: "STS returned no credentials")
        }
        return (AWSTemporaryCredentials(accessKeyID: c.accessKeyId,
                                        secretAccessKey: c.secretAccessKey,
                                        sessionToken: c.sessionToken),
                c.expiration)
    }
}

// MARK: - GCP Workforce Identity Federation

public struct GCPFederatedToken: Sendable {
    public let token: String
    public init(token: String) { self.token = token }
}

/// Workforce Identity Federation token exchange. The federated token is
/// used DIRECTLY as the Vertex bearer (workforce principal granted
/// roles/aiplatform.user); calls add x-goog-user-project.
public struct GCPWorkforceExchanger: CloudCredentialExchanger {
    let workforceProvider: String   // "locations/global/workforcePools/POOL/providers/P"
    let userProject: String
    let httpClient: OIDCHTTPClient

    public init(workforceProvider: String, userProject: String,
                httpClient: @escaping OIDCHTTPClient) {
        self.workforceProvider = workforceProvider
        self.userProject = userProject
        self.httpClient = httpClient
    }
    public func exchange(idToken: String) async throws
        -> (credentials: GCPFederatedToken, expiresAt: Date) {
        var req = URLRequest(url: URL(string: "https://sts.googleapis.com/v1/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let audience = "//iam.googleapis.com/\(workforceProvider)"
        // Build the STS options blob via JSONSerialization so a userProject
        // containing quotes/backslashes can't break out of the JSON string.
        let optionsData = try JSONSerialization.data(withJSONObject: ["userProject": userProject])
        let options = String(decoding: optionsData, as: UTF8.self)
        let fields: [(String, String)] = [
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("audience", audience),
            ("scope", "https://www.googleapis.com/auth/cloud-platform"),
            ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
            ("subject_token", idToken),
            ("subject_token_type", "urn:ietf:params:oauth:token-type:id_token"),
            ("options", options),
        ]
        req.httpBody = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(.init(charactersIn: "+&=:/"))) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await httpClient(req)
        guard resp.statusCode == 200 else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = (obj?["error_description"] as? String)
                ?? (obj?["error"] as? String) ?? "HTTP \(resp.statusCode)"
            throw OIDCAuthFailure.exchangeDenied(leg: .gcp, detail: detail)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = obj["access_token"] as? String else {
            throw OIDCAuthFailure.exchangeDenied(leg: .gcp, detail: "malformed STS response")
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        return (GCPFederatedToken(token: token), Date().addingTimeInterval(expiresIn))
    }
}
