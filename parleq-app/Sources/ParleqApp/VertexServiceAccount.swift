// VertexServiceAccount — JWT-based OAuth flow for Google Cloud
// service-account JSON keys (#23).
//
// A GCP service account is a non-human IAM principal with its own
// RSA key pair. Users who don't want to install gcloud (or want
// audit-logged, non-interactive auth) generate a JSON key file
// from the GCP IAM console and paste its contents into Parleq;
// VertexProvider then signs a short-lived JWT with the SA's
// private key and exchanges it at Google's token endpoint for an
// OAuth access token, the same shape of token gcloud itself
// produces. After that, the streaming-request path is identical
// to the gcloud-ADC mode.
//
// What's in this file:
//   1. ServiceAccountKey — strongly-typed view of the JSON's two
//      load-bearing fields (client_email + private_key). Other
//      fields (project_id, key_id, etc.) are decoded but not
//      needed for token minting.
//   2. JWT building + RSA-SHA256 signing via Apple's Security
//      framework. CryptoKit doesn't do RSA, so we go through
//      SecKey directly.
//   3. PKCS#8 → PKCS#1 unwrap. Service-account JSONs always ship
//      the private key in PKCS#8 PEM ("-----BEGIN PRIVATE KEY-----"),
//      but Apple's SecKeyCreateWithData wants PKCS#1 raw bytes for
//      the kSecAttrKeyTypeRSA + kSecAttrKeyClassPrivate combo.
//      A small ASN.1 walker strips the PrivateKeyInfo wrapper.
//   4. Token-exchange POST against https://oauth2.googleapis.com/token
//      with grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer.

import Foundation
import Security

/// Decoded view of a service-account JSON key file. Only the
/// fields we actually consume are exposed; the rest decode through
/// `extras` so a future iteration could surface, say, project_id
/// in an "auth status" affordance without re-parsing.
struct ServiceAccountKey: Decodable, Sendable {
    let type: String
    let projectId: String?
    let privateKeyId: String?
    let privateKey: String  // PEM-encoded PKCS#8
    let clientEmail: String
    let tokenUri: String?

    enum CodingKeys: String, CodingKey {
        case type
        case projectId = "project_id"
        case privateKeyId = "private_key_id"
        case privateKey = "private_key"
        case clientEmail = "client_email"
        case tokenUri = "token_uri"
    }

    /// Parse a raw service-account JSON string. Throws when the
    /// JSON is malformed or missing the load-bearing fields. The
    /// caller is expected to surface a friendly error to the user
    /// — most often "you pasted something that isn't a service-
    /// account JSON" or "this looks like a placeholder file."
    static func parse(_ json: String) throws -> ServiceAccountKey {
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "VertexServiceAccount", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "JSON is not valid UTF-8"])
        }
        let key = try JSONDecoder().decode(ServiceAccountKey.self, from: data)
        // Sanity checks — typed JSON decode passes on any object
        // with the right shape, so a placeholder/template file
        // would slip through. Verify it looks like a real key.
        guard key.type == "service_account" else {
            throw NSError(domain: "VertexServiceAccount", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "JSON 'type' is not 'service_account' (got '\(key.type)'); this isn't a service-account key file"])
        }
        guard !key.clientEmail.isEmpty else {
            throw NSError(domain: "VertexServiceAccount", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "JSON is missing 'client_email'"])
        }
        guard !key.privateKey.isEmpty else {
            throw NSError(domain: "VertexServiceAccount", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "JSON is missing 'private_key'"])
        }
        return key
    }
}

/// Mint an OAuth access token from a service-account key. Returns
/// the access_token string and its expires_in (seconds, as Google
/// reports it). The caller is expected to wrap this in a TTL cache
/// — see `VertexProvider`'s `TokenCache` actor for the shape.
///
/// Scope is fixed at `https://www.googleapis.com/auth/cloud-platform`
/// which is the broad scope Vertex AI requires; the SA's IAM role
/// (Vertex AI User, etc.) is what actually constrains what the
/// token can do.
func mintAccessTokenFromServiceAccount(
    _ key: ServiceAccountKey,
    session: URLSession = .shared
) async throws -> (token: String, expiresIn: TimeInterval) {
    let now = Date()
    let issuedAt = Int(now.timeIntervalSince1970)
    // 1 hour is Google's documented max; using exactly 3600 lets
    // the cache safely refresh after 50 min without colliding with
    // the boundary.
    let expiresAt = issuedAt + 3600

    let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
    let claims: [String: Any] = [
        "iss": key.clientEmail,
        "scope": "https://www.googleapis.com/auth/cloud-platform",
        "aud": key.tokenUri ?? "https://oauth2.googleapis.com/token",
        "exp": expiresAt,
        "iat": issuedAt,
    ]

    let headerEncoded = try base64URLEncodedJSON(header)
    let claimsEncoded = try base64URLEncodedJSON(claims)
    let signingInput = "\(headerEncoded).\(claimsEncoded)"

    let secKey = try importPKCS8RSAPrivateKey(pem: key.privateKey)
    let signature = try signRSA256(data: Data(signingInput.utf8), with: secKey)
    let signatureEncoded = base64URLEncode(signature)

    let assertion = "\(signingInput).\(signatureEncoded)"

    // Token exchange.
    let tokenURL = URL(string: key.tokenUri ?? "https://oauth2.googleapis.com/token")!
    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(assertion)"
    request.httpBody = body.data(using: .utf8)
    request.timeoutInterval = 30

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw NSError(domain: "VertexServiceAccount", code: 10,
            userInfo: [NSLocalizedDescriptionKey: "Token endpoint returned a non-HTTP response"])
    }
    if !(200..<300).contains(http.statusCode) {
        let detail = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        throw NSError(domain: "VertexServiceAccount", code: http.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "Token endpoint returned HTTP \(http.statusCode): \(String(detail.prefix(400)))"])
    }
    struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let token_type: String?
    }
    let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
    guard !parsed.access_token.isEmpty else {
        throw NSError(domain: "VertexServiceAccount", code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Token endpoint returned an empty access_token"])
    }
    return (token: parsed.access_token, expiresIn: parsed.expires_in)
}

// MARK: - Internals: PEM → SecKey

/// Parse a PEM-encoded PKCS#8 private key into a `SecKey` Apple's
/// SecKeyCreateSignature can use. SecKey wants PKCS#1 raw RSA
/// private-key DER for `kSecAttrKeyTypeRSA` + `kSecAttrKeyClassPrivate`,
/// but service-account JSONs always ship PKCS#8 — we strip the
/// PrivateKeyInfo wrapper to get at the inner RSAPrivateKey octets.
///
/// PKCS#8 PrivateKeyInfo, abbreviated:
///   SEQUENCE {
///     version INTEGER (0),
///     algorithm AlgorithmIdentifier,        -- {OID 1.2.840.113549.1.1.1, NULL} for RSA
///     privateKey OCTET STRING               -- this is the PKCS#1 RSAPrivateKey DER
///   }
private func importPKCS8RSAPrivateKey(pem: String) throws -> SecKey {
    let der = try base64DecodePEM(pem)
    let pkcs1 = try stripPKCS8Wrapper(der)
    let attrs: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
        let err = error?.takeRetainedValue()
        throw err.map { $0 as Error } ?? NSError(domain: "VertexServiceAccount", code: 20,
            userInfo: [NSLocalizedDescriptionKey: "SecKeyCreateWithData returned nil"])
    }
    return key
}

/// Strip the BEGIN/END markers from a PEM block and base64-decode
/// the body. Tolerates surrounding whitespace and either CRLF or
/// LF line endings.
private func base64DecodePEM(_ pem: String) throws -> Data {
    let lines = pem.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
    let body = lines.joined()
    guard let data = Data(base64Encoded: body) else {
        throw NSError(domain: "VertexServiceAccount", code: 21,
            userInfo: [NSLocalizedDescriptionKey: "PEM body is not valid base64"])
    }
    return data
}

/// Walk the outer PKCS#8 PrivateKeyInfo SEQUENCE and return the
/// PKCS#1 RSAPrivateKey bytes from the inner OCTET STRING. The
/// parser is intentionally minimal — it knows nothing about
/// algorithm OIDs or validation, just "skip to the OCTET STRING."
/// That's safe for our case because Google only issues RSA keys
/// for service accounts and the file format is fixed.
private func stripPKCS8Wrapper(_ der: Data) throws -> Data {
    var cursor = 0
    func need(_ n: Int) throws {
        if cursor + n > der.count {
            throw NSError(domain: "VertexServiceAccount", code: 22,
                userInfo: [NSLocalizedDescriptionKey: "Truncated DER while parsing PKCS#8"])
        }
    }
    func readByte() throws -> UInt8 {
        try need(1)
        let b = der[der.startIndex.advanced(by: cursor)]
        cursor += 1
        return b
    }
    /// DER length: short form (0..127) or long form (one extra
    /// length-of-length byte, then big-endian length).
    func readLength() throws -> Int {
        let first = try readByte()
        if first & 0x80 == 0 {
            return Int(first)
        }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4 else {
            throw NSError(domain: "VertexServiceAccount", code: 23,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported DER length form (count=\(count))"])
        }
        var length = 0
        for _ in 0..<count {
            length = (length << 8) | Int(try readByte())
        }
        return length
    }
    /// Skip exactly one DER tagged value.
    func skipTLV() throws {
        _ = try readByte()              // tag
        let length = try readLength()
        try need(length)
        cursor += length
    }

    // Outer SEQUENCE.
    let seqTag = try readByte()
    guard seqTag == 0x30 else {
        throw NSError(domain: "VertexServiceAccount", code: 24,
            userInfo: [NSLocalizedDescriptionKey: "PKCS#8 root is not SEQUENCE (got 0x\(String(seqTag, radix: 16)))"])
    }
    _ = try readLength()  // body length; we walk by tag from here

    // version INTEGER (skip).
    try skipTLV()
    // algorithm AlgorithmIdentifier (SEQUENCE — skip).
    try skipTLV()
    // privateKey OCTET STRING — extract.
    let octetTag = try readByte()
    guard octetTag == 0x04 else {
        throw NSError(domain: "VertexServiceAccount", code: 25,
            userInfo: [NSLocalizedDescriptionKey: "Expected OCTET STRING for privateKey, got 0x\(String(octetTag, radix: 16))"])
    }
    let octetLength = try readLength()
    try need(octetLength)
    let start = der.startIndex.advanced(by: cursor)
    let end = der.startIndex.advanced(by: cursor + octetLength)
    return Data(der[start..<end])
}

/// Sign `data` with `key` using RSA-PKCS1-v1.5 + SHA-256 — what
/// the JWT spec calls RS256. Apple's
/// `.rsaSignatureMessagePKCS1v15SHA256` algorithm hashes for us;
/// the input is the raw bytes of the JWT signing input.
private func signRSA256(data: Data, with key: SecKey) throws -> Data {
    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(
        key,
        .rsaSignatureMessagePKCS1v15SHA256,
        data as CFData,
        &error
    ) else {
        let err = error?.takeRetainedValue()
        throw err.map { $0 as Error } ?? NSError(domain: "VertexServiceAccount", code: 30,
            userInfo: [NSLocalizedDescriptionKey: "SecKeyCreateSignature returned nil"])
    }
    return signature as Data
}

// MARK: - Internals: base64url

private func base64URLEncodedJSON(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return base64URLEncode(data)
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
