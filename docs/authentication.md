# Authentication Configuration

This guide covers how to configure authentication for a self-hosted Qualytics deployment. Qualytics supports three authentication modes:

| Mode | Helm Value | Description | Air-Gapped Compatible |
|------|-----------|-------------|:---------------------:|
| **OIDC** | `global.authType: "OIDC"` | Direct integration with your enterprise Identity Provider (recommended) | Yes |
| **Database-backed** | `global.authType: "DB"` | Providers configured in the Qualytics database (OIDC, SAML2, or password) | Yes |
| **Auth0** | `global.authType: "AUTH0"` | Managed by Qualytics — requires egress to `auth.qualytics.io` | No |

For detailed guides including IdP-specific examples, see the [OIDC Configuration Guide](https://userguide.qualytics.io/deployments/oidc-configuration/) and [Auth0 Setup Guide](https://userguide.qualytics.io/deployments/auth0-setup/) in the Qualytics UserGuide.

Authentication settings supplement the required installation configuration. Every deployment must also set the Qualytics-provided `secrets.deployment.identifier` described in the [installation guide](../README.md#qualytics-provided-installation-configuration).

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

**For OIDC itself, discovery reduces the required IdP-specific configuration to four values** (scopes, claims mapping, and security settings have sensible defaults):

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
| `oidc_user_groups_key` | `groups` | Your IdP emits group membership under a different claim (e.g. `roles`) |
| `oidc_group_team_sync_enabled` | `false` | You want IdP groups to grant Team membership — see [Group → Team sync](#group--team-sync-optional) |
| `oidc_token_auth_method` | *(unset — auto-detected from the discovery document)* | Your IdP only accepts one method; set `client_secret_post` or `client_secret_basic` explicitly |
| `oidc_allow_insecure_transport` | `false` | Development only (allows HTTP) |
| `oidc_jwt_ttl_minutes` | *(unset — controlplane default)* | Override JWT session TTL in minutes |

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

| Helm Value (`secrets.oidc.*`) | Environment Variable | Source | Description |
|-------------------------------|---------------------|--------|-------------|
| `oidc_scopes` | `OIDC_SCOPES` | Secret | Required. Comma-separated OAuth2 scopes (e.g., `openid,email,profile`). |
| `oidc_client_id` | `OIDC_CLIENT_ID` | Secret | Required. OAuth2 client ID registered with your IdP. |
| `oidc_client_secret` | `OIDC_CLIENT_SECRET` | Secret | Required. OAuth2 client secret registered with your IdP. |
| `oidc_discovery_url` | `OIDC_DISCOVERY_URL` | Secret (if set) | Optional. OpenID Connect discovery URL; auto-discovers endpoints, JWKS, and issuer. |
| `oidc_authorization_endpoint` | `OIDC_AUTHORIZATION_ENDPOINT` | Secret | Optional when using discovery URL. IdP authorization endpoint. |
| `oidc_token_endpoint` | `OIDC_TOKEN_ENDPOINT` | Secret | Optional when using discovery URL. IdP token endpoint. |
| `oidc_userinfo_endpoint` | `OIDC_USERINFO_ENDPOINT` | Secret | Optional when using discovery URL. IdP userinfo endpoint. |
| `oidc_token_auth_method` | `OIDC_TOKEN_AUTH_METHOD` | Secret (if set) | Optional. `client_secret_post` or `client_secret_basic`. Leave empty to auto-detect from the discovery document; set it for IdPs that accept only one method (e.g. `client_secret_post` for Okta). |
| `oidc_user_id_key` | `OIDC_USER_ID_KEY` | Secret | Optional. Claim name for the user ID. Default: `sub`. |
| `oidc_user_email_key` | `OIDC_USER_EMAIL_KEY` | Secret | Optional. Claim name for the user email. Default: `email`. |
| `oidc_user_name_key` | `OIDC_USER_NAME_KEY` | Secret | Optional. Claim name for the user display name. Default: `name`. |
| `oidc_user_fname_key` | `OIDC_USER_FNAME_KEY` | Secret | Optional. Claim name for the user first name. Default: `given_name`. |
| `oidc_user_lname_key` | `OIDC_USER_LNAME_KEY` | Secret | Optional. Claim name for the user last name. Default: `family_name`. |
| `oidc_user_picture_key` | `OIDC_USER_PICTURE_KEY` | Secret | Optional. Claim name for the user avatar URL. Default: `picture`. |
| `oidc_user_provider_key` | `OIDC_USER_PROVIDER_KEY` | Secret | Optional. Claim name for the identity provider. Default: `iss`. |
| `oidc_user_groups_key` | `OIDC_USER_GROUPS_KEY` | Secret (if set) | Optional. Claim holding the user's group listing. Default: `groups`. |
| `oidc_group_team_sync_enabled` | `OIDC_GROUP_TEAM_SYNC_ENABLED` | Direct value | Optional. Add users to Teams matching their IdP groups. Default: `false`. |
| `oidc_allow_insecure_transport` | `OIDC_ALLOW_INSECURE_HTTP` | Direct value | Optional. Allow HTTP (non-TLS) for OIDC endpoints. Default: `false`. |
| `oidc_jwt_ttl_minutes` | `OIDC_JWT_TTL_MINUTES` | Secret (if set) | Optional. JWT session lifetime in minutes. Omit to use the controlplane default. |
| `oidc_signer_pem_url` | `OIDC_SIGNER_PEM_URL` | Direct value (if set) | Optional. URL to a custom PEM certificate for token signature validation. |

Additionally, these are set automatically by the Helm chart:

| Environment Variable | Value | Description |
|---------------------|-------|-------------|
| `API_AUTH` | `OIDC` | Auth mode |
| `OIDC_REDIRECT_URL` | `https://<dnsRecord>/api/callback` | Computed from `global.dnsRecord` and `API_ROOT_PATH` |
| `CFA_ROOT_URL` | `https://<dnsRecord>` | Frontend URL |
| `CORS_ORIGINS` | `<dnsRecord>` | Allowed CORS origins |

### Group → Team sync (optional)

Qualytics records the group listing presented by your IdP for every user, so you can inspect it while mapping groups to Teams. Recording happens whenever the claim named by `oidc_user_groups_key` (default `groups`) is present in the token — no extra configuration required.

Turning on `oidc_group_team_sync_enabled` additionally uses those groups to grant Team membership:

```yaml
secrets:
  oidc:
    oidc_scopes: "openid,email,profile,groups"   # your IdP must actually emit the claim
    oidc_user_groups_key: "groups"
    oidc_group_team_sync_enabled: true
```

- Matching is **case-insensitive** against existing Team names.
- Sync is **add-only** — a user is added to any Team whose name matches a presented group, and is never removed from a Team when the group disappears.
- It is **opt-in (default `false`)** because Team membership carries data access. Enable it only once your Team names line up with your IdP group names.

> If group listings come back empty, the IdP is not emitting the claim. Most IdPs require both an extra scope (add `groups` to `oidc_scopes`) and a claim/token configuration change on the application registration.

---

## Database-Backed Provider Cutover

`global.authType: "DB"` is an explicit maintenance-window cutover to providers configured under
**Settings → Access → Providers**. Provider rows may be staged and verified while `AUTH0` or
`OIDC` remains authoritative. Legacy OIDC environment configuration is imported into a provider
row on startup when no provider configurations exist, but it continues to control login until this
value is changed to `DB`.

```yaml
global:
  authType: "DB"
```

Changing to `DB` deliberately invalidates existing Auth0 and legacy OIDC browser sessions. Users
must reauthenticate with an enabled database-backed provider after the deployment restarts. The
chart does not inject legacy Auth0 or OIDC credentials into the API, CMD, or frontend DB-mode
authentication paths.

Before changing the value:

1. Confirm at least one staged provider is enabled and usable.
2. Schedule a maintenance window and notify users that reauthentication is required.
3. Set `global.authType: "DB"` and deploy the chart.
4. Verify the login page lists the expected database-backed providers.

`global.authType` is validated by the chart: anything other than exactly `AUTH0`, `OIDC`, or `DB`
(case-sensitive) fails the render. A typo such as `"db"` used to render API and CMD pods that
referenced Auth0 Secret keys the chart no longer emits — `CreateContainerConfigError` — while the
frontend silently booted in Auth0 mode.

### SAML2 and the API ingress WAF

A SAML2 provider adds a browser **form POST** from your IdP to
`https://<dnsRecord>/api/auth/saml2/acs`, carrying a large base64 `SAMLResponse` field. That path is
fronted by the `<release>-api-ingress` Ingress, which enables ModSecurity with the OWASP Core Rule
Set and per-IP rate limiting. Base64 assertion blobs are a classic CRS false-positive trigger, and
signed/encrypted assertions from IdPs that embed certificate chains or many group attributes can be
large.

| Symptom | Likely cause | Where to fix |
|---------|-------------|--------------|
| SAML login fails with a `403` served by nginx (not the app), ModSecurity audit JSON in the ingress-controller log naming a CRS rule id | OWASP CRS matched the base64 `SAMLResponse` body | Add a targeted `ctl:ruleRemoveTargetById`/`ctl:ruleRemoveById` for that rule id, scoped to the ACS path, in the `nginx.ingress.kubernetes.io/modsecurity-snippet` of `<release>-api-ingress` |
| `413 Request Entity Too Large` | Assertion exceeds `nginx.ingress.kubernetes.io/proxy-body-size` (`20m` on the API ingress) | Raise `proxy-body-size` on `<release>-api-ingress` |
| `403` with a ModSecurity body-limit message on a large assertion | The ACS POST is a non-file body, so it is capped by `SecRequestBodyNoFilesLimit` (**2.6 MB**), well below the 20 MB `SecRequestBodyLimit` | Raise `SecRequestBodyNoFilesLimit` in the same `modsecurity-snippet` |
| Intermittent `429` during a login wave | Per-IP rate limiting; many users share one egress IP behind corporate NAT | Raise `ingress.maxRequestsPerSecondPerIP` / `ingress.burstMultiplier` in `values.yaml` |

**Do not disable the WAF for the whole API ingress** (`enable-owasp-core-rules: "false"`) to make
SAML work — that removes CRS from every authenticated API endpoint. Scope the change to the ACS
path.

Only the rate-limit knobs (`ingress.maxRequestsPerSecondPerIP`, `ingress.burstMultiplier`,
`ingress.maxConnectionsPerIP`, `ingress.frontendMaxRequestsPerSecondPerIP`,
`ingress.frontendMaxConnectionsPerIP`), `ingress.cors`, and `ingress.tls.*` are exposed as values
today. There is no values knob for arbitrary ingress annotations, so a CRS exclusion or a body-size
override for the ACS path is made by editing `charts/qualytics/templates/ingress.yaml` — in the
`<release>-api-ingress` annotations block — and deploying the chart from your fork or overlay. Get
the rule id from the ingress-controller log first, then exclude only that id and only for the ACS
path, for example:

```yaml
# charts/qualytics/templates/ingress.yaml, annotations of {{ .Release.Name }}-api-ingress
nginx.ingress.kubernetes.io/modsecurity-snippet: |
  {{- include "common.modsecurity.snippet" . | nindent 6 }}
  SecRequestBodyLimit 20971520          # 20MB
  SecRequestBodyNoFilesLimit 2621440    # 2.6MB — raise if large assertions are rejected
  SecRequestBodyLimitAction Reject
  # SAML2 ACS: the IdP form-POSTs a base64 SAMLResponse here. Disable only the rule ids
  # the audit log shows firing, and only for this path.
  SecRule REQUEST_URI "@beginsWith /api/auth/saml2/acs" \
    "id:14860,phase:1,pass,nolog,ctl:ruleRemoveById=<RULE_ID>"
```

If you prefer to keep the packaged chart unmodified, define a separate Ingress for
`/api/auth/saml2/acs` with a higher `nginx.ingress.kubernetes.io/priority` than the API ingress
(`10`) and the relaxed annotations on that Ingress alone — the same pattern the chart already uses
for the streaming ingress.

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
| `secrets.auth.jwt_signing_secret` | `JWT_SIGNING_SECRET` | Signs session JWTs. Under `authType: "DB"` this key is the sole browser-session authority. Changing it invalidates all active sessions. |
| `secrets.postgres.secrets_passphrase` | `SECRETS_PASSPHRASE` | Encrypts sensitive data stored in the database (connection credentials, API keys, IdP client secrets, SAML certificates). |

> **Important:** A fresh install is rejected while **either** `secrets_passphrase` **or**
> `jwt_signing_secret` is still `ChangeMe!`. Both are enforced by the chart at install time.
> Generate secure values with `openssl rand -base64 32`. Changing the passphrase directly
> on an existing installation makes existing ciphertext unreadable; use the rotation process below.

### Rotating the stored-secrets passphrase

Rotation is a two-upgrade maintenance operation. It covers connection credentials, integration
tokens, notification secrets, OIDC client secrets, and SAML certificates.

1. Keep `secrets_passphrase` unchanged, set `new_secrets_passphrase` to a new strong value,
   and increment `secrets_migration_id` by exactly one. Upgrade the release. Hub API intentionally
   stays down while the singleton Hub CMD atomically re-encrypts and verifies current and historical secrets,
   then exits.
2. Copy `new_secrets_passphrase` into `secrets_passphrase`, clear
   `new_secrets_passphrase`, retain the incremented `secrets_migration_id`, and upgrade the
   release again. API and CMD then restart together with the new key.

Do not skip the second upgrade or run application writers during the first phase.

`secrets_migration_id` must be incremented whenever `new_secrets_passphrase` is set: the counter
starts at 1, so the chart rejects a staged passphrase that leaves it at 1. Without that guard the
controlplane reports `Secrets migration 1 has already completed` — indistinguishable from success —
and promoting a passphrase that never re-encrypted anything makes every encrypted column
undecryptable.

#### Phase-1 upgrade command: drop `--wait` and `--atomic`

The [installation command](../README.md#3-deploy-qualytics-to-your-cluster) uses `--wait --timeout=5m`.
**Do not use `--wait`, and never use `--atomic`, for the phase-1 (step 1) upgrade.** By design in
that phase:

- Hub API exits rather than serving against a half-rotated database, so its pods never become ready.
- Hub CMD raises `EnvironmentError` even when the rotation *succeeds* (that is how it reports
  "now promote the passphrase"), then restarts and crashloops on the "already completed" branch.

`--wait` therefore **always** reports failure regardless of the real outcome, and `--atomic` would
roll the release back mid-window — restoring the old passphrase against an already re-encrypted
database. Run phase 1 as:

```bash
helm upgrade qualytics qualytics/qualytics \
  --namespace qualytics \
  --version "$CHART_VERSION" \
  -f values.yaml
  # no --wait, no --atomic
```

A crashlooping `qualytics-cmd` pod after phase 1 is **expected**. Confirm the rotation actually
succeeded before starting phase 2 — do not rely on the Helm exit status or on pod health:

```bash
# 1. The completion log line (emitted once, before the intentional EnvironmentError)
kubectl logs -n qualytics deployment/qualytics-cmd --all-containers --previous \
  | grep "completed and verified"
# -> Secrets migration <N> completed and verified for <rows> rows

# 2. The authoritative check — the counter in the database must equal the configured id.
#    (Bundled Postgres shown; with an external database, run the same query against it.)
kubectl exec -n qualytics statefulset/qualytics-postgres -- \
  psql -U postgres -d surveillance_hub -tAc \
  "select secrets_migration_id from qualytics_metadata order by created desc limit 1;"
```

When the database value equals your `secrets_migration_id`, phase 1 is complete: proceed to
step 2. Restore `--wait --timeout=5m` for the phase-2 upgrade, which is an ordinary restart.

#### `secrets_migration_id` is a lifetime-of-the-deployment counter

`secrets_migration_id` mirrors `qualytics_metadata.secrets_migration_id` in your database. It is a
**monotonic counter that must never be reset or lowered** — preserve it in your values file for the
lifetime of the deployment. After the first rotation the database counter is permanently `>= 2`, so
a deploy from a regenerated or reset values file re-renders `1`: Hub API refuses to start
("configured secrets migration id ... differs from the current state") while Hub CMD performs no
parity check and keeps running. The result is an asymmetric split-brain that is easy to mistake for
an API-only outage. Treat the value as deployment state, not as a default — especially under GitOps,
where drift silently reintroduces it.

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
| Login page not loading | Wrong `authType` | Verify `global.authType` matches your auth provider (`OIDC`, `DB`, or `AUTH0`) |
| `helm install`/`upgrade` fails on `global.authType` | Value is not exactly `AUTH0`, `OIDC`, or `DB` | Fix the case/spelling — the chart rejects anything else rather than falling back to Auth0 |
| SAML login returns 403 or 413 from nginx, never reaching the app | OWASP CRS or a body-size limit on the API ingress rejected the `SAMLResponse` POST | See [SAML2 and the API ingress WAF](#saml2-and-the-api-ingress-waf) |
| "Invalid client" error | Wrong client credentials | Double-check `oidc_client_id` and `oidc_client_secret` match your IdP |
| Auth0 connection timeout | No egress to auth.qualytics.io | Ensure firewall allows outbound HTTPS to `auth.qualytics.io` |
| User attributes missing | Claims mapping mismatch | Adjust `oidc_user_*_key` values to match your IdP's claim names |
| Discovery URL not working | IdP unreachable at startup | Ensure the pod can reach `oidc_discovery_url` over HTTPS. Check `kubectl logs` for discovery fetch errors. Individual endpoint fields are used as fallbacks. |
| Sessions expire too quickly | Default JWT TTL too short | Set `secrets.oidc.oidc_jwt_ttl_minutes` in `values.yaml` to the desired session duration in minutes (e.g., `480` for 8 hours). |

---

## Additional Resources

- [OIDC Configuration Guide](https://userguide.qualytics.io/deployments/oidc-configuration/) — Detailed OIDC setup with IdP-specific examples
- [Auth0 Setup Guide](https://userguide.qualytics.io/deployments/auth0-setup/) — Auth0 setup and request workflow
- [Self-Hosted Deployment Guide](https://userguide.qualytics.io/deployments/self-hosted-deployment/) — End-to-end deployment walkthrough
- [License Management](./license-management.md) — Activate and renew your deployment license
- [Cluster Sizing Guide](./cluster-sizing.md) — Choose the right cluster configuration
