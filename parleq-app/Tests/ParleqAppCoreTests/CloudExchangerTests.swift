import XCTest
@testable import ParleqAppCore

struct FakeExchanger: CloudCredentialExchanger {
    let onExchange: @Sendable (String) async throws -> (String, Date)
    func exchange(idToken: String) async throws -> (credentials: String, expiresAt: Date) {
        try await onExchange(idToken)
    }
}

final class CloudExchangerTests: XCTestCase {
    func makeSession(idToken: String = OIDCSessionTests.idt) -> OIDCSession {
        makeSessionWithStore(idToken: idToken).session
    }
    /// Variant that also hands back the token store so a test can simulate a
    /// re-sign-in after signOut() (signOut clears the refresh token, so to drive
    /// a fresh exchange afterward the store must be re-seeded).
    func makeSessionWithStore(idToken: String = OIDCSessionTests.idt)
        -> (session: OIDCSession, store: FakeTokenStore) {
        let store = FakeTokenStore(); store.refreshToken = "rt"
        let tokenJSON = try! JSONSerialization.data(withJSONObject:
            ["access_token": "at", "id_token": idToken, "expires_in": 3600.0])
        let session = OIDCSession(
            config: OIDCClientConfig(issuer: "https://idp.example", clientID: "c1",
                                     scopes: ["openid"], ephemeralBrowser: false),
            httpClient: { req in
                let data = req.url!.path.contains("token") ? tokenJSON
                    : Data(#"{"issuer":"i","authorization_endpoint":"https://i/a","token_endpoint":"https://i/token"}"#.utf8)
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            tokenStore: store, authenticator: { _, _ in throw OIDCAuthFailure.signInCancelled })
        return (session, store)
    }
    func test_single_flight_many_awaiters_one_exchange_call() async throws {
        let counter = TokenCallCounter()
        // Deterministic barrier: park the exchange call until all 8 awaiters
        // are launched. With the first exchange held, none can observe a
        // finished task — all 8 must share one call.
        let gate = Gate()
        let exchanger = FakeExchanger { _ in
            await counter.increment()
            await gate.wait()
            return ("creds-sf", Date().addingTimeInterval(600))
        }
        let cache = CachedExchange(exchanger: exchanger, session: makeSession(), leg: .aws)
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await cache.credentials() } }
            await gate.open()
            for try await _ in group {}
        }
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "8 concurrent awaiters must share one exchange call")
    }
    func test_cache_hits_within_ttl_and_reexchanges_inside_refresh_ahead() async throws {
        let counter = TokenCallCounter()
        // First exchange: expires 10 min out (outside 5-min margin → cached).
        // We then force a second call by handing back an expiry 4 min out.
        let exchanger = FakeExchanger { _ in
            await counter.increment()
            let n = await counter.value
            return ("creds\(n)", Date().addingTimeInterval(n == 1 ? 600 : 240))
        }
        let cache = CachedExchange(exchanger: exchanger, session: makeSession(), leg: .aws)
        let c1 = try await cache.credentials()
        let c2 = try await cache.credentials()
        XCTAssertEqual(c1, "creds1"); XCTAssertEqual(c2, "creds1", "within TTL → cache hit")
        await cache.invalidate()
        let c3 = try await cache.credentials()
        XCTAssertEqual(c3, "creds2")
        // creds2 expires in 4 min — inside the 5-min refresh-ahead margin,
        // so the next read re-exchanges.
        let c4 = try await cache.credentials()
        XCTAssertEqual(c4, "creds3")
    }
    func test_warm_never_throws_and_populates() async throws {
        let exchanger = FakeExchanger { _ in ("creds", Date().addingTimeInterval(600)) }
        let cache = CachedExchange(exchanger: exchanger, session: makeSession(), leg: .gcp)
        await cache.warm()
        let status = await cache.hopStatus
        XCTAssertNotNil(status.lastSuccess)
    }
    func test_failure_records_hop_status() async {
        let exchanger = FakeExchanger { _ in throw OIDCAuthFailure.exchangeDenied(leg: .aws, detail: "trust policy") }
        let cache = CachedExchange(exchanger: exchanger, session: makeSession(), leg: .aws)
        _ = try? await cache.credentials()
        let status = await cache.hopStatus
        XCTAssertEqual(status.lastError, "trust policy")
    }

    /// Sign-out revokes cloud-credential ACCESS: after signOut() + invalidate()
    /// the cached credentials are gone, so the next credentials() must re-run
    /// the exchange (count goes 1 → 2) rather than serve the pre-signout result.
    func test_signout_invalidates_cache_forcing_fresh_exchange() async throws {
        let counter = TokenCallCounter()
        let exchanger = FakeExchanger { _ in
            await counter.increment()
            return ("creds", Date().addingTimeInterval(600))
        }
        let (session, store) = makeSessionWithStore()
        let cache = CachedExchange(exchanger: exchanger, session: session, leg: .aws)
        _ = try await cache.credentials()
        let afterFirst = await counter.value
        XCTAssertEqual(afterFirst, 1, "first credentials() runs one exchange and caches it")
        // The user signs out, then the signOut closure invalidates the cache.
        await session.signOut()
        await cache.invalidate()
        // Simulate the subsequent re-sign-in: signOut() cleared the refresh
        // token, so re-seed it (the session would acquire a new one on the next
        // interactive sign-in) — otherwise the silent refresh has nothing to
        // present and the next exchange can't even reach the exchanger.
        store.refreshToken = "rt2"
        _ = try await cache.credentials()
        let afterSignout = await counter.value
        XCTAssertEqual(afterSignout, 2,
                       "post-signout credentials() must re-exchange, not serve the invalidated cache")
    }

    /// A sign-out DURING a gated in-flight exchange must not repopulate the
    /// cache: the superseded result is discarded by the generation re-check in
    /// exchangeNow(), so a subsequent credentials() still has to re-exchange
    /// (the call count increments rather than staying put).
    func test_signout_during_inflight_exchange_does_not_repopulate_cache() async throws {
        let counter = TokenCallCounter()
        let started = Gate()   // exchange signals it has begun
        let release = Gate()   // test releases the parked exchange after signing out
        let exchanger = FakeExchanger { _ in
            await counter.increment()
            await started.open()
            await release.wait()
            return ("creds-inflight", Date().addingTimeInterval(600))
        }
        let (session, store) = makeSessionWithStore()
        let cache = CachedExchange(exchanger: exchanger, session: session, leg: .aws)
        // Launch the in-flight exchange and wait until it's actually started.
        let inflight = Task { try await cache.credentials() }
        await started.wait()
        // Sign out while the exchange is parked, then invalidate (the signOut
        // closure's contract). signOut() bumps the session generation, so the
        // parked exchange's result is now stale.
        await session.signOut()
        await cache.invalidate()
        // Let the parked exchange finish — its result must be discarded by the
        // generation re-check (superseded → not cached).
        await release.open()
        _ = try? await inflight.value   // superseded → throws or no-ops; either way no cache write
        // Simulate the re-sign-in that follows signOut so the fresh exchange
        // below can reach the exchanger (signOut cleared the refresh token).
        store.refreshToken = "rt2"
        // A fresh credentials() must re-exchange (count increments), proving the
        // superseded in-flight result never landed in the cache.
        _ = try? await cache.credentials()
        let calls = await counter.value
        XCTAssertEqual(calls, 2,
            "inflight result must be discarded by generation check, and exactly one fresh exchange must follow — no more, no less")
    }

    /// The generation check on a CACHE HIT alone protects the async gap between
    /// session.signOut() (generation bump) and the signOut closure's
    /// invalidate(): a concurrent dictation that hits the still-fresh cache in
    /// that window must NOT be served the pre-logout credentials. This drives
    /// signOut() WITHOUT calling invalidate() — so only the cache-hit
    /// generation guard can protect the gap.
    func test_cache_hit_generation_check_protects_signout_gap_without_invalidate() async throws {
        let counter = TokenCallCounter()
        let exchanger = FakeExchanger { _ in
            await counter.increment()
            return ("creds", Date().addingTimeInterval(600))
        }
        let (session, store) = makeSessionWithStore()
        let cache = CachedExchange(exchanger: exchanger, session: session, leg: .aws)
        // Populate the cache with a long-lived (within-TTL) entry.
        let first = try await cache.credentials()
        XCTAssertEqual(first, "creds")
        let afterFirst = await counter.value
        XCTAssertEqual(afterFirst, 1, "first credentials() runs one exchange and caches it")
        // Sign out — bumps the generation — but deliberately DO NOT invalidate(),
        // simulating the in-between window where a concurrent dictation races the
        // signOut closure's invalidate() call.
        await session.signOut()
        // Re-seed the refresh token so the fresh exchange forced by the stale
        // cache entry can reach the exchanger (signOut cleared it).
        store.refreshToken = "rt2"
        // The cache entry is still fresh by TTL, but its generation no longer
        // matches: credentials() must reject it and re-exchange rather than
        // serve the pre-logout credentials.
        _ = try? await cache.credentials()
        let afterSignout = await counter.value
        XCTAssertEqual(afterSignout, 2,
            "a within-TTL cache hit under a stale generation must trigger exactly one re-exchange — the generation check alone covers the signout/invalidate gap")
    }

    /// The in-flight JOIN path must be generation-safe too: a second awaiter
    /// that joined the single-flight exchange BEFORE signOut() must not receive
    /// the pre-logout credentials when the exchange resolves afterward. Both the
    /// originating awaiter and the joiner must fail closed, and the cache must
    /// stay empty (a superseded result never lands).
    func test_inflight_join_does_not_serve_pre_signout_credentials_to_either_awaiter() async throws {
        let counter = TokenCallCounter()
        let started = Gate()   // exchange signals it has begun
        let release = Gate()   // test releases the parked exchange after signing out
        let exchanger = FakeExchanger { _ in
            await counter.increment()
            await started.open()
            await release.wait()
            return ("creds-inflight", Date().addingTimeInterval(600))
        }
        let (session, store) = makeSessionWithStore()
        let cache = CachedExchange(exchanger: exchanger, session: session, leg: .aws)
        // First awaiter mints the in-flight exchange; wait until it's running.
        let first = Task { try await cache.credentials() }
        await started.wait()
        // Second awaiter JOINS the in-flight exchange (single-flight: shares the
        // same task) — minted under the pre-signOut generation.
        let second = Task { try await cache.credentials() }
        // Spin-wait until the second caller has definitely entered the join path
        // (incremented debugWaiterCount inside the inFlight branch). Without this
        // the signOut could race the spawn and the join assertion below would be
        // vacuous (second might not have reached the join branch yet).
        // Bounded spin: if a future change makes the second caller mint a
        // fresh exchange instead of joining, fail with a diagnostic rather
        // than hanging the suite.
        var spins = 0
        while await !cache.debugWaiterJoined {
            await Task.yield()
            spins += 1
            if spins > 100_000 {
                return XCTFail("second caller never joined the in-flight exchange")
            }
        }
        // Sign out while both are parked on the in-flight exchange. signOut()
        // bumps the generation; the parked result is now stale for everyone.
        await session.signOut()
        // Release the parked exchange so the task resolves.
        await release.open()
        // BOTH awaiters must fail closed — neither may receive the pre-logout
        // credentials, regardless of whether they minted or joined.
        var firstThrew = false, secondThrew = false
        do { _ = try await first.value } catch { firstThrew = true }
        do { _ = try await second.value } catch { secondThrew = true }
        XCTAssertTrue(firstThrew, "the minting awaiter must not receive post-signout credentials")
        XCTAssertTrue(secondThrew, "the joining awaiter must not receive post-signout credentials")
        // The second caller confirmed a true join (only one exchange ran for both).
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "both awaiters shared one exchange — the join path was taken, not a second mint")
        // The cache must remain empty: a fresh credentials() has to re-exchange.
        store.refreshToken = "rt2"
        _ = try? await cache.credentials()
        let callsAfterReseed = await counter.value
        XCTAssertEqual(callsAfterReseed, 2,
            "the superseded in-flight result must not populate the cache — a later credentials() re-exchanges")
    }

    /// A successful interactive sign-in opens a NEW credential epoch — re-auth
    /// may be an ACCOUNT SWITCH, so cloud credentials minted under the PRIOR
    /// identity must not outlive it. signIn() bumps the session generation, so a
    /// cache entry minted before the sign-in no longer matches the current
    /// generation: the next credentials() must reject it and RE-EXCHANGE (count
    /// goes 1 → 2) rather than serve the pre-sign-in (prior-account) credentials.
    func test_interactive_signin_opens_new_credential_epoch_forcing_reexchange() async throws {
        let counter = TokenCallCounter()
        let exchanger = FakeExchanger { _ in
            await counter.increment()
            return ("creds", Date().addingTimeInterval(600))
        }
        // Build a session whose interactive signIn() actually succeeds: the
        // authenticator parses state/nonce off the authorization URL and the
        // httpClient serves a token response echoing that nonce (round-9 pattern).
        let store = FakeTokenStore(); store.refreshToken = "rt"
        let nonceBox = NonceBox()
        let session = OIDCSession(
            config: OIDCClientConfig(issuer: "https://idp.example", clientID: "c1",
                                     scopes: ["openid"], ephemeralBrowser: false),
            httpClient: { req in
                let data: Data
                if req.url!.path.contains("token") {
                    data = OIDCSessionTests.tokenJSONWithNonce(await nonceBox.value)
                } else {
                    data = OIDCSessionTests.discoveryJSON()
                }
                return (data, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            tokenStore: store,
            authenticator: { buildAuthorizationURL, _ in
                let url = buildAuthorizationURL(nil)
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let state = items.first { $0.name == "state" }?.value ?? ""
                let nonce = items.first { $0.name == "nonce" }?.value ?? ""
                await nonceBox.set(nonce)
                return URL(string: "parleq-auth://oidc/callback?state=\(state)&code=c1")!
            })
        let cache = CachedExchange(exchanger: exchanger, session: session, leg: .aws)
        // Populate the cache under the PRIOR identity's generation.
        let first = try await cache.credentials()
        XCTAssertEqual(first, "creds")
        let afterFirst = await counter.value
        XCTAssertEqual(afterFirst, 1, "first credentials() runs one exchange and caches it")
        // Interactive re-sign-in (possible account switch) — bumps the generation.
        _ = try await session.signIn()
        // The cache entry is still fresh by TTL, but it was minted under the prior
        // generation: credentials() must reject it and re-exchange.
        _ = try await cache.credentials()
        let afterSignIn = await counter.value
        XCTAssertEqual(afterSignIn, 2,
            "interactive sign-in opens a new credential epoch — pre-sign-in credentials must not survive it, so credentials() re-exchanges")
    }
}

final class AWSGCPExchangerTests: XCTestCase {
    func test_role_session_name_sanitization() {
        XCTAssertEqual(AWSWebIdentityExchanger.sanitizeSessionName("jon+yoder@acme.com"),
                       "jon+yoder@acme.com")     // legal charset passes through
        XCTAssertEqual(AWSWebIdentityExchanger.sanitizeSessionName("jon yöder!"),
                       "jonyder")                 // illegal chars stripped
        XCTAssertEqual(AWSWebIdentityExchanger.sanitizeSessionName(""), "parleq-user")
        XCTAssertEqual(AWSWebIdentityExchanger.sanitizeSessionName(String(repeating: "a", count: 99)).count, 64)
    }
    func test_gcp_exchange_builds_request_and_parses_response() async throws {
        let captured = RequestBox()
        let exchanger = GCPWorkforceExchanger(
            workforceProvider: "locations/global/workforcePools/acme/providers/kc",
            userProject: "parleq-dev",
            httpClient: { req in
                await captured.set(req)
                let body = #"{"access_token":"fed-token","expires_in":3600}"#
                return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200,
                                                          httpVersion: nil, headerFields: nil)!)
            })
        let (creds, exp) = try await exchanger.exchange(idToken: "idt-abc")
        XCTAssertEqual(creds.token, "fed-token")
        XCTAssertGreaterThan(exp.timeIntervalSinceNow, 3000)
        let req = await captured.value!
        XCTAssertEqual(req.url?.absoluteString, "https://sts.googleapis.com/v1/token")
        let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("subject_token=idt-abc"))
        XCTAssertTrue(bodyStr.contains("workforcePools%2Facme"))
        XCTAssertTrue(bodyStr.contains("grant_type=urn%3Aietf%3A"))
        XCTAssertTrue(bodyStr.contains("userProject"))
    }
    func test_aws_exchange_happy_path_passes_args_and_round_trips_credentials() async throws {
        // Capture the seam's arguments so we can assert the session name is
        // computed live from userEmailProvider, and roleArn/duration/token
        // flow through unchanged.
        let captured = AWSCallBox()
        let exchanger = AWSWebIdentityExchanger(
            roleArn: "arn:aws:iam::123456789012:role/T",
            region: "us-east-2",
            userEmailProvider: { "jon@acme.com" },
            durationSeconds: 3600,
            callSTS: { roleArn, sessionName, token, duration, region in
                await captured.set(roleArn: roleArn, sessionName: sessionName,
                                   token: token, duration: duration, region: region)
                return (AWSTemporaryCredentials(accessKeyID: "AK", secretAccessKey: "SK",
                                                sessionToken: "ST"),
                        Date().addingTimeInterval(3600))
            })
        let (creds, exp) = try await exchanger.exchange(idToken: "tok")
        XCTAssertEqual(creds.accessKeyID, "AK")
        XCTAssertEqual(creds.secretAccessKey, "SK")
        XCTAssertEqual(creds.sessionToken, "ST")
        XCTAssertGreaterThan(exp.timeIntervalSinceNow, 3000)
        // sessionName is computed inside exchange() from userEmailProvider
        // (sanitized) — the email charset is legal, so it round-trips intact.
        let (sessionName, roleArn, duration, token, region) =
            (await captured.sessionName, await captured.roleArn, await captured.duration,
             await captured.token, await captured.region)
        XCTAssertEqual(sessionName, "jon@acme.com")
        XCTAssertEqual(roleArn, "arn:aws:iam::123456789012:role/T")
        XCTAssertEqual(duration, 3600)
        XCTAssertEqual(token, "tok")
        XCTAssertEqual(region, "us-east-2")
    }
    func test_aws_exchange_wraps_seam_error_as_exchangeDenied() async {
        let exchanger = AWSWebIdentityExchanger(
            roleArn: "arn:aws:iam::123456789012:role/T",
            region: "us-east-2",
            userEmailProvider: { "jon@acme.com" },
            durationSeconds: 3600,
            callSTS: { _, _, _, _, _ in throw NSError(domain: "t", code: 1) })
        do { _ = try await exchanger.exchange(idToken: "tok"); XCTFail("expected throw") }
        catch let f as OIDCAuthFailure {
            guard case .exchangeDenied(let leg, let detail) = f else { return XCTFail("\(f)") }
            XCTAssertEqual(leg, .aws)
            XCTAssertFalse(detail.isEmpty, "wrapped error must carry non-empty detail")
        } catch { XCTFail("\(error)") }
    }
    func test_gcp_exchange_maps_4xx_to_exchangeDenied() async {
        let exchanger = GCPWorkforceExchanger(
            workforceProvider: "locations/global/workforcePools/acme/providers/kc",
            userProject: "p",
            httpClient: { req in
                (Data(#"{"error":"invalid_grant","error_description":"aud mismatch"}"#.utf8),
                 HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
            })
        do { _ = try await exchanger.exchange(idToken: "x"); XCTFail("expected throw") }
        catch let f as OIDCAuthFailure {
            guard case .exchangeDenied(let leg, let d) = f else { return XCTFail("\(f)") }
            XCTAssertEqual(leg, .gcp); XCTAssertTrue(d.contains("aud mismatch"))
        } catch { XCTFail("\(error)") }
    }
}
actor RequestBox { var value: URLRequest?; func set(_ r: URLRequest) { value = r } }
actor AWSCallBox {
    var roleArn = ""; var sessionName = ""; var token = ""; var duration = 0; var region = ""
    func set(roleArn: String, sessionName: String, token: String, duration: Int, region: String) {
        self.roleArn = roleArn; self.sessionName = sessionName
        self.token = token; self.duration = duration; self.region = region
    }
}
