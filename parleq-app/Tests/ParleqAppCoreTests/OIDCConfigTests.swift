import XCTest
@testable import ParleqAppCore

final class OIDCConfigTests: XCTestCase {
    func test_oidc_section_round_trips() throws {
        var c = Config.defaults
        c.oidcIssuer = "https://acme.okta.com"; c.oidcClientID = "0oa1"
        c.oidcScopes = ["openid", "email"]; c.oidcEphemeralBrowser = true
        c.awsRoleArn = "arn:aws:iam::1:role/Parleq"; c.awsSessionDurationSeconds = 7200
        c.vertexWorkforceProvider = "locations/global/workforcePools/a/providers/b"
        c.awsAuthMode = "oidc"; c.vertexAuthMode = "oidcFederation"
        let dict = Config.serializeToDictionary(c)
        let parsed = Config.parse(fromDictionary: dict)
        XCTAssertEqual(parsed.oidcIssuer, c.oidcIssuer)
        XCTAssertEqual(parsed.oidcClientID, c.oidcClientID)
        XCTAssertEqual(parsed.oidcScopes, c.oidcScopes)
        XCTAssertTrue(parsed.oidcEphemeralBrowser)
        XCTAssertEqual(parsed.awsRoleArn, c.awsRoleArn)
        XCTAssertEqual(parsed.awsSessionDurationSeconds, 7200)
        XCTAssertEqual(parsed.vertexWorkforceProvider, c.vertexWorkforceProvider)
        XCTAssertEqual(parsed.awsAuthMode, "oidc")
        XCTAssertEqual(parsed.vertexAuthMode, "oidcFederation")
    }
    /// Addendum 2: the Vertex "googleOAuth" auth mode round-trips through
    /// serialize → parse. No new keys — it reuses the shared OIDC section
    /// (issuer/client ID/scopes) and the vertex project; there is NO
    /// workforce provider (no federation hop).
    func test_vertex_googleOAuth_auth_mode_round_trips() {
        var c = Config.defaults
        c.oidcIssuer = "https://accounts.google.com"
        c.oidcClientID = "1234.apps.googleusercontent.com"
        c.oidcScopes = ["openid", "email", "https://www.googleapis.com/auth/cloud-platform"]
        c.vertexProject = "my-gcp-project"
        c.vertexAuthMode = "googleOAuth"
        let parsed = Config.parse(fromDictionary: Config.serializeToDictionary(c))
        XCTAssertEqual(parsed.vertexAuthMode, "googleOAuth")
        XCTAssertEqual(parsed.oidcIssuer, c.oidcIssuer)
        XCTAssertEqual(parsed.oidcClientID, c.oidcClientID)
        XCTAssertEqual(parsed.oidcScopes, c.oidcScopes)
        XCTAssertEqual(parsed.vertexProject, c.vertexProject)
    }
    func test_defaults_omit_oidc_keys() {
        let dict = Config.serializeToDictionary(Config.defaults)
        XCTAssertNil(dict["oidc"])
        let aws = dict["aws"] as? [String: Any]
        XCTAssertNil(aws?["role_arn"]); XCTAssertNil(aws?["session_duration_seconds"])
        let vertex = dict["vertex"] as? [String: Any]
        XCTAssertNil(vertex?["workforce_provider"])
    }
    func test_session_duration_clamped() {
        var c = Config.defaults; c.awsSessionDurationSeconds = 10
        let parsed = Config.parse(fromDictionary: Config.serializeToDictionary(c))
        XCTAssertEqual(parsed.awsSessionDurationSeconds, 900, "below STS minimum clamps to 900")
    }
    func test_session_duration_clamped_upper_bound() {
        var c = Config.defaults; c.awsSessionDurationSeconds = 50000
        let parsed = Config.parse(fromDictionary: Config.serializeToDictionary(c))
        XCTAssertEqual(parsed.awsSessionDurationSeconds, 43200, "above STS maximum clamps to 43200")
    }
    func test_managed_keys_include_oidc_set() {
        for key in ["oidcIssuer", "oidcClientID", "oidcScopes", "oidcEphemeralBrowserSession",
                    "oidcRedirectURI", "oidcExtraAuthParams",
                    "awsRoleArn", "awsSessionDurationSeconds", "vertexWorkforceProvider"] {
            XCTAssertTrue(ManagedConfig.allKeys.contains(key), key)
        }
    }

    // MARK: - Generic-OP knobs: redirect_uri + extra_auth_params

    func test_redirect_uri_and_extra_auth_params_round_trip() {
        var c = Config.defaults
        c.oidcIssuer = "https://accounts.google.com"
        c.oidcClientID = "1234.apps.googleusercontent.com"
        c.oidcRedirectURI = "com.googleusercontent.apps.1234:/oauth2redirect"
        c.oidcExtraAuthParams = ["access_type": "offline", "prompt": "consent"]
        let dict = Config.serializeToDictionary(c)
        let oidc = dict["oidc"] as? [String: Any]
        XCTAssertEqual(oidc?["redirect_uri"] as? String, c.oidcRedirectURI)
        XCTAssertEqual(oidc?["extra_auth_params"] as? [String: String], c.oidcExtraAuthParams)
        let parsed = Config.parse(fromDictionary: dict)
        XCTAssertEqual(parsed.oidcRedirectURI, c.oidcRedirectURI)
        XCTAssertEqual(parsed.oidcExtraAuthParams, c.oidcExtraAuthParams)
    }

    /// Default values for both new keys must be OMITTED from the serialized
    /// dict — a config that only sets issuer/client_id must not write a
    /// redirect_uri or extra_auth_params key.
    func test_default_redirect_uri_and_empty_extra_params_are_omitted() {
        var c = Config.defaults
        c.oidcIssuer = "https://acme.okta.com"; c.oidcClientID = "0oa1"
        let dict = Config.serializeToDictionary(c)
        let oidc = dict["oidc"] as? [String: Any]
        XCTAssertNotNil(oidc, "issuer/client_id set → oidc section present")
        XCTAssertNil(oidc?["redirect_uri"], "default redirect_uri must be omitted")
        XCTAssertNil(oidc?["extra_auth_params"], "empty extra_auth_params must be omitted")
    }

    /// A redirect_uri without a parseable scheme is rejected at parse time —
    /// the default value is kept (the callback scheme is derived from it, so a
    /// schemeless value would silently break browser interception).
    func test_redirect_uri_without_scheme_is_rejected() {
        let dict: [String: Any] = ["oidc": ["redirect_uri": "no-scheme-here"]]
        let parsed = Config.parse(fromDictionary: dict)
        XCTAssertEqual(parsed.oidcRedirectURI, Config.default.oidcRedirectURI,
                       "schemeless redirect_uri must keep the default")
    }

    /// An http(s):// redirect_uri is rejected at parse time — the custom-scheme
    /// callback can never intercept an http(s) URL, so it would fail opaquely at
    /// sign-in. The default value is kept.
    func test_https_redirect_uri_is_rejected() {
        let dict: [String: Any] = ["oidc": ["redirect_uri": "https://example.com/callback"]]
        let parsed = Config.parse(fromDictionary: dict)
        XCTAssertEqual(parsed.oidcRedirectURI, Config.default.oidcRedirectURI,
                       "https redirect_uri must keep the default")
        let dict2: [String: Any] = ["oidc": ["redirect_uri": "http://localhost/callback"]]
        let parsed2 = Config.parse(fromDictionary: dict2)
        XCTAssertEqual(parsed2.oidcRedirectURI, Config.default.oidcRedirectURI,
                       "http redirect_uri must keep the default")
    }

    /// A custom-scheme redirect_uri is accepted at parse time.
    func test_custom_scheme_redirect_uri_is_accepted() {
        let dict: [String: Any] = ["oidc": ["redirect_uri": "parleq-auth://oidc/callback"]]
        XCTAssertEqual(Config.parse(fromDictionary: dict).oidcRedirectURI,
                       "parleq-auth://oidc/callback")
        let dict2: [String: Any] = ["oidc": ["redirect_uri": "com.googleusercontent.apps.1234:/oauth2redirect"]]
        XCTAssertEqual(Config.parse(fromDictionary: dict2).oidcRedirectURI,
                       "com.googleusercontent.apps.1234:/oauth2redirect")
    }

    /// An https:// issuer round-trips on the JSON path; an http:// non-loopback
    /// issuer is rejected (kept default) for parity with the MDM validator;
    /// http:// loopback (the Keycloak dev rig) is still accepted.
    func test_json_issuer_validation_parity() {
        let httpsDict: [String: Any] = ["oidc": ["issuer": "https://acme.okta.com"]]
        XCTAssertEqual(Config.parse(fromDictionary: httpsDict).oidcIssuer, "https://acme.okta.com")

        let badDict: [String: Any] = ["oidc": ["issuer": "http://attacker.example/realms/parleq"]]
        XCTAssertEqual(Config.parse(fromDictionary: badDict).oidcIssuer,
                       Config.default.oidcIssuer,
                       "http non-loopback issuer must keep the default")

        let loopbackDict: [String: Any] = ["oidc": ["issuer": "http://127.0.0.1:8080/realms/parleq"]]
        XCTAssertEqual(Config.parse(fromDictionary: loopbackDict).oidcIssuer,
                       "http://127.0.0.1:8080/realms/parleq",
                       "http loopback issuer (Keycloak dev rig) must still be accepted")
    }

    /// extra_auth_params with non-String values drops those entries.
    func test_extra_auth_params_drops_non_string_values() {
        let dict: [String: Any] = ["oidc": ["extra_auth_params": ["prompt": "consent", "n": 5]]]
        let parsed = Config.parse(fromDictionary: dict)
        XCTAssertEqual(parsed.oidcExtraAuthParams, ["prompt": "consent"])
    }

    /// Pinned-never-materialize for BOTH new keys: pinned + absent on disk
    /// must write nothing (no leak of org config onto the user's disk).
    func test_pinned_redirect_uri_and_extra_params_never_materialize_when_absent() {
        var c = Config.default
        c.oidcRedirectURI = "com.googleusercontent.apps.9:/oauth2redirect"
        c.oidcExtraAuthParams = ["prompt": "consent"]
        c.managedKeys = ["oidcRedirectURI", "oidcExtraAuthParams"]
        let existing: [String: Any] = [:]
        let merged = Config.mergeForSave(c, existing: existing)
        XCTAssertNil(merged["oidc"],
                     "pinned-but-absent redirect_uri + extra_auth_params must not materialize")
    }

    /// Counterpart: pinned + present on disk preserves the on-disk value.
    func test_pinned_redirect_uri_and_extra_params_preserve_existing_on_disk() {
        var c = Config.default
        c.oidcRedirectURI = "com.googleusercontent.apps.MANAGED:/oauth2redirect"
        c.oidcExtraAuthParams = ["prompt": "managed"]
        c.managedKeys = ["oidcRedirectURI", "oidcExtraAuthParams"]
        let existing: [String: Any] = [
            "oidc": [
                "redirect_uri": "com.googleusercontent.apps.USER:/oauth2redirect",
                "extra_auth_params": ["prompt": "consent", "access_type": "offline"],
            ],
        ]
        let merged = Config.mergeForSave(c, existing: existing)
        let oidc = merged["oidc"] as? [String: Any]
        XCTAssertEqual(oidc?["redirect_uri"] as? String,
                       "com.googleusercontent.apps.USER:/oauth2redirect",
                       "pinned-and-present redirect_uri preserves the on-disk value")
        XCTAssertEqual(oidc?["extra_auth_params"] as? [String: String],
                       ["prompt": "consent", "access_type": "offline"],
                       "pinned-and-present extra_auth_params preserves the on-disk value")
    }

    /// MDM-pinned OIDC-federation values must NEVER materialize onto disk.
    /// All seven org-config fields are pinned (managedKeys + effective managed
    /// values present in memory), but the existing on-disk dict has no oidc
    /// section / role_arn / workforce_provider. The merge that save() performs
    /// must leave those keys ABSENT — falling back to the effective managed
    /// value would write org config into ~/.parleq/config.json, where it would
    /// survive MDM-profile removal. Driven through mergeForSave() (the pure,
    /// disk-free core of save()) so no real config.json is touched.
    func test_pinned_oidc_values_never_materialize_when_absent_on_disk() {
        var c = Config.default
        // Effective managed values (as if the MDM overlay applied them).
        c.oidcIssuer = "https://acme.okta.com"
        c.oidcClientID = "0oa1managed"
        c.oidcScopes = ["openid", "email", "offline_access"]
        c.oidcEphemeralBrowser = true
        c.awsRoleArn = "arn:aws:iam::1:role/Parleq"
        c.awsSessionDurationSeconds = 7200
        c.vertexWorkforceProvider = "locations/global/workforcePools/a/providers/b"
        c.managedKeys = ["oidcIssuer", "oidcClientID", "oidcScopes",
                         "oidcEphemeralBrowserSession", "awsRoleArn",
                         "awsSessionDurationSeconds", "vertexWorkforceProvider"]
        // Existing on-disk dict has aws/vertex sections but NO oidc-federation
        // keys — the user never wrote them (the org pins them via MDM).
        let existing: [String: Any] = [
            "aws": ["region": "us-east-2", "profile": "", "auth_mode": "sso"],
            "vertex": ["project": "", "region": "us-central1", "auth_mode": "adc"],
        ]
        let merged = Config.mergeForSave(c, existing: existing)
        XCTAssertNil(merged["oidc"], "pinned-but-absent oidc section must not materialize")
        let aws = merged["aws"] as? [String: Any]
        XCTAssertNil(aws?["role_arn"], "pinned-but-absent role_arn must not materialize")
        XCTAssertNil(aws?["session_duration_seconds"],
                     "pinned-but-absent session_duration_seconds must not materialize")
        let vertex = merged["vertex"] as? [String: Any]
        XCTAssertNil(vertex?["workforce_provider"],
                     "pinned-but-absent workforce_provider must not materialize")
    }

    /// Counterpart: when a pinned field IS present on disk (the user's pre-MDM
    /// value), the merge preserves THAT on-disk value — not the effective
    /// managed value — so removing the MDM profile restores the user's choice.
    func test_pinned_oidc_values_preserve_existing_on_disk_value() {
        var c = Config.default
        c.oidcIssuer = "https://managed.okta.com"   // effective managed value
        c.awsRoleArn = "arn:aws:iam::9:role/Managed"
        c.managedKeys = ["oidcIssuer", "awsRoleArn"]
        let existing: [String: Any] = [
            "oidc": ["issuer": "https://user-prior.okta.com"],
            "aws": ["region": "us-east-2", "profile": "",
                    "auth_mode": "sso", "role_arn": "arn:aws:iam::1:role/UserPrior"],
        ]
        let merged = Config.mergeForSave(c, existing: existing)
        let oidc = merged["oidc"] as? [String: Any]
        XCTAssertEqual(oidc?["issuer"] as? String, "https://user-prior.okta.com",
                       "pinned-and-present issuer preserves the on-disk value, not the managed one")
        let aws = merged["aws"] as? [String: Any]
        XCTAssertEqual(aws?["role_arn"] as? String, "arn:aws:iam::1:role/UserPrior",
                       "pinned-and-present role_arn preserves the on-disk value")
    }
}
