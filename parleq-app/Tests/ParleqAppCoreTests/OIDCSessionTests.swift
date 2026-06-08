import XCTest
@testable import ParleqAppCore

/// Recording fake — order of operations is the assertion surface.
final class FakeTokenStore: OIDCTokenStore, @unchecked Sendable {
    var refreshToken: String?
    var identity: OIDCIdentity?
    var log: [String] = []
    func loadRefreshToken() -> String? { log.append("loadRT"); return refreshToken }
    func saveRefreshToken(_ t: String) -> Bool { log.append("saveRT:\(t)"); refreshToken = t; return true }
    func loadIdentity() -> OIDCIdentity? { identity }
    func saveIdentity(_ i: OIDCIdentity) -> Bool { identity = i; return true }
    func clear() { log.append("clear"); refreshToken = nil; identity = nil }
}

@MainActor
final class OIDCSessionTests: XCTestCase {
    // Pure, stateless helpers — marked `nonisolated` so the @Sendable httpClient
    // closures (which run off the MainActor) can call them synchronously.
    nonisolated static let idt = makeJWT(claims: ["sub": "u1", "email": "jon@acme.com",
                                                  "iat": 1_700_000_000.0, "exp": 9_999_999_999.0])
    nonisolated static func makeJWT(claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        return "eyJhbGciOiJSUzI1NiJ9." + payload.base64URLEncoded() + ".sig"
    }
    nonisolated static func discoveryJSON() -> Data {
        Data(#"{"issuer":"https://idp.example","authorization_endpoint":"https://idp.example/auth","token_endpoint":"https://idp.example/token"}"#.utf8)
    }
    nonisolated static func idtIdentity() -> OIDCIdentity {
        try! OIDCIdentity.from(idToken: idt, issuer: "https://idp.example", clientID: "c1")
    }
    nonisolated static func discoveryWithRevocationJSON() -> Data {
        Data(#"{"issuer":"https://idp.example","authorization_endpoint":"https://idp.example/auth","token_endpoint":"https://idp.example/token","revocation_endpoint":"https://idp.example/revoke"}"#.utf8)
    }
    nonisolated static func tokenJSON(rt: String?) -> Data {
        var obj: [String: Any] = ["access_token": "at", "id_token": idt, "expires_in": 3600.0]
        if let rt { obj["refresh_token"] = rt }
        return try! JSONSerialization.data(withJSONObject: obj)
    }
    nonisolated static func http(_ script: @escaping @Sendable (URLRequest) -> (Data, Int)) -> OIDCHTTPClient {
        { req in
            let (data, code) = script(req)
            return (data, HTTPURLResponse(url: req.url!, statusCode: code,
                                          httpVersion: nil, headerFields: nil)!)
        }
    }
    nonisolated static func config() -> OIDCClientConfig {
        OIDCClientConfig(issuer: "https://idp.example", clientID: "c1",
                         scopes: ["openid", "profile", "email", "offline_access"],
                         ephemeralBrowser: false)
    }

    func test_refresh_persists_rotated_token_before_returning() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        let session = OIDCSession(config: Self.config(), httpClient: Self.http { req in
            req.url!.path.contains("token") ? (Self.tokenJSON(rt: "rt2"), 200) : (Self.discoveryJSON(), 200)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        _ = try await session.idToken()
        XCTAssertTrue(store.log.contains("saveRT:rt2"), "rotated RT must be persisted")
        XCTAssertEqual(store.refreshToken, "rt2")
    }
    func test_refresh_with_failed_rotation_persistence_fails_loudly_without_signing_in() async throws {
        // The store reports saveRefreshToken failure for the rotated RT. apply()
        // must throw .rotationLost BEFORE caching the ID token or flipping to
        // .signedIn — a rotation whose new RT couldn't be persisted is a lost
        // session, so fail now rather than at the next (dead-token) refresh.
        let store = FailingSaveTokenStore(); store.refreshToken = "rt1"
        let session = OIDCSession(config: Self.config(), httpClient: Self.http { req in
            req.url!.path.contains("token") ? (Self.tokenJSON(rt: "rt2"), 200) : (Self.discoveryJSON(), 200)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        do {
            _ = try await session.idToken()
            XCTFail("expected rotationLost")
        } catch OIDCAuthFailure.rotationLost {
            // expected
        }
        // State must NOT be .signedIn and the ID token must NOT be cached.
        let signedIn: Bool
        if case .signedIn = await session.state { signedIn = true } else { signedIn = false }
        XCTAssertFalse(signedIn, "a failed rotation persistence must not leave the session signed in")
        let cached = await session.debugHasCachedToken
        XCTAssertFalse(cached, "a failed rotation persistence must not cache the ID token")
    }
    /// Fix (job 5140 #1): when rotation persistence fails, apply()/validate()
    /// must tear down ALL local state before throwing rotationLost — clear the
    /// token store and drop any cached ID token. Otherwise the OLD (now
    /// IdP-invalidated) refresh token + identity stay persisted and a RESTART
    /// rehydrates .signedIn with a dead token, deferring the failure to a
    /// confusing place. We assert the teardown happened AND that a fresh session
    /// constructed over the same (now-cleared) store inits to .signedOut.
    func test_failed_rotation_tears_down_local_state_so_restart_is_signedOut() async throws {
        let store = FailingSaveTokenStore()
        store.refreshToken = "rt1"
        store.identity = Self.idtIdentity()   // pre-existing persisted identity
        let session = OIDCSession(config: Self.config(), httpClient: Self.http { req in
            req.url!.path.contains("token") ? (Self.tokenJSON(rt: "rt2"), 200) : (Self.discoveryJSON(), 200)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        do {
            _ = try await session.idToken()
            XCTFail("expected rotationLost")
        } catch OIDCAuthFailure.rotationLost {
            // expected
        }
        // Local teardown: store cleared, identity gone, no cached token.
        XCTAssertTrue(store.log.contains("clear"), "store must be cleared before throwing: \(store.log)")
        XCTAssertNil(store.loadIdentity(), "identity must be cleared on rotation loss")
        XCTAssertNil(store.refreshToken, "old refresh token must be cleared on rotation loss")
        let cached = await session.debugHasCachedToken
        XCTAssertFalse(cached, "cached ID token must be dropped on rotation loss")
        // Restart-style assertion: a NEW session over the torn-down store inits
        // to .signedOut — no dead-token .signedIn rehydration.
        let restarted = OIDCSession(config: Self.config(),
                                    httpClient: Self.http { _ in (Self.discoveryJSON(), 200) },
                                    tokenStore: store,
                                    authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        let restartedState = await restarted.state
        guard case .signedOut = restartedState else {
            return XCTFail("restart must be signedOut, got \(restartedState)")
        }
    }
    func test_single_flight_many_awaiters_one_token_call() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        let counter = TokenCallCounter()
        // Deterministic barrier instead of a wall-clock sleep: the token call
        // parks on `gate` until the test opens it AFTER all 8 awaiters are
        // launched. With the first call held open, none of the others can
        // observe a *finished* task, so the single-flight invariant must route
        // all 8 through one refresh — no reliance on 50ms winning a CI race.
        let gate = Gate()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("token") { await counter.increment(); await gate.wait() }
            let data = req.url!.path.contains("token") ? Self.tokenJSON(rt: nil) : Self.discoveryJSON()
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await session.idToken() } }
            await gate.open()  // release the held token call once all awaiters exist
            for try await _ in group {}
        }
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "8 concurrent awaiters must share one refresh")
    }

    /// REAL race fixed in this pass: a refresh whose token call is in flight
    /// when signOut() lands must NOT resurrect `.signedIn` / re-cache a token
    /// after the store was cleared. Generation guard in applyIfCurrent.
    func test_signOut_during_inflight_refresh_does_not_resurrect_signedIn() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        store.identity = Self.idtIdentity()
        let gate = Gate()
        let started = Gate()   // opened once the token call is actually parked
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            // Park the *refresh* token call until the test has run signOut().
            if req.url!.path.contains("token") {
                await started.open()   // signal the test that we've reached the park point
                await gate.wait()
            }
            let data = req.url!.path.contains("token") ? Self.tokenJSON(rt: "rt2") : Self.discoveryJSON()
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })

        let refreshTask = Task { try await session.idToken() }
        // Deterministically wait until the refresh has entered the actor and
        // parked on the token call — no Task.yield reliance.
        await started.wait()
        await session.signOut()   // bumps generation, clears store, cancels inflight
        await gate.open()         // let the (now-superseded) token call complete
        _ = try? await refreshTask.value

        let state = await session.state
        guard case .signedOut = state else { return XCTFail("resurrected: \(state)") }
        let cached = await session.debugHasCachedToken
        XCTAssertFalse(cached, "cached token must stay cleared after sign-out")
        XCTAssertNil(store.refreshToken, "store must not be re-populated by the superseded refresh")
    }

    /// 1a: RFC 7009 revocation body must percent-encode token + client_id.
    func test_signOut_revocation_body_is_percent_encoded() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt/with+specials=="
        let captured = CapturedBody()
        // Revocation is now fire-and-forget (detached Task), so the test must
        // wait for the revoke call to actually land instead of assuming signOut()
        // awaited it. The httpClient opens `revoked` once it has captured the body.
        let revoked = Gate()
        let session = OIDCSession(config: OIDCClientConfig(
            issuer: "https://idp.example", clientID: "c/1+x",
            scopes: ["openid"], ephemeralBrowser: false), httpClient: { req in
                if req.url!.path.contains("revoke") {
                    await captured.set(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")
                    await revoked.open()
                    return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                return (Self.discoveryWithRevocationJSON(),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        await session.signOut()
        await revoked.wait()   // fire-and-forget revocation has run
        let body = await captured.value
        XCTAssertFalse(body.contains("/"), "raw '/' leaked into revocation body: \(body)")
        XCTAssertFalse(body.contains("+"), "raw '+' leaked into revocation body: \(body)")
        // '=' only legal as the key/value separator, never inside an encoded value.
        XCTAssertEqual(body.filter { $0 == "=" }.count, 2, "unencoded '=' in values: \(body)")
        XCTAssertTrue(body.hasPrefix("token=") && body.contains("&client_id="), body)
    }

    /// Ordering fix (job 5132): signOut() must clear local state BEFORE the
    /// revocation HTTP call is made. A stalled revocation must not leave the
    /// user signed-in locally with reusable cloud creds. We record both the
    /// token-store "clear" and the revocation request into one ordered log
    /// (the store appends "clear"; the httpClient appends "revoke") and assert
    /// "clear" precedes "revoke".
    func test_signOut_clears_local_state_before_revocation() async throws {
        let log = OrderedLog()
        let store = SharedLogTokenStore(log: log); store.refreshToken = "rt1"
        let revoked = Gate()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("revoke") {
                log.append("revoke")
                await revoked.open()
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.discoveryWithRevocationJSON(),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        await session.signOut()
        await revoked.wait()   // fire-and-forget revocation has run
        let entries = log.entries
        let clearIdx = entries.firstIndex(of: "clear")
        let revokeIdx = entries.firstIndex(of: "revoke")
        XCTAssertNotNil(clearIdx, "store must be cleared: \(entries)")
        XCTAssertNotNil(revokeIdx, "revocation must be attempted: \(entries)")
        if let c = clearIdx, let r = revokeIdx {
            XCTAssertLessThan(c, r, "clear must precede revocation: \(entries)")
        }
    }

    /// signOut() must RETURN without awaiting the revocation round-trip — the
    /// revocation is fire-and-forget. We gate the revocation response closed and
    /// assert signOut() completes (and local state is cleared) while the gate is
    /// still shut, i.e. before the revocation HTTP call can resolve.
    func test_signOut_returns_without_awaiting_slow_revocation() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        let revokeGate = Gate()        // held shut: revocation cannot complete
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("revoke") {
                await revokeGate.wait()   // park the revocation indefinitely
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.discoveryWithRevocationJSON(),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })

        await session.signOut()   // must return even though revocation is parked
        // Local state is cleared synchronously, independent of the parked revoke.
        let state = await session.state
        guard case .signedOut = state else { return XCTFail("not signedOut: \(state)") }
        XCTAssertNil(store.refreshToken, "store must be cleared regardless of revocation")
        let cached = await session.debugHasCachedToken
        XCTAssertFalse(cached, "cached token must be cleared regardless of revocation")
        await revokeGate.open()   // release the parked revocation so the task can exit
    }

    func test_invalid_grant_maps_to_sessionExpired_and_needsInteractive() async {
        let store = FakeTokenStore(); store.refreshToken = "rt-dead"
        let session = OIDCSession(config: Self.config(), httpClient: Self.http { req in
            req.url!.path.contains("token")
                ? (Data(#"{"error":"invalid_grant"}"#.utf8), 400) : (Self.discoveryJSON(), 200)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        do { _ = try await session.idToken(); XCTFail("expected throw") }
        catch let f as OIDCAuthFailure {
            guard case .sessionExpired(let code) = f else { return XCTFail("\(f)") }
            // Accept path of the tokenCall sanitizer: a conforming RFC 6749
            // error code passes through verbatim into code AND logLine.
            XCTAssertEqual(code, "invalid_grant")
            XCTAssertEqual(f.logLine, "oidc state=sessionExpired code=invalid_grant")
        } catch { XCTFail("\(error)") }
        let state = await session.state
        guard case .needsInteractive = state else { return XCTFail("\(state)") }
    }
    /// A nonconforming token endpoint can put prose / log-breaking text in the
    /// JSON `error` field on a non-200 refresh. That value lands in
    /// sessionExpired.code (logged verbatim), so it must be sanitized: a value
    /// outside the RFC 6749 error-code charset is replaced with the status-only
    /// fallback ("HTTP <status>") — sessionExpired has no doctor-only detail
    /// slot, so the raw value is dropped.
    func test_refresh_nonstandard_error_value_is_sanitized_for_code() async {
        let store = FakeTokenStore(); store.refreshToken = "rt-dead"
        let session = OIDCSession(config: Self.config(), httpClient: Self.http { req in
            req.url!.path.contains("token")
                ? (Data(#"{"error":"some prose with spaces\nand newlines"}"#.utf8), 400)
                : (Self.discoveryJSON(), 200)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        do { _ = try await session.idToken(); XCTFail("expected throw") }
        catch let f as OIDCAuthFailure {
            guard case .sessionExpired(let code) = f else { return XCTFail("\(f)") }
            XCTAssertEqual(code, "HTTP 400", "nonconforming error must fall back to status-only code")
            // The logged rendering must carry ONLY the sanitized fallback.
            XCTAssertEqual(f.logLine, "oidc state=sessionExpired code=HTTP 400")
            XCTAssertFalse(f.logLine.contains("prose"), "raw IdP text must never reach logLine")
            XCTAssertFalse(f.logLine.contains("\n"), "newlines must never reach logLine")
        } catch { XCTFail("\(error)") }
    }
    func test_no_refresh_token_is_signedOut_and_throws() async {
        let session = OIDCSession(config: Self.config(),
                                  httpClient: Self.http { _ in (Self.discoveryJSON(), 200) },
                                  tokenStore: FakeTokenStore(),
                                  authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        do { _ = try await session.idToken(); XCTFail("expected throw") } catch {}
        let state = await session.state
        guard case .signedOut = state else { return XCTFail("\(state)") }
    }
    /// Builds a token-response JSON whose id_token carries the given `nonce`
    /// claim, so the signIn nonce check (OIDC §3.1.3.7) can be exercised. By
    /// default it ALSO grants a refresh_token — interactive sign-in now requires
    /// one (job 5142 #2); pass `rt: nil` to model the missing-RT rejection path.
    nonisolated static func tokenJSONWithNonce(_ nonce: String?, rt: String? = "rt-granted") -> Data {
        var claims: [String: Any] = ["sub": "u1", "email": "jon@acme.com",
                                     "iat": 1_700_000_000.0, "exp": 9_999_999_999.0]
        if let nonce { claims["nonce"] = nonce }
        let idt = makeJWT(claims: claims)
        var obj: [String: Any] = ["access_token": "at", "id_token": idt, "expires_in": 3600.0]
        if let rt { obj["refresh_token"] = rt }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    /// Happy path: the interactive token response's id_token echoes the exact
    /// nonce from the authorization request → sign-in succeeds.
    func test_signIn_verifies_matching_nonce() async throws {
        let store = FakeTokenStore()
        // The captured nonce flows from the authenticator (which reads it off the
        // authorization URL) into the httpClient (which mints an id_token carrying
        // it). A box bridges the two @Sendable closures.
        let nonceBox = NonceBox()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            let data: Data
            if req.url!.path.contains("token") {
                data = Self.tokenJSONWithNonce(await nonceBox.value)
            } else {
                data = Self.discoveryJSON()
            }
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { buildAuthorizationURL, _ in
            let url = buildAuthorizationURL(nil)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            let nonce = items.first { $0.name == "nonce" }?.value ?? ""
            await nonceBox.set(nonce)
            return URL(string: "parleq-auth://oidc/callback?state=\(state)&code=c1")!
        })
        let id = try await session.signIn()
        XCTAssertEqual(id.sub, "u1")
        let state = await session.state
        guard case .signedIn = state else { return XCTFail("\(state)") }
    }

    /// The interactive token response's id_token carries a WRONG nonce → the
    /// §3.1.3.7 check rejects it as callbackInvalid, and the session does not
    /// flip to signedIn.
    func test_signIn_rejects_wrong_nonce() async {
        let store = FakeTokenStore()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            let data = req.url!.path.contains("token")
                ? Self.tokenJSONWithNonce("not-the-nonce-we-sent")
                : Self.discoveryJSON()
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { buildAuthorizationURL, _ in
            let url = buildAuthorizationURL(nil)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            return URL(string: "parleq-auth://oidc/callback?state=\(state)&code=c1")!
        })
        do { _ = try await session.signIn(); XCTFail("expected throw") }
        catch let f as OIDCAuthFailure {
            guard case .callbackInvalid = f else { return XCTFail("\(f)") }
        } catch { XCTFail("\(error)") }
        let state = await session.state
        guard case .signedOut = state else { return XCTFail("\(state)") }
    }

    /// IdP error-redirect: the callback carries a MATCHING state plus OAuth
    /// error params (no `code`). signIn must surface the diagnosable idpRejected
    /// (with the machine code + detail prose) rather than the misleading
    /// callbackInvalid copy. Models the live-tested Cognito invalid_scope case.
    func test_signIn_idp_error_redirect_with_matching_state_throws_idpRejected() async {
        let store = FakeTokenStore()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            // Only discovery is ever fetched — the flow throws at the callback
            // before any token call.
            (Self.discoveryJSON(),
             HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { buildAuthorizationURL, _ in
            let url = buildAuthorizationURL(nil)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            return URL(string: "parleq-auth://oidc/callback?state=\(state)&error=invalid_request&error_description=invalid_scope")!
        })
        do { _ = try await session.signIn(); XCTFail("expected idpRejected") }
        catch let f as OIDCAuthFailure {
            guard case .idpRejected(let code, let detail) = f else { return XCTFail("\(f)") }
            XCTAssertEqual(code, "invalid_request")
            XCTAssertTrue(detail.contains("invalid_scope"), "detail: \(detail)")
        } catch { XCTFail("\(error)") }
    }

    /// Forgery precedence: a callback whose state MISMATCHES, even when it also
    /// carries OAuth error params, stays callbackInvalid — a forged redirect must
    /// not be able to surface IdP-looking diagnostics.
    func test_signIn_mismatched_state_with_error_params_stays_callbackInvalid() async {
        let store = FakeTokenStore()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            (Self.discoveryJSON(),
             HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in
            // Deliberately ignore the real state and return a forged one alongside
            // error params.
            URL(string: "parleq-auth://oidc/callback?state=forged&error=invalid_request&error_description=invalid_scope")!
        })
        do { _ = try await session.signIn(); XCTFail("expected callbackInvalid") }
        catch let f as OIDCAuthFailure {
            guard case .callbackInvalid = f else { return XCTFail("\(f)") }
        } catch { XCTFail("\(error)") }
    }

    /// Builds a token-response JSON whose id_token carries the given `nonce` but
    /// NO `sub` claim — so the nonce check passes but OIDCIdentity.from throws
    /// (unreadable id_token), exercising signIn's identity-parse failure path.
    nonisolated static func tokenJSONNonceButNoSub(_ nonce: String?) -> Data {
        var claims: [String: Any] = ["email": "jon@acme.com",
                                     "iat": 1_700_000_000.0, "exp": 9_999_999_999.0]
        if let nonce { claims["nonce"] = nonce }
        let idt = makeJWT(claims: claims)
        // Grant a refresh_token so validate() gets PAST the requireRefreshToken
        // check and reaches the identity-parse failure this fixture exercises.
        let obj: [String: Any] = ["access_token": "at", "id_token": idt,
                                  "expires_in": 3600.0, "refresh_token": "rt-granted"]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    /// Fix (job 5140 #2): an interactive sign-in that fails AFTER the nonce check
    /// but at identity-parse (valid nonce, id_token missing `sub`) must surface
    /// needsInteractive (banner path) WITHOUT bumping the epoch. Pre-restructure,
    /// the epoch bump happened before apply(), so a post-bump parse throw left a
    /// bumped epoch (invalidating prior cloud creds) AND no banner (the model's
    /// pre-captured generation no longer matched). We assert both halves: (a) the
    /// model's surfaceInteractiveFailure (generation-guarded on the PRE-captured
    /// value) still paints the banner, and (b) cloud credentials minted before
    /// the failed sign-in remain valid — credentials() does NOT re-exchange,
    /// proving the generation was never bumped.
    func test_signIn_parse_failure_surfaces_banner_and_does_not_bump_epoch() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        store.identity = Self.idtIdentity()
        let nonceBox = NonceBox()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            let data: Data
            if req.url!.path.contains("token") {
                // The auth-code exchange returns a valid nonce but a sub-less
                // id_token; the silent refresh (driven below to mint creds) also
                // hits this path, but the cred mint happens BEFORE the bad sign-in
                // and uses session.idToken()'s own refresh — which also lands here.
                // To keep the pre-sign-in refresh healthy we serve the good idt
                // until a nonce has been captured (i.e. the interactive flow ran).
                if let n = await nonceBox.value {
                    data = Self.tokenJSONNonceButNoSub(n)
                } else {
                    data = Self.tokenJSON(rt: nil)   // healthy silent refresh
                }
            } else {
                data = Self.discoveryJSON()
            }
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { buildAuthorizationURL, _ in
            let url = buildAuthorizationURL(nil)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            let nonce = items.first { $0.name == "nonce" }?.value ?? ""
            await nonceBox.set(nonce)
            return URL(string: "parleq-auth://oidc/callback?state=\(state)&code=c1")!
        })

        // Mint a cloud credential under the CURRENT epoch (pre-sign-in). The
        // exchanger counts its calls so we can prove a later read is a cache hit.
        let counter = TokenCallCounter()
        let exchanger = FakeExchanger { _ in
            await counter.increment()
            return ("creds", Date().addingTimeInterval(3600))   // well outside the 5-min margin
        }
        let cache = CachedExchange(exchanger: exchanger, session: session, leg: .aws)
        let c1 = try await cache.credentials()
        XCTAssertEqual(c1, "creds")
        let mintCount = await counter.value
        XCTAssertEqual(mintCount, 1, "first credentials() mints once")

        // Drive the failing sign-in exactly as OIDCSessionModel.signIn does:
        // capture the generation BEFORE the flow, then surface the failure with
        // that pre-captured generation on throw.
        let gen = await session.currentGeneration()
        do {
            _ = try await session.signIn()
            XCTFail("expected identity-parse failure")
        } catch let f as OIDCAuthFailure {
            guard case .sessionExpired = f else { return XCTFail("expected sessionExpired, got \(f)") }
            await session.surfaceInteractiveFailure(f, gen: gen)
        }

        // (a) Banner path: the pre-captured generation still matches (no bump),
        // so surfaceInteractiveFailure painted needsInteractive.
        let state = await session.state
        guard case .needsInteractive = state else { return XCTFail("expected needsInteractive, got \(state)") }

        // (b) Epoch unchanged: the pre-sign-in cached credential is still valid,
        // so credentials() serves the cache hit instead of re-exchanging.
        let c2 = try await cache.credentials()
        XCTAssertEqual(c2, "creds")
        let mintCountAfter = await counter.value
        XCTAssertEqual(mintCountAfter, 1,
                       "failed sign-in must NOT bump the epoch — cached creds stay valid, no re-exchange")
        let genAfter = await session.currentGeneration()
        XCTAssertEqual(genAfter, gen, "generation must be unchanged after a failed sign-in")
    }

    /// Fix (job 5142 #1): the rotationLost teardown must END the credential
    /// epoch — bump the generation — not just clear the store/cache. Before the
    /// fix the teardown cleared local state but left the generation untouched, so
    /// a CachedExchange entry minted PRE-teardown still passed the generation
    /// check and kept serving cloud creds after the session had self-destructed.
    /// Here: mint a cloud cred under the live session, then drive a refresh whose
    /// rotated-RT save fails (→ rotationLost teardown), then assert a subsequent
    /// credentials() does NOT serve the old cache hit — it re-exchanges, which
    /// fails closed (the store was cleared, so idToken() finds no refresh token).
    /// Also assert the session self-surfaced .needsInteractive(.rotationLost).
    func test_rotationLost_teardown_bumps_epoch_so_cached_creds_are_not_served() async throws {
        let store = FailingSaveTokenStore(); store.refreshToken = "rt1"
        // The FIRST refresh (driven by the cred mint) returns a SOON-expiring
        // id_token with NO rotation, so it succeeds AND its cached id_token falls
        // outside the 60 s validity window — the next idToken() re-refreshes
        // rather than serving the cache. The SECOND refresh returns a rotated RT
        // whose save fails → rotationLost teardown.
        nonisolated(unsafe) let soonExpId = Self.makeJWT(claims: [
            "sub": "u1", "email": "jon@acme.com",
            "iat": Date().timeIntervalSince1970,
            "exp": Date().addingTimeInterval(30).timeIntervalSince1970,   // <60 s → not cacheable
        ])
        let callCount = TokenCallCounter()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            let data: Data
            if req.url!.path.contains("token") {
                await callCount.increment()
                let n = await callCount.value
                let obj: [String: Any]
                if n == 1 {
                    obj = ["access_token": "at", "id_token": soonExpId, "expires_in": 30.0]   // no rotation
                } else {
                    obj = ["access_token": "at", "id_token": soonExpId, "expires_in": 30.0,
                           "refresh_token": "rt2"]   // rotated RT → save fails → rotationLost
                }
                data = try! JSONSerialization.data(withJSONObject: obj)
            } else {
                data = Self.discoveryJSON()
            }
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })

        // Mint a cloud credential under the live epoch. CachedExchange.exchangeNow
        // pulls the id_token from the session itself (1st token call → healthy
        // refresh) and hands it to the exchanger, so a LATER re-exchange will fail
        // closed once the store is cleared (no need to re-fetch inside the closure).
        let mintCount = TokenCallCounter()
        let exchanger = FakeExchanger { _ in
            await mintCount.increment()
            return ("creds", Date().addingTimeInterval(3600))   // outside the 5-min margin
        }
        let cache = CachedExchange(exchanger: exchanger, session: session, leg: .aws)
        let c1 = try await cache.credentials()
        XCTAssertEqual(c1, "creds")
        let minted = await mintCount.value
        XCTAssertEqual(minted, 1)

        // Drive the failing-rotation refresh directly. The 1st refresh's id_token
        // expires in 30 s (uncacheable), so this idToken() re-refreshes → 2nd
        // token call → rotated RT whose save fails → rotationLost teardown.
        do {
            _ = try await session.idToken()
            XCTFail("expected rotationLost")
        } catch OIDCAuthFailure.rotationLost {
            // expected
        }

        // The session self-surfaced needsInteractive(rotationLost) (NOT signedOut,
        // NOT signedIn) — the teardown is a forced re-auth, so the banner renders.
        let state = await session.state
        guard case .needsInteractive(let f) = state, case .rotationLost = f else {
            return XCTFail("expected needsInteractive(rotationLost), got \(state)")
        }

        // THE FIX: a subsequent credentials() must NOT serve the pre-teardown
        // cache hit. The teardown bumped the generation, so CachedExchange drops
        // the stale entry and re-exchanges — which fails closed (store cleared →
        // idToken() has no refresh token → sessionExpired). A pre-fix session
        // would return "creds" here (cache hit served past epoch end).
        do {
            _ = try await cache.credentials()
            XCTFail("expected fail-closed re-exchange, not a stale cache hit")
        } catch let e as OIDCAuthFailure {
            guard case .sessionExpired = e else { return XCTFail("expected sessionExpired, got \(e)") }
        }
    }

    /// Fix (job 5142 #2): an interactive auth-code sign-in whose token response
    /// carries NO refresh_token must be REJECTED as .refreshTokenMissing (Parleq
    /// keeps no offline persistence without one, and a stale prior-account RT
    /// could otherwise resurrect the old identity). The rejection shares the
    /// rotationLost teardown: it clears the store (account-switch hygiene), bumps
    /// the epoch, and self-surfaces .needsInteractive(.refreshTokenMissing).
    /// Silent refresh keeps tolerating a missing RT (covered by other tests).
    func test_interactive_signIn_without_refresh_token_throws_refreshTokenMissing() async throws {
        let store = FakeTokenStore()
        store.refreshToken = "stale-prior-account-rt"   // prior account's RT, must be cleared
        let nonceBox = NonceBox()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            let data: Data
            if req.url!.path.contains("token") {
                // Auth-code response echoes the nonce (passes §3.1.3.7) but carries
                // NO refresh_token (rt: nil).
                data = Self.tokenJSONWithNonce(await nonceBox.value, rt: nil)
            } else {
                data = Self.discoveryJSON()
            }
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { buildAuthorizationURL, _ in
            let url = buildAuthorizationURL(nil)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            let nonce = items.first { $0.name == "nonce" }?.value ?? ""
            await nonceBox.set(nonce)
            return URL(string: "parleq-auth://oidc/callback?state=\(state)&code=c1")!
        })
        let genBefore = await session.currentGeneration()
        do {
            _ = try await session.signIn()
            XCTFail("expected refreshTokenMissing")
        } catch OIDCAuthFailure.refreshTokenMissing {
            // expected
        }
        // Store cleared (the stale prior-account RT is gone — no resurrection).
        XCTAssertNil(store.refreshToken, "prior account's RT must be cleared")
        XCTAssertTrue(store.log.contains("clear"), "teardown must clear the store: \(store.log)")
        // No cached id_token left behind.
        let cached = await session.debugHasCachedToken
        XCTAssertFalse(cached)
        // Self-surfaced needsInteractive(refreshTokenMissing).
        let state = await session.state
        guard case .needsInteractive(let f) = state, case .refreshTokenMissing = f else {
            return XCTFail("expected needsInteractive(refreshTokenMissing), got \(state)")
        }
        // Epoch DID bump (mirrors the rotationLost teardown — prior creds are dead).
        let genAfter = await session.currentGeneration()
        XCTAssertEqual(genAfter, genBefore + 1, "teardown must end the epoch")
    }

    /// The model drives signIn() and, on any OIDCAuthFailure, calls
    /// surfaceInteractiveFailure with its PRE-flow generation. For a self-surfaced
    /// teardown kind (refreshTokenMissing) the session already painted the banner
    /// and bumped the epoch, so the model's call must be a harmless no-op — not a
    /// double-paint or a stale-gen clobber. Assert the state stays
    /// needsInteractive(refreshTokenMissing) after the model's redundant surface.
    func test_model_surface_of_self_surfaced_failure_is_noop() async throws {
        let store = FakeTokenStore(); store.refreshToken = "stale"
        let nonceBox = NonceBox()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            let data = req.url!.path.contains("token")
                ? Self.tokenJSONWithNonce(await nonceBox.value, rt: nil)
                : Self.discoveryJSON()
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { buildAuthorizationURL, _ in
            let url = buildAuthorizationURL(nil)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            let nonce = items.first { $0.name == "nonce" }?.value ?? ""
            await nonceBox.set(nonce)
            return URL(string: "parleq-auth://oidc/callback?state=\(state)&code=c1")!
        })
        let gen = await session.currentGeneration()   // pre-flow capture, as the model does
        do { _ = try await session.signIn(); XCTFail("expected refreshTokenMissing") }
        catch let f as OIDCAuthFailure {
            // Model's catch surfaces with the now-stale pre-flow generation.
            await session.surfaceInteractiveFailure(f, gen: gen)
        }
        let state = await session.state
        guard case .needsInteractive(let f) = state, case .refreshTokenMissing = f else {
            return XCTFail("expected needsInteractive(refreshTokenMissing), got \(state)")
        }
    }

    // MARK: - optional client secret (Google "Desktop app" clients)

    /// The REFRESH grant must carry `client_secret` when the token store
    /// provides one. The value is form-encoded (`.alphanumerics`) like every
    /// other field; we assert the encoded form is present, not the raw value.
    func test_refresh_grant_includes_client_secret_when_store_provides_one() async throws {
        let store = SecretTokenStore()
        store.refreshToken = "rt1"
        store.clientSecret = "GOCSPX-secret123"
        let bodyBox = CapturedBody()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("token") {
                await bodyBox.set(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")
                return (Self.tokenJSON(rt: nil), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.discoveryJSON(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        _ = try await session.idToken()
        let body = await bodyBox.value
        // "GOCSPX" is all-alphanumeric so it survives encoding verbatim; the
        // '-' in the value is percent-encoded, so assert on the surviving run.
        XCTAssertTrue(body.contains("client_secret=GOCSPX"),
                      "refresh grant must include client_secret: \(body)")
    }

    /// The AUTHORIZATION-CODE exchange must carry `client_secret` too — Google
    /// Desktop clients reject the exchange without it even with PKCE.
    func test_authorization_code_exchange_includes_client_secret() async throws {
        let store = SecretTokenStore()
        store.clientSecret = "GOCSPX-secret123"
        let nonceBox = NonceBox()
        let bodyBox = CapturedBody()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("token") {
                await bodyBox.set(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")
                return (Self.tokenJSONWithNonce(await nonceBox.value),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.discoveryJSON(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { buildAuthorizationURL, _ in
            let url = buildAuthorizationURL(nil)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            let nonce = items.first { $0.name == "nonce" }?.value ?? ""
            await nonceBox.set(nonce)
            return URL(string: "parleq-auth://oidc/callback?state=\(state)&code=c1")!
        })
        _ = try await session.signIn()
        let body = await bodyBox.value
        XCTAssertTrue(body.contains("client_secret=GOCSPX"),
                      "auth-code exchange must include client_secret: \(body)")
        XCTAssertTrue(body.contains("grant_type=authorization"),
                      "this body must be the auth-code exchange: \(body)")
    }

    /// When the store provides NO client secret (the common case — every
    /// non-Desktop client), the token body must OMIT the key entirely, so the
    /// request is byte-identical to the pre-feature behavior.
    func test_token_body_omits_client_secret_when_store_returns_nil() async throws {
        let store = SecretTokenStore()
        store.refreshToken = "rt1"
        store.clientSecret = nil   // explicit: no secret
        let bodyBox = CapturedBody()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("token") {
                await bodyBox.set(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")
                return (Self.tokenJSON(rt: nil), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.discoveryJSON(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        _ = try await session.idToken()
        let body = await bodyBox.value
        XCTAssertFalse(body.contains("client_secret"),
                      "no client_secret key may appear when the store returns nil: \(body)")
    }

    /// A FakeTokenStore (which does NOT override oidcClientSecret()) uses the
    /// protocol default of nil — proving existing conformers compile AND that
    /// the default path omits the key.
    func test_default_token_store_omits_client_secret() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        let bodyBox = CapturedBody()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("token") {
                await bodyBox.set(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")
                return (Self.tokenJSON(rt: nil), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.discoveryJSON(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        _ = try await session.idToken()
        let body = await bodyBox.value
        XCTAssertFalse(body.contains("client_secret"),
                       "default-protocol store must omit client_secret: \(body)")
    }

    /// Arbitrary characters in the secret must round-trip through the form
    /// encoder safely (no raw reserved bytes leak into the body). Uses a value
    /// full of reserved chars; assert none of them appear unencoded and the
    /// '=' count is exactly the key/value-separator count.
    func test_client_secret_with_reserved_chars_is_form_encoded() async throws {
        let store = SecretTokenStore()
        store.refreshToken = "rt1"
        store.clientSecret = "a+b/c=d&e"
        let bodyBox = CapturedBody()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("token") {
                await bodyBox.set(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")
                return (Self.tokenJSON(rt: nil), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.discoveryJSON(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        _ = try await session.idToken()
        let body = await bodyBox.value
        // The secret's reserved chars ('+','/','&') must be percent-encoded.
        // '&' is the field separator; the encoded secret must not introduce a
        // spurious one. The body has exactly four fields here
        // (grant_type=refresh_token, refresh_token=rt1, client_id=c1,
        // client_secret=...), so count '&' = (fields - 1).
        let fieldCount = body.split(separator: "&").count
        // Each field has exactly one '=' separator (values are fully encoded).
        XCTAssertEqual(body.filter { $0 == "=" }.count, fieldCount,
                       "every '=' must be a key/value separator, none from the secret: \(body)")
        XCTAssertFalse(body.contains("a+b"), "raw '+' leaked from the secret: \(body)")
        XCTAssertFalse(body.contains("c=d"), "raw '=' leaked from the secret: \(body)")
    }

    /// The OIDCTokenStore seam round-trips the client secret: a store that
    /// returns a value surfaces it via oidcClientSecret(); the protocol default
    /// (FakeTokenStore) returns nil. This is the fake-keychain test seam the
    /// production KeychainOIDCTokenStore conforms to.
    func test_oidcClientSecret_accessor_round_trips_through_the_store_seam() {
        let secretStore = SecretTokenStore()
        XCTAssertNil(secretStore.oidcClientSecret(), "unset secret reads nil")
        secretStore.clientSecret = "GOCSPX-xyz"
        XCTAssertEqual(secretStore.oidcClientSecret(), "GOCSPX-xyz", "set secret reads back")
        secretStore.clear()
        XCTAssertEqual(secretStore.oidcClientSecret(), "GOCSPX-xyz",
                       "clear() (sign-out) must NOT remove the client secret — it is client config")
        // Default-protocol conformer returns nil without overriding.
        XCTAssertNil(FakeTokenStore().oidcClientSecret(), "default protocol impl is nil")
    }

    func test_signOut_clears_store() async {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        let session = OIDCSession(config: Self.config(),
                                  httpClient: Self.http { _ in (Self.discoveryJSON(), 200) },
                                  tokenStore: store,
                                  authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        await session.signOut()
        XCTAssertTrue(store.log.contains("clear"))
    }

    // MARK: - client-secret ownership scoping (fix #57)
    //
    // The OIDC client secret is one GLOBAL Keychain item that survives sign-out
    // (it's client config). Before this fix it was a bare string with no record
    // of WHICH client it belonged to, so reconfiguring issuer/client_id (e.g.
    // Google Desktop → Okta public client) shipped the prior client's secret to
    // the NEW IdP. These tests pin the pure ownership-decision logic that scopes
    // the secret to its owning client. (The Keychain I/O wrapper is a thin
    // switch over this decision; the real Keychain isn't exercised in unit tests.)

    /// A secret stamped for client A is NOT returned when the config is switched
    /// to client B — the stale item is scheduled for deletion instead. THE CORE BUG.
    func test_client_secret_for_client_A_not_returned_after_switch_to_client_B() {
        let stored = Self.stampedSecret(clientID: "client-A", issuer: "https://a.example", secret: "secretA")
        let decision = KeychainStore.oidcClientSecretDecision(
            raw: stored, clientID: "client-B", issuer: "https://b.example")
        XCTAssertEqual(decision, .deleteStale,
                       "a secret saved for client A must not be served to client B")
    }

    /// Same client_id but a DIFFERENT issuer is also a mismatch — both halves of
    /// the owner stamp must match (a client_id can collide across IdPs).
    func test_client_secret_mismatch_on_issuer_change_only() {
        let stored = Self.stampedSecret(clientID: "c1", issuer: "https://old.example", secret: "s")
        let decision = KeychainStore.oidcClientSecretDecision(
            raw: stored, clientID: "c1", issuer: "https://new.example")
        XCTAssertEqual(decision, .deleteStale, "issuer change alone must invalidate the stamp")
    }

    /// The secret IS returned for the SAME client across sign-out: sign-out does
    /// not change the client config, so the owner still matches. Models the
    /// "survives sign-out" guarantee at the ownership layer.
    func test_client_secret_returned_for_same_client_across_sign_out() {
        let stored = Self.stampedSecret(clientID: "c1", issuer: "https://idp.example", secret: "keepme")
        // Sign-out clears refresh token + identity but leaves THIS item untouched,
        // so a later read for the same client still matches.
        let decision = KeychainStore.oidcClientSecretDecision(
            raw: stored, clientID: "c1", issuer: "https://idp.example")
        XCTAssertEqual(decision, .useStamped("keepme"),
                       "same-client read must still return the secret after sign-out")
    }

    /// Explicit clear (absent item) yields the no-op decision — nothing to read,
    /// nothing to delete.
    func test_client_secret_absent_yields_none() {
        let decision = KeychainStore.oidcClientSecretDecision(
            raw: nil, clientID: "c1", issuer: "https://idp.example")
        XCTAssertEqual(decision, .none, "a cleared/absent secret reads as none")
    }

    /// A legacy bare-string value (written before this fix, no owner stamp) is
    /// adopted by the current client via migration — keeps single-client installs
    /// working across the upgrade.
    func test_legacy_bare_string_secret_is_migrated_to_current_owner() {
        let decision = KeychainStore.oidcClientSecretDecision(
            raw: "legacy-plain-secret", clientID: "c1", issuer: "https://idp.example")
        XCTAssertEqual(decision, .migrateLegacy("legacy-plain-secret"),
                       "a pre-fix bare-string secret must be migrated, not dropped")
    }

    /// The stamped envelope round-trips through JSON: the value persisted by
    /// `setOIDCClientSecret` decodes back to a `.useStamped` with the same secret.
    func test_stamped_envelope_round_trips() {
        let stored = Self.stampedSecret(clientID: "c1", issuer: "https://idp.example", secret: "round-trip")
        let decision = KeychainStore.oidcClientSecretDecision(
            raw: stored, clientID: "c1", issuer: "https://idp.example")
        XCTAssertEqual(decision, .useStamped("round-trip"))
    }

    /// Helper: the exact JSON envelope `setOIDCClientSecret` writes, so the
    /// decision tests feed the same on-disk shape the reader sees in production.
    nonisolated static func stampedSecret(clientID: String, issuer: String, secret: String) -> String {
        let env = KeychainStore.OIDCClientSecretEnvelope(clientID: clientID, issuer: issuer, secret: secret)
        return String(data: try! JSONEncoder().encode(env), encoding: .utf8)!
    }

    // MARK: issuer scheme guard

    /// A session whose issuer uses plain HTTP on a non-loopback host must throw
    /// `discoveryFailed` from `idToken()` before any network call is issued —
    /// the issuer URL itself is rejected at the discovery stage.
    func test_http_non_loopback_issuer_throws_discoveryFailed() async {
        let store = FakeTokenStore(); store.refreshToken = "rt-live"
        let evilConfig = OIDCClientConfig(
            issuer: "http://evil.example", clientID: "c1",
            scopes: ["openid"], ephemeralBrowser: false)
        let session = OIDCSession(
            config: evilConfig,
            httpClient: Self.http { _ in (Self.discoveryJSON(), 200) },
            tokenStore: store,
            authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        do {
            _ = try await session.idToken()
            XCTFail("expected throw for http non-loopback issuer")
        } catch let f as OIDCAuthFailure {
            guard case .discoveryFailed = f else {
                return XCTFail("expected discoveryFailed, got \(f)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// A session whose issuer uses plain HTTP on a loopback host
    /// (e.g. http://localhost:8080/realms/parleq — the in-repo Keycloak dev rig)
    /// must pass the issuer guard and proceed past discovery. We let the flow
    /// complete (refresh token → token call) to confirm no throw at the discovery
    /// stage; the scripted httpClient serves the discovery doc and a token response.
    func test_http_loopback_issuer_proceeds_past_discovery() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        nonisolated(unsafe) let localDiscoveryJSON = Data(#"{"issuer":"http://localhost:8080/realms/parleq","authorization_endpoint":"http://localhost:8080/realms/parleq/protocol/openid-connect/auth","token_endpoint":"http://localhost:8080/realms/parleq/protocol/openid-connect/token"}"#.utf8)
        let loopbackConfig = OIDCClientConfig(
            issuer: "http://localhost:8080/realms/parleq", clientID: "c1",
            scopes: ["openid"], ephemeralBrowser: false)
        let session = OIDCSession(
            config: loopbackConfig,
            httpClient: Self.http { req in
                req.url!.path.contains("token")
                    ? (Self.tokenJSON(rt: nil), 200)
                    : (localDiscoveryJSON, 200)
            },
            tokenStore: store,
            authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        // Must not throw — the loopback issuer passes the HTTPS-or-loopback guard
        // and the scripted httpClient serves a valid discovery doc + token response.
        let token = try await session.idToken()
        XCTAssertFalse(token.isEmpty, "idToken must be non-empty after successful refresh")
    }

    // MARK: - Generic-OP: redirect_uri + extra_auth_params on the auth flow

    /// Helper: drives a full happy-path interactive sign-in with the given
    /// config, capturing the authorization-request URL and the token-call body.
    /// Returns (authURL queryItems, callbackScheme passed to the authenticator,
    /// token-call body string).
    private func runSignInCapturing(_ config: OIDCClientConfig) async throws
        -> (auth: [URLQueryItem], scheme: String, tokenBody: String) {
        let store = FakeTokenStore()
        let nonceBox = NonceBox()
        let authURLBox = CapturedURL()
        let schemeBox = CapturedBody()
        let tokenBodyBox = CapturedBody()
        let session = OIDCSession(config: config, httpClient: { req in
            let data: Data
            if req.url!.path.contains("token") {
                await tokenBodyBox.set(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")
                data = Self.tokenJSONWithNonce(await nonceBox.value)
            } else {
                data = Self.discoveryJSON()
            }
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { buildAuthorizationURL, scheme in
            // Custom-scheme path: build with the configured redirect (no override).
            let url = buildAuthorizationURL(nil)
            await authURLBox.set(url)
            await schemeBox.set(scheme ?? "")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            let nonce = items.first { $0.name == "nonce" }?.value ?? ""
            await nonceBox.set(nonce)
            return URL(string: "parleq-auth://oidc/callback?state=\(state)&code=c1")!
        })
        _ = try await session.signIn()
        let url = await authURLBox.value!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return (items, await schemeBox.value, await tokenBodyBox.value)
    }

    /// Default config (no redirect override, no extra params) must produce a
    /// byte-identical authorization request to the pre-feature behavior: the
    /// parleq-auth redirect, the parleq-auth callback scheme, and NO extra
    /// query params beyond the fixed eight.
    func test_default_config_authorization_request_is_unchanged() async throws {
        let (auth, scheme, tokenBody) = try await runSignInCapturing(Self.config())
        XCTAssertEqual(scheme, "parleq-auth", "default callback scheme")
        XCTAssertEqual(auth.first { $0.name == "redirect_uri" }?.value,
                       "parleq-auth://oidc/callback", "default auth redirect_uri")
        // Exactly the fixed eight params — no extras leaked in.
        let names = Set(auth.map { $0.name })
        XCTAssertEqual(names, ["response_type", "client_id", "redirect_uri", "scope",
                               "state", "nonce", "code_challenge", "code_challenge_method"],
                       "default config must add no extra auth params")
        // The body form-encodes via .alphanumerics, so '-'/':'/'/' are escaped;
        // the alphanumeric run "parleq" survives and uniquely identifies the
        // default redirect.
        XCTAssertTrue(tokenBody.contains("redirect_uri=parleq"),
                      "token call must use the parleq-auth redirect by default: \(tokenBody)")
    }

    /// A custom redirect URI (Google reversed-client-ID scheme) appears in the
    /// authorization request, the derived callback scheme, AND the token call.
    func test_custom_redirect_uri_flows_to_auth_scheme_and_token_call() async throws {
        let redirect = "com.googleusercontent.apps.1234:/oauth2redirect"
        let config = OIDCClientConfig(issuer: "https://idp.example", clientID: "c1",
                                      scopes: ["openid"], ephemeralBrowser: false,
                                      redirectURI: redirect)
        let (auth, scheme, tokenBody) = try await runSignInCapturing(config)
        XCTAssertEqual(scheme, "com.googleusercontent.apps.1234",
                       "callback scheme must be derived from the redirect URI")
        XCTAssertEqual(auth.first { $0.name == "redirect_uri" }?.value, redirect,
                       "auth request redirect_uri must be the configured value")
        // The token call form-encodes the value via .alphanumerics, so '.'/':'/'/'
        // are all percent-encoded. Assert the alphanumeric run that's unique to
        // the custom redirect is present and the parleq-auth default is NOT.
        XCTAssertTrue(tokenBody.contains("googleusercontent"),
                      "token call redirect_uri must be the configured value: \(tokenBody)")
        XCTAssertFalse(tokenBody.contains("redirect_uri=parleq"),
                       "token call must not fall back to the default redirect")
    }

    /// Loopback build-closure shape: an authenticator that builds the
    /// authorization URL with an EFFECTIVE redirect override (the ephemeral-port
    /// loopback URI it discovered after binding) must have that exact value —
    /// PORT included — flow into BOTH the authorization request's `redirect_uri`
    /// AND the token-exchange body. This is the contract the loopback
    /// authenticator relies on: the IdP and the token exchange see the same
    /// port-bearing redirect.
    func test_loopback_effective_redirect_flows_to_auth_and_token_call() async throws {
        let store = FakeTokenStore()
        let nonceBox = NonceBox()
        let authURLBox = CapturedURL()
        let tokenBodyBox = CapturedBody()
        // The effective (ephemeral-port) redirect the "loopback" authenticator
        // would discover after binding. Configured redirect is a custom scheme;
        // the override must WIN for both the auth URL and the token body.
        let effectiveRedirect = "http://127.0.0.1:54321/oauth2redirect"
        let config = OIDCClientConfig(issuer: "https://idp.example", clientID: "c1",
                                      scopes: ["openid"], ephemeralBrowser: false,
                                      redirectURI: "parleq-auth://oidc/callback")
        let session = OIDCSession(config: config, httpClient: { req in
            let data: Data
            if req.url!.path.contains("token") {
                await tokenBodyBox.set(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")
                data = Self.tokenJSONWithNonce(await nonceBox.value)
            } else {
                data = Self.discoveryJSON()
            }
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { buildAuthorizationURL, _ in
            // Loopback path: build with the discovered ephemeral redirect.
            let url = buildAuthorizationURL(effectiveRedirect)
            await authURLBox.set(url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            let nonce = items.first { $0.name == "nonce" }?.value ?? ""
            await nonceBox.set(nonce)
            // The IdP redirects to the loopback URI; reconstruct it with the query.
            return URL(string: "\(effectiveRedirect)?state=\(state)&code=c1")!
        })
        _ = try await session.signIn()

        let authURL = await authURLBox.value!
        let authItems = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(authItems.first { $0.name == "redirect_uri" }?.value, effectiveRedirect,
                       "auth request redirect_uri must be the effective (port-bearing) loopback URI")
        // Token body form-encodes via .alphanumerics, so ':'/'/'/'.'/'?' are
        // escaped; the digits "54321" survive verbatim and uniquely identify the
        // ephemeral-port redirect.
        let tokenBody = await tokenBodyBox.value
        XCTAssertTrue(tokenBody.contains("54321"),
                      "token call redirect_uri must carry the ephemeral port: \(tokenBody)")
        XCTAssertFalse(tokenBody.contains("redirect_uri=parleq"),
                       "token call must NOT fall back to the configured custom-scheme redirect")
    }

    /// Configured extra auth params are appended to the authorization request.
    func test_extra_auth_params_appear_in_authorization_request() async throws {
        let config = OIDCClientConfig(issuer: "https://idp.example", clientID: "c1",
                                      scopes: ["openid"], ephemeralBrowser: false,
                                      extraAuthParams: ["access_type": "offline", "prompt": "consent"])
        let (auth, _, _) = try await runSignInCapturing(config)
        XCTAssertEqual(auth.first { $0.name == "access_type" }?.value, "offline")
        XCTAssertEqual(auth.first { $0.name == "prompt" }?.value, "consent")
    }

    /// A reserved-key collision in extra_auth_params is DROPPED — Parleq's own
    /// state/nonce/client_id/etc. must win. Assert the reserved param keeps
    /// Parleq's value and is not duplicated.
    func test_reserved_extra_auth_param_is_dropped() async throws {
        let config = OIDCClientConfig(issuer: "https://idp.example", clientID: "c1",
                                      scopes: ["openid"], ephemeralBrowser: false,
                                      extraAuthParams: ["state": "attacker-fixed",
                                                        "client_id": "attacker",
                                                        "prompt": "consent"])
        let (auth, _, _) = try await runSignInCapturing(config)
        // client_id stays Parleq's, appears exactly once.
        let clientIDs = auth.filter { $0.name == "client_id" }
        XCTAssertEqual(clientIDs.count, 1, "client_id must not be duplicated")
        XCTAssertEqual(clientIDs.first?.value, "c1", "client_id must stay Parleq's value")
        // state stays Parleq's random value, appears exactly once, never the attacker's.
        let states = auth.filter { $0.name == "state" }
        XCTAssertEqual(states.count, 1, "state must not be duplicated")
        XCTAssertNotEqual(states.first?.value, "attacker-fixed", "reserved state override must be dropped")
        // The non-reserved param still made it through.
        XCTAssertEqual(auth.first { $0.name == "prompt" }?.value, "consent")
    }

    // MARK: - googleOAuth: access-token cache (Addendum 2)

    /// A token response with a short access lifetime (`expires_in`) but a long
    /// id_token `exp` claim. Lets the access cache expire while the id cache is
    /// still fresh — exercising the separate-expiry invariant.
    nonisolated static func tokenJSONSeparateExpiries(access: String,
                                                      expiresIn: Double,
                                                      idExp: Double,
                                                      rt: String?) -> Data {
        let idt = makeJWT(claims: ["sub": "u1", "email": "jon@acme.com",
                                   "iat": Date().timeIntervalSince1970, "exp": idExp])
        var obj: [String: Any] = ["access_token": access, "id_token": idt,
                                  "expires_in": expiresIn]
        if let rt { obj["refresh_token"] = rt }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    /// accessToken() returns the access token from a successful refresh and
    /// serves it from cache on the second call (one network round-trip).
    func test_accessToken_served_from_cache() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        let counter = TokenCallCounter()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("token") {
                await counter.increment()
                return (Self.tokenJSONSeparateExpiries(access: "at-live", expiresIn: 3600,
                                                       idExp: 9_999_999_999, rt: nil),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.discoveryJSON(),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        let t1 = try await session.accessToken()
        XCTAssertEqual(t1, "at-live")
        let t2 = try await session.accessToken()
        XCTAssertEqual(t2, "at-live")
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "second accessToken() must hit the cache, not re-refresh")
    }

    /// The access token expires (short expires_in) while the id_token stays
    /// fresh (far-future exp). A second accessToken() must trigger a refresh
    /// (its OWN expiry is the gate), even though idToken() would still be a
    /// cache hit — proving the two caches carry independent expiries.
    func test_accessToken_refreshes_when_access_expired_but_id_fresh() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        let counter = TokenCallCounter()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("token") {
                await counter.increment()
                let n = await counter.value
                // First refresh: access expires in 1 s (already inside the 60 s
                // freshness gate → uncacheable for accessToken), id_token exp is
                // far future (cacheable for idToken). Second refresh: a normal
                // long-lived access token.
                let data = n == 1
                    ? Self.tokenJSONSeparateExpiries(access: "at-stale", expiresIn: 1,
                                                     idExp: 9_999_999_999, rt: nil)
                    : Self.tokenJSONSeparateExpiries(access: "at-fresh", expiresIn: 3600,
                                                     idExp: 9_999_999_999, rt: nil)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.discoveryJSON(),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        // First access call refreshes (counter→1); the access token's 1 s expiry
        // is inside the 60 s gate, so the SECOND access call must refresh again.
        let a1 = try await session.accessToken()
        XCTAssertEqual(a1, "at-stale")
        // The id_token from refresh #1 has a far-future exp, so idToken() is a
        // cache hit — it must NOT trigger a refresh.
        _ = try await session.idToken()
        let afterID = await counter.value
        XCTAssertEqual(afterID, 1, "idToken() must be a cache hit, not refresh")
        // accessToken() again: its own expiry forces refresh #2 → at-fresh.
        let a2 = try await session.accessToken()
        XCTAssertEqual(a2, "at-fresh")
        let afterA2 = await counter.value
        XCTAssertEqual(afterA2, 2, "stale access token must trigger a second refresh")
    }

    /// Sign-out clears the access-token cache as well as the id-token cache.
    func test_accessToken_cache_cleared_on_signOut() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        let session = OIDCSession(config: Self.config(), httpClient: Self.http { req in
            req.url!.path.contains("token")
                ? (Self.tokenJSON(rt: nil), 200) : (Self.discoveryJSON(), 200)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        _ = try await session.accessToken()
        let cachedBefore = await session.debugHasCachedAccessToken
        XCTAssertTrue(cachedBefore, "access token cached after refresh")
        await session.signOut()
        let cachedAccessAfter = await session.debugHasCachedAccessToken
        let cachedIDAfter = await session.debugHasCachedToken
        XCTAssertFalse(cachedAccessAfter, "sign-out must clear the access cache")
        XCTAssertFalse(cachedIDAfter, "sign-out must clear the id cache")
    }

    /// invalidateAccessToken() drops ONLY the cached access token: the next
    /// accessToken() must perform a fresh refresh (network call increments),
    /// while the id-token cache and refresh token stay intact (no sign-out).
    func test_invalidateAccessToken_forces_refresh_on_next_access_call() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        let counter = TokenCallCounter()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("token") {
                await counter.increment()
                return (Self.tokenJSONSeparateExpiries(access: "at-live", expiresIn: 3600,
                                                       idExp: 9_999_999_999, rt: nil),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.discoveryJSON(),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        // Prime the cache (refresh #1).
        _ = try await session.accessToken()
        let callsAfterPrime = await counter.value
        XCTAssertEqual(callsAfterPrime, 1)
        // Without invalidation a second call is a cache hit (long-lived token).
        await session.invalidateAccessToken()
        let cachedAfterInvalidate = await session.debugHasCachedAccessToken
        XCTAssertFalse(cachedAfterInvalidate, "invalidateAccessToken must drop the cached access token")
        // id cache and refresh token untouched — still signed in.
        let idCachedAfterInvalidate = await session.debugHasCachedToken
        XCTAssertTrue(idCachedAfterInvalidate, "id-token cache must survive access-token invalidation")
        XCTAssertEqual(store.refreshToken, "rt1", "refresh token must survive access-token invalidation")
        // Next access call must mint a fresh token (refresh #2).
        let t = try await session.accessToken()
        XCTAssertEqual(t, "at-live")
        let callsAfterReaccess = await counter.value
        XCTAssertEqual(callsAfterReaccess, 2, "next accessToken() after invalidate must refresh")
    }

    /// A nonconforming IdP can put prose / log-breaking text in the OAuth
    /// `error` param. The value lands in idpRejected.code (logged verbatim), so
    /// it must be sanitized: a value outside the RFC 6749 error-code charset is
    /// replaced with a fixed code, while the raw text is preserved ONLY in the
    /// doctor-only `detail` (never logged).
    func test_signIn_nonstandard_error_value_is_sanitized_for_code() async {
        let store = FakeTokenStore()
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            (Self.discoveryJSON(),
             HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { buildAuthorizationURL, _ in
            let url = buildAuthorizationURL(nil)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            // Prose with spaces + punctuation — not a valid OAuth error code.
            let raw = "some prose with spaces!".addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed)!
            return URL(string: "parleq-auth://oidc/callback?state=\(state)&error=\(raw)")!
        })
        do { _ = try await session.signIn(); XCTFail("expected idpRejected") }
        catch let f as OIDCAuthFailure {
            guard case .idpRejected(let code, let detail) = f else { return XCTFail("\(f)") }
            XCTAssertEqual(code, "nonstandard_error", "nonconforming error must use the fixed code")
            XCTAssertTrue(detail.contains("some prose with spaces!"),
                          "raw value must be preserved in the doctor-only detail: \(detail)")
            // The logged rendering must carry ONLY the sanitized code, never the raw prose.
            XCTAssertEqual(f.logLine, "oidc state=idpRejected code=nonstandard_error")
            XCTAssertFalse(f.logLine.contains("prose"), "raw IdP text must never reach logLine")
        } catch { XCTFail("\(error)") }
    }

    /// Concurrent idToken() + accessToken() callers on a cold session share the
    /// ONE single-flight refresh: exactly one network token call, and both
    /// accessors return their freshly-cached token.
    func test_single_flight_shared_between_idToken_and_accessToken() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        let counter = TokenCallCounter()
        let gate = Gate()
        let started = Gate()   // opened once the token call is parked
        let session = OIDCSession(config: Self.config(), httpClient: { req in
            if req.url!.path.contains("token") {
                await counter.increment(); await started.open(); await gate.wait()
            }
            let data = req.url!.path.contains("token")
                ? Self.tokenJSONSeparateExpiries(access: "at-live", expiresIn: 3600,
                                                 idExp: 9_999_999_999, rt: nil)
                : Self.discoveryJSON()
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        // First caller (idToken) enters the actor and parks the token call.
        let idTask = Task { try await session.idToken() }
        await started.wait()
        // Second caller (accessToken) now arrives while the refresh is in flight
        // → must JOIN it, not start a new one.
        let accessTask = Task { try await session.accessToken() }
        // Give the second caller a turn to enter the actor and join the in-flight
        // task before we release the held token call.
        for _ in 0..<50 { await Task.yield() }
        await gate.open()
        let id = try await idTask.value
        let access = try await accessTask.value
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(access, "at-live")
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "concurrent idToken()+accessToken() must share one refresh")
    }

    // MARK: granted-scope verification (RFC 6749 §5.1) — interactive sign-in

    /// Config that asks for the Google scope set (incl. cloud-platform), so the
    /// granular-consent downgrade can be exercised.
    nonisolated static func googleScopeConfig() -> OIDCClientConfig {
        OIDCClientConfig(issuer: "https://idp.example", clientID: "c1",
                         scopes: ["openid", "email", "https://www.googleapis.com/auth/cloud-platform"],
                         ephemeralBrowser: false)
    }
    /// Token-response JSON carrying the nonce AND a granted `scope` field
    /// (RFC 6749 §5.1). `scope: nil` omits the field entirely (unverifiable).
    nonisolated static func tokenJSONWithScope(_ nonce: String?, scope: String?, rt: String? = "rt-granted") -> Data {
        var claims: [String: Any] = ["sub": "u1", "email": "jon@acme.com",
                                     "iat": 1_700_000_000.0, "exp": 9_999_999_999.0]
        if let nonce { claims["nonce"] = nonce }
        let idt = makeJWT(claims: claims)
        var obj: [String: Any] = ["access_token": "at", "id_token": idt, "expires_in": 3600.0]
        if let rt { obj["refresh_token"] = rt }
        if let scope { obj["scope"] = scope }
        return try! JSONSerialization.data(withJSONObject: obj)
    }
    /// Drives an interactive sign-in whose token response grants `scope`,
    /// echoing the authorization-request nonce so the §3.1.3.7 check passes.
    private func runSignIn(config: OIDCClientConfig, store: FakeTokenStore,
                           grantedScope: String?) -> OIDCSession {
        let nonceBox = NonceBox()
        return OIDCSession(config: config, httpClient: { req in
            let data: Data
            if req.url!.path.contains("token") {
                data = Self.tokenJSONWithScope(await nonceBox.value, scope: grantedScope)
            } else {
                data = Self.discoveryJSON()
            }
            return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { buildAuthorizationURL, _ in
            let url = buildAuthorizationURL(nil)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = items.first { $0.name == "state" }?.value ?? ""
            let nonce = items.first { $0.name == "nonce" }?.value ?? ""
            await nonceBox.set(nonce)
            return URL(string: "parleq-auth://oidc/callback?state=\(state)&code=c1")!
        })
    }

    /// (1) Granted set omits cloud-platform (the granular-consent box wasn't
    /// ticked) → signIn throws scopeNotGranted and persists NOTHING.
    func test_signIn_missing_required_scope_throws_scopeNotGranted_and_persists_nothing() async {
        let store = FakeTokenStore()
        let session = runSignIn(config: Self.googleScopeConfig(), store: store,
                                grantedScope: "openid email")
        do { _ = try await session.signIn(); XCTFail("expected scopeNotGranted") }
        catch let f as OIDCAuthFailure {
            guard case .scopeNotGranted(let missing) = f else { return XCTFail("\(f)") }
            XCTAssertEqual(missing, ["https://www.googleapis.com/auth/cloud-platform"])
        } catch { XCTFail("\(error)") }
        XCTAssertNil(store.refreshToken, "no RT may be persisted on a rejected sign-in")
        XCTAssertNil(store.identity, "no identity may be persisted on a rejected sign-in")
        let cached = await session.debugHasCachedAccessToken
        XCTAssertFalse(cached, "no access token may be cached on a rejected sign-in")
        let state = await session.state
        guard case .signedOut = state else { return XCTFail("\(state)") }
    }

    /// (2) Granted == requested → sign-in succeeds.
    func test_signIn_granted_equals_requested_succeeds() async throws {
        let store = FakeTokenStore()
        let session = runSignIn(config: Self.googleScopeConfig(), store: store,
                                grantedScope: "openid email https://www.googleapis.com/auth/cloud-platform")
        let id = try await session.signIn()
        XCTAssertEqual(id.sub, "u1")
        let state = await session.state
        guard case .signedIn = state else { return XCTFail("\(state)") }
    }

    /// (3) No `scope` field in the response → can't verify → proceed (success).
    func test_signIn_no_scope_field_proceeds() async throws {
        let store = FakeTokenStore()
        let session = runSignIn(config: Self.googleScopeConfig(), store: store,
                                grantedScope: nil)
        let id = try await session.signIn()
        XCTAssertEqual(id.sub, "u1")
        let state = await session.state
        guard case .signedIn = state else { return XCTFail("\(state)") }
    }

    /// (4) Granted omits only standard OIDC scopes (offline_access / profile),
    /// which IdPs normalize away — the allowlist means this still succeeds.
    func test_signIn_missing_only_standard_oidc_scopes_succeeds() async throws {
        let store = FakeTokenStore()
        let config = OIDCClientConfig(issuer: "https://idp.example", clientID: "c1",
                                      scopes: ["openid", "profile", "email", "offline_access"],
                                      ephemeralBrowser: false)
        // IdP echoes only "openid email" — profile/offline_access dropped.
        let session = runSignIn(config: config, store: store, grantedScope: "openid email")
        let id = try await session.signIn()
        XCTAssertEqual(id.sub, "u1")
        let state = await session.state
        guard case .signedIn = state else { return XCTFail("\(state)") }
    }

    // MARK: refresh request body (RFC 6749 §6) — scope omitted

    /// The refresh grant MUST NOT send a `scope` parameter — omitting it means
    /// "same scope as originally granted" (RFC 6749 §6), avoiding an
    /// invalid_scope teardown when the granted set was narrower than configured.
    func test_refresh_request_body_omits_scope() async throws {
        let store = FakeTokenStore(); store.refreshToken = "rt1"
        let captured = CapturedBody()
        let session = OIDCSession(config: Self.googleScopeConfig(), httpClient: { req in
            if req.url!.path.contains("token") {
                await captured.set(String(data: req.httpBody ?? Data(), encoding: .utf8) ?? "")
                return (Self.tokenJSON(rt: nil),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.discoveryJSON(),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        _ = try await session.idToken()
        let body = await captured.value
        XCTAssertFalse(body.contains("scope="), "refresh body must not carry a scope key: \(body)")
        XCTAssertTrue(body.contains("grant_type=refresh"), body)
        XCTAssertTrue(body.contains("refresh_token="), body)
    }
}

actor TokenCallCounter { var value = 0; func increment() { value += 1 } }

/// One-shot async barrier: waiters park until `open()`; opens are idempotent
/// and waiters arriving after open proceed immediately. Deterministic stand-in
/// for wall-clock sleeps in concurrency tests.
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        guard !opened else { return }
        opened = true
        let w = waiters; waiters = []
        for c in w { c.resume() }
    }
}

actor CapturedBody { var value = ""; func set(_ v: String) { value = v } }
actor CapturedURL { var value: URL?; func set(_ v: URL) { value = v } }

/// Lock-backed ordered log shared between a synchronous token store (`clear()`)
/// and the async httpClient (`revoke`). A plain actor can't back `clear()` —
/// `OIDCTokenStore.clear()` is synchronous and non-isolated — so this uses an
/// NSLock to record both events into one ordered sequence for ordering asserts.
final class OrderedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []
    func append(_ s: String) { lock.lock(); _entries.append(s); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return _entries }
}

/// Token store that records its `clear()` into a shared OrderedLog so the
/// clear-before-revocation ordering can be asserted against the httpClient's
/// revoke entry.
final class SharedLogTokenStore: OIDCTokenStore, @unchecked Sendable {
    var refreshToken: String?
    var identity: OIDCIdentity?
    private let log: OrderedLog
    init(log: OrderedLog) { self.log = log }
    func loadRefreshToken() -> String? { refreshToken }
    func saveRefreshToken(_ t: String) -> Bool { refreshToken = t; return true }
    func loadIdentity() -> OIDCIdentity? { identity }
    func saveIdentity(_ i: OIDCIdentity) -> Bool { identity = i; return true }
    func clear() { log.append("clear"); refreshToken = nil; identity = nil }
}

/// Bridges the captured authorization-request nonce from the authenticator
/// closure to the httpClient closure in the signIn nonce-verification tests.
actor NonceBox { var value: String?; func set(_ v: String) { value = v } }

/// Token store whose saveRefreshToken always reports failure (e.g. Keychain
/// unavailable). Used to assert apply() fails loudly with .rotationLost when a
/// rotated refresh token can't be persisted, rather than silently signing in.
final class FailingSaveTokenStore: OIDCTokenStore, @unchecked Sendable {
    var refreshToken: String?
    var identity: OIDCIdentity?
    var log: [String] = []
    func loadRefreshToken() -> String? { log.append("loadRT"); return refreshToken }
    func saveRefreshToken(_ t: String) -> Bool { log.append("saveRT:\(t)"); return false }   // persistence always fails
    func loadIdentity() -> OIDCIdentity? { identity }
    func saveIdentity(_ i: OIDCIdentity) -> Bool { identity = i; return true }
    func clear() { log.append("clear"); refreshToken = nil; identity = nil }
}

/// Token store that ALSO provides an optional client secret (Google "Desktop
/// app" clients). When `clientSecret` is nil, `oidcClientSecret()` returns nil
/// and the token call must omit the key entirely (default-protocol behavior).
final class SecretTokenStore: OIDCTokenStore, @unchecked Sendable {
    var refreshToken: String?
    var identity: OIDCIdentity?
    var clientSecret: String?
    func loadRefreshToken() -> String? { refreshToken }
    func saveRefreshToken(_ t: String) -> Bool { refreshToken = t; return true }
    func loadIdentity() -> OIDCIdentity? { identity }
    func saveIdentity(_ i: OIDCIdentity) -> Bool { identity = i; return true }
    func clear() { refreshToken = nil; identity = nil }   // does NOT touch clientSecret (client config)
    func oidcClientSecret() -> String? { clientSecret }
}
