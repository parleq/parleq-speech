# Keycloak OIDC dev rig

A throwaway [Keycloak](https://www.keycloak.org/) instance with a pre-imported
realm for exercising Parleq's enterprise OIDC federation locally — interactive
PKCE sign-in, refresh-token rotation, and the Company Account connection doctor
— without standing up a real IdP.

## Run it

```bash
cd scripts/dev/keycloak
docker compose up
```

Keycloak boots in dev mode and imports `realm-parleq.json` on first start.

> **Security note:** the rig binds to `127.0.0.1` only — it is not reachable from other machines on the network. `admin` / `admin` are throwaway local credentials; never expose this container beyond your own machine (e.g. don't publish the port on `0.0.0.0` or deploy it to a shared host).

- **Issuer:** `http://localhost:8080/realms/parleq`
- **Admin console:** `http://localhost:8080/` — `admin` / `admin`
- **Test user:** `dev@parleq.test` / `dev` (username `dev`; email login is enabled, both work)

The discovery document is at
`http://localhost:8080/realms/parleq/.well-known/openid-configuration`.

Stop and wipe with `docker compose down` (no volumes are persisted — the realm
re-imports from the JSON every boot, so edits to `realm-parleq.json` take effect
on the next `up`).

## What the realm pins

`realm-parleq.json` is a Keycloak 26 realm export configured to match what
Parleq's `OIDCSession` expects:

- Public client `parleq-app` — `publicClient: true`, `standardFlowEnabled: true`
  (authorization-code flow), no client secret.
- **PKCE S256 required** — client attribute `pkce.code.challenge.method: "S256"`.
- Redirect URI `parleq-auth://oidc/callback` — Parleq's custom-scheme callback
  (`OIDCSession.redirectURI`).
- **Refresh-token rotation ON** — realm `revokeRefreshToken: true` and
  `refreshTokenMaxReuse: 0`, so every refresh mints a fresh refresh token and the
  old one is invalidated on reuse. This exercises Parleq's persist-rotated-
  token-before-use ordering (`OIDCSession.apply`).
- Default scopes `openid`, `profile`, `email`; `offline_access` as an optional
  scope (Parleq requests it so the IdP issues a refresh token). Note: `openid`
  does not appear in `realm-parleq.json`'s `clientScopes` list because Keycloak
  treats it as implicit for all `openid-connect` clients — it is always granted
  and does not need an explicit entry.

## Parleq config snippet

Point Parleq at the rig via `~/.parleq/config.json`:

```json
{
  "oidc": {
    "issuer": "http://localhost:8080/realms/parleq",
    "client_id": "parleq-app",
    "scopes": ["openid", "profile", "email", "offline_access"],
    "ephemeral_browser": false
  }
}
```

Then sign in from **Settings → Company Account**.

## Cloud-leg caveat (read before testing AWS/GCP federation)

This rig fully exercises Parleq's OIDC ENGINE (sign-in, refresh, rotation,
sign-out, the connection doctor). The live CLOUD legs both need more than a
plain-http localhost issuer:

- **AWS**: STS validates tokens by fetching the issuer's JWKS from AWS's side —
  a localhost issuer cannot pass `AssumeRoleWithWebIdentity`.
- **GCP**: workforce providers accept an inline-uploaded JWKS (`jwks_json`),
  which avoids the JWKS fetch — but the provider's **issuer URI must use the
  HTTPS scheme** regardless, so a plain-http localhost issuer is rejected at
  provider creation.

For live cloud testing use a hosted free issuer (Amazon Cognito user pool or an
Okta Integrator Free org — both work for BOTH legs), or front this rig with a
free HTTPS tunnel that has a STABLE hostname (e.g. an ngrok free static domain;
ephemeral tunnel URLs break the pinned issuer on every restart).
