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
    public init() {}
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
    public func clear() {
        _ = KeychainStore.removeOIDCRefreshToken()
        _ = KeychainStore.removeOIDCIdentityJSON()
    }
}
