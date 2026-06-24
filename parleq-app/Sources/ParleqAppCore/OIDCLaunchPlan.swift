import Foundation

/// Launch-time enterprise-OIDC wiring decisions, derived purely from config so
/// they can be unit-tested without the App startup closure.
///
/// Decoupled from which tier is currently *active*. Corporate sign-in is
/// "configured" the moment an OIDC auth mode is selected for any cloud and the
/// issuer + client ID are set — so the shared `OIDCSession` (and therefore the
/// Settings → Company Account sign-in button) is built whenever the user has
/// set it up, including when only the **refine** or **context** tier uses the
/// federated provider. The earlier gate keyed on the cleanup/context provider
/// being vertex/bedrock and silently ignored the refine tier, which let the
/// user reach a dead-end: the Company Account section was visible (its own
/// predicate only needs the issuer) but no session existed, so there was no
/// sign-in button and the "enter issuer + client ID, then restart" hint was
/// wrong because those were already set.
///
/// Invariants preserved:
///  - **Non-enterprise users pay nothing**: with no OIDC auth mode selected
///    (and an empty issuer) nothing is built — no session, no Keychain read.
///  - **Fail-closed**: building a session never signs anyone in (sign-in stays
///    user-triggered); a signed-out federated cleanup still falls back to raw.
public struct OIDCLaunchPlan: Equatable {
    /// An OIDC auth mode is selected for some cloud (independent of creds).
    public let oidcModeSelected: Bool
    /// Build the shared `OIDCSession` (and wire the Company Account sign-in UI).
    public let buildSession: Bool
    /// Wire the AWS STS web-identity exchanger.
    public let wireAWSExchange: Bool
    /// Wire the GCP Workforce Identity exchanger.
    public let wireGCPExchange: Bool
    /// Vertex native Google sign-in mode (no exchanger; the session's access
    /// token is the Vertex bearer directly).
    public let vertexGoogleOAuth: Bool

    public init(config: Config, evalMode: Bool) {
        // In eval mode the gate runs the on-device provider only and must not
        // touch the Keychain, so nothing OIDC is built.
        let awsOIDC          = !evalMode && config.awsAuthMode == "oidc"
        let vertexFederation = !evalMode && config.vertexAuthMode == "oidcFederation"
        let vertexGoogle     = !evalMode && config.vertexAuthMode == "googleOAuth"
        let selected   = awsOIDC || vertexFederation || vertexGoogle
        let credsReady = !config.oidcIssuer.trimmingCharacters(in: .whitespaces).isEmpty
            && !config.oidcClientID.trimmingCharacters(in: .whitespaces).isEmpty
        let build = selected && credsReady

        self.oidcModeSelected = selected
        self.buildSession     = build
        // Exchangers ride the session: wire each whenever its auth mode is
        // selected AND its leg-specific credential (role ARN / workforce
        // provider) is present — regardless of which tier holds the provider.
        self.wireAWSExchange  = build && awsOIDC
            && !config.awsRoleArn.trimmingCharacters(in: .whitespaces).isEmpty
        self.wireGCPExchange  = build && vertexFederation
            && !config.vertexWorkforceProvider.trimmingCharacters(in: .whitespaces).isEmpty
        self.vertexGoogleOAuth = build && vertexGoogle
    }
}
