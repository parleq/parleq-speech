import XCTest
@testable import ParleqAppCore

final class OIDCCoreTests: XCTestCase {
    // RFC 7636 Appendix B vector.
    func test_pkce_challenge_matches_rfc7636_vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(forVerifier: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func test_pkce_generate_produces_43_char_unreserved_verifier() {
        let p = PKCE.generate()
        // 32 bytes base64url-without-padding is always exactly 43 characters.
        XCTAssertEqual(p.verifier.count, 43)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(p.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertEqual(p.challenge, PKCE.challenge(forVerifier: p.verifier))
    }
    func test_discovery_parses_required_endpoints() throws {
        let json = #"{"issuer":"https://idp.example","authorization_endpoint":"https://idp.example/auth","token_endpoint":"https://idp.example/token","revocation_endpoint":"https://idp.example/revoke"}"#
        let d = try OIDCDiscovery.parse(Data(json.utf8))
        XCTAssertEqual(d.authorizationEndpoint.absoluteString, "https://idp.example/auth")
        XCTAssertEqual(d.tokenEndpoint.absoluteString, "https://idp.example/token")
        XCTAssertEqual(d.revocationEndpoint?.absoluteString, "https://idp.example/revoke")
    }
    func test_discovery_http_non_loopback_endpoint_throws_discoveryFailed() {
        let json = #"{"issuer":"http://idp.example","authorization_endpoint":"http://idp.example/auth","token_endpoint":"http://idp.example/token"}"#
        XCTAssertThrowsError(try OIDCDiscovery.parse(Data(json.utf8))) { err in
            guard case OIDCAuthFailure.discoveryFailed = err else {
                return XCTFail("expected discoveryFailed, got \(err)")
            }
        }
    }
    func test_discovery_http_loopback_endpoint_parses() throws {
        let json = #"{"issuer":"http://localhost:8080","authorization_endpoint":"http://localhost:8080/auth","token_endpoint":"http://localhost:8080/token"}"#
        let d = try OIDCDiscovery.parse(Data(json.utf8))
        XCTAssertEqual(d.authorizationEndpoint.absoluteString, "http://localhost:8080/auth")
        XCTAssertEqual(d.tokenEndpoint.absoluteString, "http://localhost:8080/token")
    }
    func test_discovery_http_ipv6_loopback_endpoint_parses() throws {
        // ::1 is the IPv6 loopback; plain HTTP must be accepted just like 127.0.0.1.
        let json = #"{"issuer":"http://[::1]:8080","authorization_endpoint":"http://[::1]:8080/auth","token_endpoint":"http://[::1]:8080/token"}"#
        let d = try OIDCDiscovery.parse(Data(json.utf8))
        XCTAssertEqual(d.authorizationEndpoint.absoluteString, "http://[::1]:8080/auth")
        XCTAssertEqual(d.tokenEndpoint.absoluteString, "http://[::1]:8080/token")
    }
    func test_discovery_missing_token_endpoint_throws_discoveryFailed() {
        let json = #"{"issuer":"https://idp.example","authorization_endpoint":"https://idp.example/auth"}"#
        XCTAssertThrowsError(try OIDCDiscovery.parse(Data(json.utf8))) { err in
            guard case OIDCAuthFailure.discoveryFailed = err else {
                return XCTFail("expected discoveryFailed, got \(err)")
            }
        }
    }
    func test_token_response_parses_with_and_without_rotated_refresh() throws {
        let rotated = #"{"access_token":"at","id_token":"idt","refresh_token":"rt2","expires_in":3600}"#
        let r1 = try OIDCTokenResponse.parse(Data(rotated.utf8))
        XCTAssertEqual(r1.idToken, "idt"); XCTAssertEqual(r1.refreshToken, "rt2")
        let unrotated = #"{"access_token":"at","id_token":"idt","expires_in":3600}"#
        XCTAssertNil(try OIDCTokenResponse.parse(Data(unrotated.utf8)).refreshToken)
    }
    func test_identity_decodes_from_idtoken_claims() throws {
        // Unsigned JWT payload (we never validate signatures — the clouds do).
        let claims = #"{"sub":"u123","email":"jon@acme.com","name":"Jon","iat":1700000000}"#
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJSUzI1NiJ9.\(payload).sig"
        let id = try OIDCIdentity.from(idToken: jwt, issuer: "https://idp.example", clientID: "c1")
        XCTAssertEqual(id.sub, "u123"); XCTAssertEqual(id.email, "jon@acme.com")
    }
    func test_taxonomy_user_copy_is_nonempty_and_logsafe() {
        let cases: [OIDCAuthFailure] = [
            .discoveryFailed(detail: "dns"), .signInCancelled,
            .sessionExpired(code: "invalid_grant"), .rotationLost,
            .exchangeDenied(leg: .aws, detail: "trust"), .exchangeDenied(leg: .gcp, detail: "aud"),
            .providerDenied(detail: "no invoke"),
            .callbackInvalid,
            .idpRejected(code: "invalid_request", detail: "invalid_scope"),
            .signInUnavailable(detail: "another sign-in active"),
            .refreshTokenMissing,
            .scopeNotGranted(missing: ["https://www.googleapis.com/auth/cloud-platform"]),
        ]
        for c in cases where !c.isSilent {
            XCTAssertFalse(c.userCopy.isEmpty, "\(c)")
            XCTAssertFalse(c.logLine.contains("@"), "log line must never carry identity: \(c)")
        }
        XCTAssertTrue(OIDCAuthFailure.signInCancelled.isSilent)
        // callbackInvalid: not silent, user copy must not imply session expiry,
        // logLine must be "oidc state=callbackInvalid".
        XCTAssertFalse(OIDCAuthFailure.callbackInvalid.isSilent)
        XCTAssertEqual(OIDCAuthFailure.callbackInvalid.logLine, "oidc state=callbackInvalid")
        XCTAssertFalse(OIDCAuthFailure.callbackInvalid.userCopy.contains("Signed out"),
                       "callbackInvalid userCopy must not imply session expiry")
        // signInUnavailable: not silent; logLine is code-only; doctorDetail
        // passes through the supplied detail.
        XCTAssertFalse(OIDCAuthFailure.signInUnavailable(detail: "x").isSilent)
        XCTAssertEqual(OIDCAuthFailure.signInUnavailable(detail: "x").logLine,
                       "oidc state=signInUnavailable")
        XCTAssertEqual(OIDCAuthFailure.signInUnavailable(detail: "boom").doctorDetail, "boom")
        // refreshTokenMissing: not silent; precise IT-facing doctorDetail and
        // code-only logLine; userCopy points at the offline_access scope.
        XCTAssertFalse(OIDCAuthFailure.refreshTokenMissing.isSilent)
        XCTAssertEqual(OIDCAuthFailure.refreshTokenMissing.logLine, "oidc state=refreshTokenMissing")
        XCTAssertTrue(OIDCAuthFailure.refreshTokenMissing.doctorDetail.contains("offline_access"))
        XCTAssertTrue(OIDCAuthFailure.refreshTokenMissing.userCopy.contains("offline access"))
        XCTAssertFalse(OIDCAuthFailure.refreshTokenMissing.userCopy.isEmpty)
        // idpRejected: not silent; logLine carries only the machine `code`, NEVER
        // the IdP-controlled `detail` prose; doctorDetail combines code + detail.
        let idpRej = OIDCAuthFailure.idpRejected(code: "invalid_request", detail: "invalid_scope")
        XCTAssertFalse(idpRej.isSilent)
        XCTAssertEqual(idpRej.logLine, "oidc state=idpRejected code=invalid_request")
        XCTAssertFalse(idpRej.logLine.contains("invalid_scope"),
                       "idpRejected logLine must never carry the IdP detail prose")
        XCTAssertEqual(idpRej.doctorDetail, "invalid_request: invalid_scope")
        XCTAssertEqual(OIDCAuthFailure.idpRejected(code: "access_denied", detail: "").doctorDetail,
                       "access_denied", "empty detail falls back to the bare code")
        XCTAssertFalse(idpRej.userCopy.isEmpty)
        XCTAssertFalse(idpRej.userCopy.contains("Signed out"),
                       "idpRejected userCopy must not imply session expiry")
        // scopeNotGranted: not silent; logLine carries the (config-derived, so
        // log-safe) missing scope names; userCopy + doctorDetail name them too.
        let scopeFail = OIDCAuthFailure.scopeNotGranted(
            missing: ["https://www.googleapis.com/auth/cloud-platform"])
        XCTAssertFalse(scopeFail.isSilent)
        XCTAssertEqual(scopeFail.logLine,
                       "oidc state=scopeNotGranted missing=https://www.googleapis.com/auth/cloud-platform")
        XCTAssertTrue(scopeFail.userCopy.contains("cloud-platform"))
        XCTAssertTrue(scopeFail.doctorDetail.contains("granular-consent"))
        XCTAssertFalse(scopeFail.userCopy.contains("Signed out"),
                       "scopeNotGranted userCopy must not imply session expiry")
    }
    func test_token_response_missing_fields_throws_sessionExpired() {
        XCTAssertThrowsError(try OIDCTokenResponse.parse(Data(#"{"expires_in":3600}"#.utf8))) { err in
            guard case OIDCAuthFailure.sessionExpired = err else { return XCTFail("\(err)") }
        }
    }
    func test_discovery_http_non_loopback_revocation_endpoint_throws_discoveryFailed() {
        // Auth + token are HTTPS-valid, but revocation_endpoint is plain HTTP on a
        // non-loopback host — a tampered discovery doc could exfiltrate the refresh
        // token POSTed there by signOut(). Must throw discoveryFailed.
        let json = #"{"issuer":"https://idp.example","authorization_endpoint":"https://idp.example/auth","token_endpoint":"https://idp.example/token","revocation_endpoint":"http://evil.example/revoke"}"#
        XCTAssertThrowsError(try OIDCDiscovery.parse(Data(json.utf8))) { err in
            guard case OIDCAuthFailure.discoveryFailed = err else {
                return XCTFail("expected discoveryFailed, got \(err)")
            }
        }
    }
    func test_discovery_http_loopback_revocation_endpoint_parses() throws {
        // http://localhost revocation endpoint is acceptable (in-repo Keycloak dev rig).
        let json = #"{"issuer":"http://localhost:8080","authorization_endpoint":"http://localhost:8080/auth","token_endpoint":"http://localhost:8080/token","revocation_endpoint":"http://localhost:8080/revoke"}"#
        let d = try OIDCDiscovery.parse(Data(json.utf8))
        XCTAssertEqual(d.revocationEndpoint?.absoluteString, "http://localhost:8080/revoke")
    }
    func test_discovery_http_ipv6_loopback_revocation_endpoint_parses() throws {
        // ::1 is the IPv6 loopback; a plain-HTTP revocation endpoint there must be
        // accepted just like http://localhost — completing the loopback matrix
        // (the auth/token IPv6-loopback case is covered above).
        let json = #"{"issuer":"http://[::1]:8080","authorization_endpoint":"http://[::1]:8080/auth","token_endpoint":"http://[::1]:8080/token","revocation_endpoint":"http://[::1]:8080/revoke"}"#
        let d = try OIDCDiscovery.parse(Data(json.utf8))
        XCTAssertEqual(d.revocationEndpoint?.absoluteString, "http://[::1]:8080/revoke")
    }
    func test_clock_skew_detection() {
        // iat 10 minutes in the future vs a fixed 'now'
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let skew = OIDCAuthFailure.clockSkewSeconds(tokenIat: now.addingTimeInterval(600), now: now)
        XCTAssertEqual(skew, 600)
    }
}
