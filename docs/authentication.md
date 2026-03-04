# Authentication Configuration

This guide covers how to configure authentication for a self-hosted Qualytics deployment. Qualytics supports two authentication modes:

| Mode | Helm Value | Description | Air-Gapped Compatible |
|------|-----------|-------------|:---------------------:|
| **OIDC** | `global.authType: "OIDC"` | Direct integration with your enterprise Identity Provider (recommended) | Yes |
| **Auth0** | `global.authType: "AUTH0"` | Managed by Qualytics — requires egress to `auth.qualytics.io` | No |

For detailed guides including IdP-specific examples, see the [OIDC Configuration Guide](https://userguide.qualytics.io/deployments/oidc-configuration/) and [Auth0 Setup Guide](https://userguide.qualytics.io/deployments/auth0-setup/) in the Qualytics UserGuide.

---

## OIDC Configuration (Recommended)

Set `global.authType` to `"OIDC"` and configure your Identity Provider credentials under `secrets.oidc`.

### Prerequisites

1. Register Qualytics as a **Web Application** in your IdP
2. Set the **redirect URI** to `https://<your-dns-record>/api/callback`
3. Use **Authorization Code** grant type
4. Enable scopes: `openid`, `email`, `profile` (at minimum `openid`)

### Discovery URL (Recommended)

The simplest way to configure OIDC is with a **discovery URL**. Set `oidc_discovery_url` to your IdP's `.well-known/openid-configuration` endpoint and the controlplane will automatically discover 5 endpoint fields at startup:

| Auto-Discovered Field | Env Var Made Optional |
|-----------------------|----------------------|
| `authorization_endpoint` | `OIDC_AUTHORIZATION_ENDPOINT` |
| `token_endpoint` | `OIDC_TOKEN_ENDPOINT` |
| `userinfo_endpoint` | `OIDC_USERINFO_ENDPOINT` |
| `jwks_uri` | `OIDC_JWKS_URI` |
| `issuer` | `OIDC_ISSUER` |

**With discovery, you only need 4 values** (scopes, claims mapping, and security settings all have sensible defaults):

```yaml
global:
  authType: "OIDC"

secrets:
  oidc:
    oidc_discovery_url: "https://your-idp.example.com/.well-known/openid-configuration"
    oidc_client_id: "your-client-id"
    oidc_client_secret: "your-client-secret"
  auth:
    jwt_signing_secret: "<random-32+-char-string>"  # generate with: openssl rand -base64 32
```

**Defaults applied automatically:**

| Key | Default | Override if... |
|-----|---------|----------------|
| `oidc_scopes` | `openid,email,profile` | Your IdP requires different scopes |
| `oidc_user_id_key` | `sub` | Your IdP uses a non-standard claim |
| `oidc_user_email_key` | `email` | " |
| `oidc_user_name_key` | `name` | " |
| `oidc_user_fname_key` | `given_name` | " |
| `oidc_user_lname_key` | `family_name` | " |
| `oidc_user_picture_key` | `picture` | " |
| `oidc_user_provider_key` | `iss` | " |
| `oidc_allow_insecure_transport` | `false` | Development only (allows HTTP) |

**Common discovery URLs:**

| Identity Provider | Discovery URL |
|-------------------|--------------|
| **Okta** | `https://<your-org>.okta.com/.well-known/openid-configuration` |
| **Azure AD (Entra ID)** | `https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration` |
| **Google Workspace** | `https://accounts.google.com/.well-known/openid-configuration` |
| **Keycloak** | `https://<keycloak-host>/realms/<realm>/.well-known/openid-configuration` |
| **OneLogin** | `https://<your-org>.onelogin.com/oidc/2/.well-known/openid-configuration` |

> **Fallback behavior:** If the discovery fetch fails or a field is missing from the response, the controlplane falls back to any individually configured endpoint env vars. You can set both `oidc_discovery_url` and individual endpoints for resilience.

### Manual Endpoint Configuration (Fallback)

If your IdP doesn't support discovery, or you need to override specific endpoints, configure them individually:

```yaml
global:
  authType: "OIDC"

secrets:
  oidc:
    # Individual endpoints (required when NOT using oidc_discovery_url)
    oidc_authorization_endpoint: "https://your-idp.example.com/oauth2/authorize"
    oidc_token_endpoint: "https://your-idp.example.com/oauth2/token"
    oidc_userinfo_endpoint: "https://your-idp.example.com/oauth2/userinfo"

    # Required: OAuth2 client credentials
    oidc_client_id: "your-client-id"
    oidc_client_secret: "your-client-secret"

    # Scopes, claims mapping, and security settings use sensible defaults
    # (see defaults table above). Override only if needed.

  auth:
    jwt_signing_secret: "<random-32+-char-string>"  # generate with: openssl rand -base64 32
```

### Helm Values to Environment Variable Mapping

The Helm chart creates a Kubernetes Secret (`qualytics-creds`) and injects values as environment variables into the controlplane pods (API and CMD deployments).

| Helm Value (`secrets.oidc.*`) | Environment Variable | Source |
|-------------------------------|---------------------|--------|
| `oidc_discovery_url` | `OIDC_DISCOVERY_URL` | Secret (if set) |
| `oidc_scopes` | `OIDC_SCOPES` | Secret |
| `oidc_authorization_endpoint` | `OIDC_AUTHORIZATION_ENDPOINT` | Secret |
| `oidc_token_endpoint` | `OIDC_TOKEN_ENDPOINT` | Secret |
| `oidc_userinfo_endpoint` | `OIDC_USERINFO_ENDPOINT` | Secret |
| `oidc_client_id` | `OIDC_CLIENT_ID` | Secret |
| `oidc_client_secret` | `OIDC_CLIENT_SECRET` | Secret |
| `oidc_user_id_key` | `OIDC_USER_ID_KEY` | Secret |
| `oidc_user_email_key` | `OIDC_USER_EMAIL_KEY` | Secret |
| `oidc_user_name_key` | `OIDC_USER_NAME_KEY` | Secret |
| `oidc_user_fname_key` | `OIDC_USER_FNAME_KEY` | Secret |
| `oidc_user_lname_key` | `OIDC_USER_LNAME_KEY` | Secret |
| `oidc_user_picture_key` | `OIDC_USER_PICTURE_KEY` | Secret |
| `oidc_user_provider_key` | `OIDC_USER_PROVIDER_KEY` | Secret |
| `oidc_allow_insecure_transport` | `OIDC_ALLOW_INSECURE_HTTP` | Direct value |
| `oidc_signer_pem_url` | `OIDC_SIGNER_PEM_URL` | Direct value (if set) |

Additionally, these are set automatically by the Helm chart:

| Environment Variable | Value | Description |
|---------------------|-------|-------------|
| `API_AUTH` | `OIDC` | Auth mode |
| `OIDC_REDIRECT_URL` | `https://<dnsRecord>/api/callback` | Computed from `global.dnsRecord` and `API_ROOT_PATH` |
| `CFA_ROOT_URL` | `https://<dnsRecord>` | Frontend URL |
| `CORS_ORIGINS` | `<dnsRecord>` | Allowed CORS origins |

---

## Auth0 Configuration

Auth0 is managed by Qualytics. To use Auth0 for a self-hosted deployment:

1. Contact your [Qualytics account manager](mailto:hello@qualytics.ai) and request Auth0 resources
2. Qualytics provisions an Auth0 organization and provides you with:
   - `auth0_domain`
   - `auth0_audience`
   - `auth0_organization`
   - `auth0_spa_client_id`
3. Configure the values in your `values.yaml`

### Helm Values

```yaml
global:
  authType: "AUTH0"

secrets:
  auth0:
    auth0_domain: auth.qualytics.io          # provided by Qualytics
    auth0_audience: your-api-audience         # provided by Qualytics
    auth0_organization: org_your-org-id       # provided by Qualytics
    auth0_spa_client_id: your-spa-client-id   # provided by Qualytics

  auth:
    jwt_signing_secret: "<random-32+-char-string>"
```

### Helm Values to Environment Variable Mapping

| Helm Value (`secrets.auth0.*`) | Environment Variable | Source |
|-------------------------------|---------------------|--------|
| `auth0_domain` | `AUTH0_DOMAIN` | Direct value |
| `auth0_audience` | `AUTH0_AUDIENCE` | Secret |
| `auth0_organization` | `AUTH0_ORGANIZATION` | Secret |
| `auth0_spa_client_id` | `AUTH0_CLIENT_ID` | Secret |

Additionally set automatically:

| Environment Variable | Value | Description |
|---------------------|-------|-------------|
| `API_AUTH` | `AUTH0` | Auth mode |

### Network Requirements

Auth0 requires outbound HTTPS access from the cluster to:
- `https://auth.qualytics.io` — Auth0 tenant for authentication
- `https://<auth0_domain>/.well-known/jwks.json` — Token verification

This makes Auth0 incompatible with fully air-gapped deployments.

---

## Shared Security Settings

These settings apply to both OIDC and Auth0 modes:

```yaml
secrets:
  auth:
    jwt_signing_secret: "<random-32+-char-string>"   # REQUIRED — min 32 chars
  postgres:
    secrets_passphrase: "<random-secure-string>"     # REQUIRED — encrypts stored credentials
```

| Helm Value | Environment Variable | Description |
|-----------|---------------------|-------------|
| `secrets.auth.jwt_signing_secret` | `JWT_SIGNING_SECRET` | Signs session JWTs. Changing this invalidates all active sessions. |
| `secrets.postgres.secrets_passphrase` | `SECRETS_PASSPHRASE` | Encrypts sensitive data stored in the database (connection credentials, API keys). |

> **Important:** Both `jwt_signing_secret` and `secrets_passphrase` must be changed from their defaults before deploying to production. Generate secure values with `openssl rand -base64 32`.

---

## Verifying Authentication

After deploying, verify authentication is working:

```bash
# Check the API pod is running
kubectl get pods -n qualytics -l app=qualytics-api

# Check API logs for auth initialization
kubectl logs -n qualytics deployment/qualytics-api | grep -i "auth\|oidc\|auth0"

# Test the login endpoint
curl -I https://<your-dns-record>/api/login
```

For OIDC, the `/api/login` endpoint should return a `302` redirect to your IdP's authorization endpoint. For Auth0, the frontend handles the login redirect.

> **Next step:** After deployment and authentication are working, your instance has a 31-day grace period. See [License Management](./license-management.md) to activate your license before the grace period ends.

---

## Troubleshooting

| Symptom | Likely Cause | Solution |
|---------|-------------|----------|
| 401 after login callback | Redirect URI mismatch | Ensure your IdP has `https://<dnsRecord>/api/callback` as an allowed redirect URI |
| CORS errors in browser | `CORS_ORIGINS` not set correctly | Check that `global.dnsRecord` matches the URL in the browser |
| Login page not loading | Wrong `authType` | Verify `global.authType` matches your auth provider (`OIDC` or `AUTH0`) |
| "Invalid client" error | Wrong client credentials | Double-check `oidc_client_id` and `oidc_client_secret` match your IdP |
| Auth0 connection timeout | No egress to auth.qualytics.io | Ensure firewall allows outbound HTTPS to `auth.qualytics.io` |
| User attributes missing | Claims mapping mismatch | Adjust `oidc_user_*_key` values to match your IdP's claim names |
| Discovery URL not working | IdP unreachable at startup | Ensure the pod can reach `oidc_discovery_url` over HTTPS. Check `kubectl logs` for discovery fetch errors. Individual endpoint fields are used as fallbacks. |
| Sessions expire too quickly | Default 30-min JWT TTL | This is controlled by the controlplane (`OIDC_JWT_TTL_MINUTES`). Contact Qualytics support if adjustment is needed. |

---

## Additional Resources

- [OIDC Configuration Guide](https://userguide.qualytics.io/deployments/oidc-configuration/) — Detailed OIDC setup with IdP-specific examples
- [Auth0 Setup Guide](https://userguide.qualytics.io/deployments/auth0-setup/) — Auth0 setup and request workflow
- [Self-Hosted Deployment Guide](https://userguide.qualytics.io/deployments/self-hosted-deployment/) — End-to-end deployment walkthrough
- [License Management](./license-management.md) — Activate and renew your deployment license
- [Cluster Sizing Guide](./cluster-sizing.md) — Choose the right cluster configuration
