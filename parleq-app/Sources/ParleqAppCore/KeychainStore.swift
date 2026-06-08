// KeychainStore — thin wrapper around the macOS Keychain Services
// API for storing a single password-class secret per account name.
//
// Used for every provider secret Parleq needs: Gemini API key,
// Bedrock API key, AWS static IAM credentials, Vertex service-
// account JSON, Azure resource API key. Settings UI is the
// canonical writer. There is no plaintext-on-disk fallback — see
// docs/SECURITY_REVIEW.md.
//
// Threat model: protects against plaintext-on-disk leaks and the
// "anyone with read access to my home dir can grep my keys" class
// of mistake. Doesn't protect against malware running as the user
// (it would just call `SecItemCopyMatching` itself), but neither
// does any per-user secret store on macOS — that's TCC's job, not
// the Keychain's.

import Foundation
import Security

/// Singleton-ish helper. Service identifier matches the app's
/// bundle ID convention; account identifies which secret within
/// the service.
public enum KeychainStore {
    /// Service tag used for every Parleq-owned Keychain item. Per
    /// Apple HIG, services are coarse application identities;
    /// distinct secrets live as different `account` values under
    /// the same service.
    private static let service = "com.parleq.app"

    /// Account name for the Gemini direct API key. If we add
    /// other secrets later (per #21: Bedrock API keys, AWS static
    /// access keys, Vertex AI service-account JSON, Azure OpenAI
    /// resource keys), each gets its own account string under the
    /// same service.
    public static let geminiAPIKeyAccount = "gemini-api-key"

    /// Account name for AWS static credentials when the user has
    /// chosen "static credentials" as the Bedrock auth mode (#21
    /// step 3). The stored value is a JSON blob containing the
    /// access key id, secret access key, and an optional session
    /// token, kept under a single Keychain item rather than three
    /// separate ones.
    public static let awsStaticCredentialsAccount = "aws-static-credentials"

    /// Account name for the AWS Bedrock API key when the user has
    /// chosen Bearer-token auth (#22). Bedrock API keys are scoped
    /// to Bedrock specifically (no broader IAM permissions) and
    /// don't require IAM policy understanding from the user —
    /// they're the recommended new-user path. Stored as a single
    /// opaque string.
    public static let bedrockAPIKeyAccount = "bedrock-api-key"

    /// Account name for the Azure OpenAI resource API key
    /// (#21 step 5). The user creates an OpenAI resource in their
    /// Azure subscription, copies the resource key from the
    /// "Keys and Endpoint" page in the Azure portal, and pastes
    /// it into Settings. Stored as a single string.
    public static let azureAPIKeyAccount = "azure-openai-key"

    /// Account name for the Vertex AI service-account JSON
    /// (#23). Whole JSON file content stored as a single string —
    /// the SA's email, project, and PEM private key all live
    /// inside. Stored intact so the user can verify what's
    /// configured and rotate atomically rather than dealing with
    /// the private key separately from its metadata.
    public static let vertexServiceAccountJSONAccount = "vertex-service-account-json"

    /// Account name for the OpenAI direct API key (#33). The user
    /// creates an API key at platform.openai.com → API keys and
    /// pastes it into Settings. Stored as a single opaque string.
    public static let openAIAPIKeyAccount = "openai-api-key"

    /// Account name for the OIDC refresh token (enterprise federation).
    /// The long-lived refresh token minted during corporate sign-in;
    /// rotated tokens overwrite the prior value. Stored as a single
    /// opaque string — never written to config.json or any plain file.
    public static let oidcRefreshTokenAccount = "oidc-refresh-token"

    /// Account name for the OIDC identity snapshot (enterprise
    /// federation). A JSON-encoded `OIDCIdentity` (issuer, client id,
    /// sub, email, name, obtainedAt) used for display/attribution only.
    /// Stored in the Keychain — NOT config.json — so the email/name PII
    /// never lands in a plaintext file.
    public static let oidcIdentityAccount = "oidc-identity"

    /// Account name for the OIDC client secret (enterprise federation).
    /// OPTIONAL — needed ONLY for Google "Desktop app" OAuth clients, which
    /// REQUIRE a client_secret on the token exchange even with PKCE (the
    /// installed-app secret is public-by-design per Google's own docs; the iOS
    /// client type has no secret, which is why the custom-scheme flow never
    /// needed one). This is CLIENT CONFIGURATION, not a user credential —
    /// unlike the refresh token + identity, it is NOT cleared on sign-out
    /// (KeychainOIDCTokenStore.clear() leaves it intact); it lives or dies with
    /// the issuer / client-ID config the IT admin entered. Kept in the Keychain
    /// (not config.json) anyway: it's a secret-shaped value and the Settings UI
    /// is the canonical writer for all such values, never displayed after save.
    public static let oidcClientSecretAccount = "oidc-client-secret"

    // MARK: - Public API

    /// Store the user's Gemini API key. Replaces any prior value
    /// for the same account. Returns true on success, false on
    /// any Keychain error (logged to stderr for debugging).
    @discardableResult
    public static func setGeminiAPIKey(_ key: String) -> Bool {
        set(account: geminiAPIKeyAccount, value: key)
    }

    /// Read the stored Gemini API key, or nil if none is set.
    public static func readGeminiAPIKey() -> String? {
        read(account: geminiAPIKeyAccount)
    }

    /// Delete the stored Gemini API key. Returns true if removed
    /// or already absent; false on a real Keychain error.
    @discardableResult
    public static func removeGeminiAPIKey() -> Bool {
        delete(account: geminiAPIKeyAccount)
    }

    /// Convenience predicate the Settings UI uses to show
    /// "stored in Keychain" vs "Set Gemini API Key" without
    /// putting the secret value in memory.
    public static var hasGeminiAPIKey: Bool {
        readGeminiAPIKey() != nil
    }

    // MARK: - AWS static credentials (#21 step 3)

    /// Triple of (access key id, secret access key, session token)
    /// returned from the Keychain when AWS static-credential mode is
    /// configured. Session token is optional — only present for
    /// short-lived STS-issued credentials. For long-lived IAM user
    /// access keys, sessionToken is nil.
    public struct AWSStaticCredentials: Equatable {
        var accessKeyId: String
        var secretAccessKey: String
        var sessionToken: String?
    }

    /// Persist an AWS access key id + secret + optional session token
    /// to the Keychain. JSON-encoded under a single account so the
    /// three values rotate together. Returns true on success.
    @discardableResult
    public static func setAWSStaticCredentials(_ creds: AWSStaticCredentials) -> Bool {
        let payload: [String: String?] = [
            "accessKeyId": creds.accessKeyId,
            "secretAccessKey": creds.secretAccessKey,
            "sessionToken": creds.sessionToken,
        ]
        let cleaned = payload.compactMapValues { $0 }
        guard let json = try? JSONSerialization.data(withJSONObject: cleaned),
              let asString = String(data: json, encoding: .utf8) else {
            return false
        }
        return set(account: awsStaticCredentialsAccount, value: asString)
    }

    /// Read AWS static credentials from the Keychain. Returns nil
    /// when none are stored or the stored payload is corrupt — in
    /// the corruption case we log and remove the bad item so the
    /// next set() lands cleanly.
    public static func readAWSStaticCredentials() -> AWSStaticCredentials? {
        guard let raw = read(account: awsStaticCredentialsAccount),
              let data = raw.data(using: .utf8) else {
            return nil
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            logKeychainError("decode aws-static-credentials (corrupt JSON; removing)", status: errSecDecode)
            _ = delete(account: awsStaticCredentialsAccount)
            return nil
        }
        guard let id = parsed["accessKeyId"],
              let secret = parsed["secretAccessKey"] else {
            return nil
        }
        return AWSStaticCredentials(
            accessKeyId: id,
            secretAccessKey: secret,
            sessionToken: parsed["sessionToken"]
        )
    }

    /// Remove the stored AWS static credentials. Returns true if
    /// removed or already absent.
    @discardableResult
    public static func removeAWSStaticCredentials() -> Bool {
        delete(account: awsStaticCredentialsAccount)
    }

    /// Settings-UI predicate. Doesn't materialize the secret values
    /// in memory; only checks whether the Keychain item exists.
    public static var hasAWSStaticCredentials: Bool {
        readAWSStaticCredentials() != nil
    }

    // MARK: - AWS Bedrock API key (#22)

    @discardableResult
    public static func setBedrockAPIKey(_ key: String) -> Bool {
        set(account: bedrockAPIKeyAccount, value: key)
    }

    public static func readBedrockAPIKey() -> String? {
        read(account: bedrockAPIKeyAccount)
    }

    @discardableResult
    public static func removeBedrockAPIKey() -> Bool {
        delete(account: bedrockAPIKeyAccount)
    }

    /// Settings-UI predicate. Doesn't materialize the secret value.
    public static var hasBedrockAPIKey: Bool {
        readBedrockAPIKey() != nil
    }

    // MARK: - Azure OpenAI API key (#21 step 5)

    @discardableResult
    public static func setAzureAPIKey(_ key: String) -> Bool {
        set(account: azureAPIKeyAccount, value: key)
    }

    public static func readAzureAPIKey() -> String? {
        read(account: azureAPIKeyAccount)
    }

    @discardableResult
    public static func removeAzureAPIKey() -> Bool {
        delete(account: azureAPIKeyAccount)
    }

    /// Settings-UI predicate. Doesn't materialize the secret value.
    public static var hasAzureAPIKey: Bool {
        readAzureAPIKey() != nil
    }

    // MARK: - Vertex AI service-account JSON (#23)

    @discardableResult
    public static func setVertexServiceAccountJSON(_ json: String) -> Bool {
        set(account: vertexServiceAccountJSONAccount, value: json)
    }

    public static func readVertexServiceAccountJSON() -> String? {
        read(account: vertexServiceAccountJSONAccount)
    }

    @discardableResult
    public static func removeVertexServiceAccountJSON() -> Bool {
        delete(account: vertexServiceAccountJSONAccount)
    }

    /// Settings-UI predicate. Doesn't materialize the JSON content.
    public static var hasVertexServiceAccountJSON: Bool {
        readVertexServiceAccountJSON() != nil
    }

    // MARK: - OpenAI direct API key (#33)

    @discardableResult
    public static func setOpenAIAPIKey(_ key: String) -> Bool {
        set(account: openAIAPIKeyAccount, value: key)
    }

    public static func readOpenAIAPIKey() -> String? {
        read(account: openAIAPIKeyAccount)
    }

    @discardableResult
    public static func removeOpenAIAPIKey() -> Bool {
        delete(account: openAIAPIKeyAccount)
    }

    /// Settings-UI predicate. Doesn't materialize the secret value.
    public static var hasOpenAIAPIKey: Bool {
        readOpenAIAPIKey() != nil
    }

    // MARK: - OIDC (enterprise federation)

    @discardableResult
    public static func setOIDCRefreshToken(_ token: String) -> Bool {
        set(account: oidcRefreshTokenAccount, value: token)
    }

    @discardableResult
    public static func removeOIDCRefreshToken() -> Bool {
        delete(account: oidcRefreshTokenAccount)
    }

    /// Part of the uniform set/remove/has surface; not yet consumed —
    /// the Company Account UI reads session state from OIDCSessionModel instead.
    /// Reads the token to memory momentarily but does not expose it to callers.
    public static var hasOIDCRefreshToken: Bool {
        readOIDCRefreshToken() != nil
    }

    public static func readOIDCRefreshToken() -> String? {
        read(account: oidcRefreshTokenAccount)
    }

    @discardableResult
    public static func setOIDCIdentityJSON(_ json: String) -> Bool {
        set(account: oidcIdentityAccount, value: json)
    }

    @discardableResult
    public static func removeOIDCIdentityJSON() -> Bool {
        delete(account: oidcIdentityAccount)
    }

    public static func readOIDCIdentityJSON() -> String? {
        read(account: oidcIdentityAccount)
    }

    /// Part of the uniform set/remove/has surface; not yet consumed —
    /// the Company Account UI reads session state from OIDCSessionModel instead.
    /// Reads the identity JSON to memory momentarily but does not expose it to callers.
    public static var hasOIDCIdentityJSON: Bool {
        readOIDCIdentityJSON() != nil
    }

    // MARK: - OIDC client secret (Google "Desktop app" clients)
    //
    // CLIENT CONFIGURATION, not a user credential: it survives sign-out
    // (KeychainOIDCTokenStore.clear() deliberately does NOT touch it — see the
    // account-constant doc above). Same service / accessibility class as the
    // refresh-token accessors.
    //
    // OWNERSHIP STAMP (fix #57): the secret is stored as a JSON envelope that
    // records the client_id + issuer it was saved against, NOT a bare string.
    // The reader returns the secret ONLY when the stamped owner matches the
    // currently-configured client_id + issuer; on a mismatch it deletes the
    // stale item and returns nil. This stops a secret saved for client A from
    // being transmitted to a DIFFERENT IdP after the admin reconfigures the
    // issuer / client_id (which would both break the new exchange AND leak the
    // prior client's secret to another endpoint). Switching clients is a
    // CONFIG change, distinct from sign-out — sign-out still keeps the secret.
    // Neither the secret nor the stamp is ever logged.

    /// JSON envelope persisted under `oidcClientSecretAccount`. The owner fields
    /// scope the secret to one client config; only `secret` is the sensitive
    /// value (the owner is non-secret config already present in config.json).
    struct OIDCClientSecretEnvelope: Codable {
        var clientID: String
        var issuer: String
        var secret: String
    }

    /// The action `readOIDCClientSecret` should take for a stored raw value and
    /// a requested owner. Split out as a PURE function so the owner-matching /
    /// migration logic (the fix #57 core) is unit-testable without the real
    /// Keychain. `none` means "no value stored / nothing to do".
    enum OIDCClientSecretDecision: Equatable {
        /// Stamped envelope whose owner matches → return this secret, no write.
        case useStamped(String)
        /// Stamped envelope whose owner DIFFERS → delete the stale item, nil.
        case deleteStale
        /// Legacy bare-string value → re-stamp it for the requested owner
        /// (one-time migration) and return it.
        case migrateLegacy(String)
        /// No stored value.
        case none
    }

    /// Pure decision for the stored `raw` value (nil = absent) given the
    /// requested owner. No I/O — see `readOIDCClientSecret` for the I/O wrapper.
    static func oidcClientSecretDecision(raw: String?,
                                         clientID: String,
                                         issuer: String) -> OIDCClientSecretDecision {
        guard let raw else { return .none }
        if let data = raw.data(using: .utf8),
           let env = try? JSONDecoder().decode(OIDCClientSecretEnvelope.self, from: data) {
            guard env.clientID == clientID, env.issuer == issuer else { return .deleteStale }
            return .useStamped(env.secret)
        }
        // Not a stamped envelope → legacy bare string written before this fix.
        return .migrateLegacy(raw)
    }

    /// Persist the OIDC client secret stamped with the client_id + issuer it
    /// belongs to. Replaces any prior value (including a legacy bare-string one).
    @discardableResult
    public static func setOIDCClientSecret(_ secret: String,
                                           forClientID clientID: String,
                                           issuer: String) -> Bool {
        let envelope = OIDCClientSecretEnvelope(clientID: clientID, issuer: issuer, secret: secret)
        guard let data = try? JSONEncoder().encode(envelope),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        return set(account: oidcClientSecretAccount, value: json)
    }

    /// Read the OIDC client secret IF it belongs to the given client_id + issuer.
    ///
    /// - Stamped envelope, owner matches → returns the secret.
    /// - Stamped envelope, owner DIFFERS → deletes the stale item, returns nil
    ///   (so a reconfigured client never ships the prior client's secret).
    /// - Legacy bare-string value (written before this fix) → adopted by the
    ///   current client: re-stamped in place with this owner and returned. A
    ///   single-client install (the common case) keeps working; a later client
    ///   switch then hits the mismatch path and clears it.
    public static func readOIDCClientSecret(forClientID clientID: String,
                                            issuer: String) -> String? {
        let raw = read(account: oidcClientSecretAccount)
        switch oidcClientSecretDecision(raw: raw, clientID: clientID, issuer: issuer) {
        case .none:
            return nil
        case .useStamped(let secret):
            return secret
        case .deleteStale:
            _ = delete(account: oidcClientSecretAccount)
            return nil
        case .migrateLegacy(let secret):
            _ = setOIDCClientSecret(secret, forClientID: clientID, issuer: issuer)
            return secret
        }
    }

    @discardableResult
    public static func removeOIDCClientSecret() -> Bool {
        delete(account: oidcClientSecretAccount)
    }

    /// Settings-UI predicate: is a secret stored FOR THE GIVEN client config?
    /// Owner-aware so the UI badge reflects the current client, not a secret
    /// left over from a different one. Doesn't expose the secret value.
    public static func hasOIDCClientSecret(forClientID clientID: String, issuer: String) -> Bool {
        readOIDCClientSecret(forClientID: clientID, issuer: issuer) != nil
    }

    // MARK: - Internals

    private static func set(account: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Always delete-then-add. Apple's recommended
        // SecItemUpdate path requires a precise query; for our
        // single-item-per-account shape the delete+add pattern
        // sidesteps "duplicate item" cases cleanly.
        _ = delete(account: account)
        let attrs: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecValueData as String:    data,
            // Available after first unlock — match Login Items
            // behavior so a Parleq autostart doesn't fail to
            // resolve the key on a freshly-booted machine before
            // any GUI login.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            logKeychainError("set \(account)", status: status)
            return false
        }
        return true
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account,
            kSecMatchLimit as String:      kSecMatchLimitOne,
            kSecReturnData as String:      true as CFBoolean,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            logKeychainError("read \(account)", status: status)
            return nil
        }
    }

    private static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return true
        default:
            logKeychainError("delete \(account)", status: status)
            return false
        }
    }

    private static func logKeychainError(_ operation: String, status: OSStatus) {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        let line = "[parleq] keychain: \(operation) failed: \(msg)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }
}

/// KeychainStore-backed `OIDCTokenStore`. Identity is stored as JSON in
/// the Keychain — NOT config.json — so the email/name PII never lands in
/// a plain file. The refresh token is the long-lived federation secret;
/// rotated tokens overwrite the prior value.
public struct KeychainOIDCTokenStore: OIDCTokenStore {
    /// The client_id + issuer the live session is configured for. Used to scope
    /// the OPTIONAL client secret to its owning client (fix #57): the secret is
    /// returned only when its stored owner matches these. Empty strings (the
    /// default) mean "no client configured" — `oidcClientSecret()` then always
    /// returns nil, which is correct (no token call is made without a client).
    private let clientID: String
    private let issuer: String
    public init(clientID: String = "", issuer: String = "") {
        self.clientID = clientID
        self.issuer = issuer
    }
    public func loadRefreshToken() -> String? { KeychainStore.readOIDCRefreshToken() }
    @discardableResult
    public func saveRefreshToken(_ token: String) -> Bool { KeychainStore.setOIDCRefreshToken(token) }
    public func loadIdentity() -> OIDCIdentity? {
        guard let json = KeychainStore.readOIDCIdentityJSON(),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OIDCIdentity.self, from: data)
    }
    @discardableResult
    public func saveIdentity(_ identity: OIDCIdentity) -> Bool {
        guard let data = try? JSONEncoder().encode(identity),
              let json = String(data: data, encoding: .utf8) else { return false }
        return KeychainStore.setOIDCIdentityJSON(json)
    }
    /// The OAuth client secret for Google "Desktop app" clients (optional; nil
    /// for every other client type). Read fresh from the Keychain on each token
    /// call so a Settings change takes effect without re-instantiating the
    /// session. Owner-scoped (fix #57): returns the secret ONLY when it was
    /// saved for this store's configured client_id + issuer, so a reconfigured
    /// client never ships a stale secret to a different IdP.
    public func oidcClientSecret() -> String? {
        KeychainStore.readOIDCClientSecret(forClientID: clientID, issuer: issuer)
    }
    /// Sign-out teardown. Clears ONLY the user-credential pair (refresh token +
    /// identity). The client secret is CLIENT CONFIGURATION (like the issuer and
    /// client ID), not a user credential, so it deliberately SURVIVES sign-out —
    /// signing out then back in must not lose the IT-entered Desktop-client
    /// secret. It is removed only when the user explicitly clears it in Settings.
    public func clear() {
        _ = KeychainStore.removeOIDCRefreshToken()
        _ = KeychainStore.removeOIDCIdentityJSON()
    }
}
