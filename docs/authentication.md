# Authentication Configuration

This guide covers how to configure authentication for a self-hosted Qualytics deployment. Qualytics supports two authentication modes:

| Mode | Helm Value | Description | Air-Gapped Compatible |
|------|-----------|-------------|:---------------------:|
| **Database-backed** | `global.authType: "DB"` | Identity providers (OpenID Connect or SAML 2.0) and password sign-in configured in the Qualytics database (recommended) | Yes |
| **Auth0** | `global.authType: "AUTH0"` | Managed by Qualytics — requires egress to `auth.qualytics.io` | No |

The former `global.authType: "OIDC"` mode, which read a single identity provider from `secrets.oidc.*`, is no longer supported: the chart rejects the value and the controlplane refuses to start with it. See [Migrating from the removed OIDC mode](#migrating-from-the-removed-oidc-mode).

For Auth0 setup, see the [Auth0 Setup Guide](https://userguide.qualytics.io/deployments/auth0-setup/) in the Qualytics UserGuide.

Authentication settings supplement the required installation configuration. Every deployment must also set the Qualytics-provided `secrets.deployment.identifier` described in the [installation guide](../README.md#qualytics-provided-installation-configuration).

---

## Database-Backed Providers (Recommended)

Set `global.authType` to `"DB"`. Identity providers are configured in the application rather than in Helm values, so the chart renders no IdP credentials.

```yaml
global:
  authType: "DB"

secrets:
  auth:
    jwt_signing_secret: "<random-32+-char-string>"  # generate with: openssl rand -base64 32
```

### First sign-in

A fresh installation seeds a password provider. Open `https://<dnsRecord>/`, create the first administrator account from the login page, then configure providers under **Settings → Access → Providers**:

- **OpenID Connect** — supply the discovery URL (or explicit endpoints), client ID, client secret, scopes, and optional claim mappings and groups claim. Register Qualytics in your IdP as a Web Application using the Authorization Code grant and the provider's redirect URI, `https://<dnsRecord>/api/auth/oidc/callback/<provider-id>`, where `<provider-id>` is the numeric id assigned when the provider is created.
- **SAML 2.0** — supply the IdP metadata; the assertion consumer service is `https://<dnsRecord>/api/auth/saml2/acs` (see [SAML2 and the API ingress WAF](#saml2-and-the-api-ingress-waf)).
- **Password** — the built-in provider; administrators invite users by email.

Providers can be staged and verified before they are enabled, and several providers can be enabled at once. The login page lists every enabled provider.

### Deployment-wide provider settings

A few settings apply to every database-backed OpenID Connect provider and are still supplied through Helm because they have no per-provider equivalent:

| Helm Value (`secrets.oidc.*`) | Environment Variable | Default | Description |
|-------------------------------|---------------------|---------|-------------|
| `oidc_group_team_sync_enabled` | `OIDC_GROUP_TEAM_SYNC_ENABLED` | `false` | Add users to Teams matching the groups presented by the provider's groups claim. |
| `oidc_allow_insecure_transport` | `OIDC_ALLOW_INSECURE_HTTP` | `false` | Allow HTTP (non-TLS) identity provider endpoints. Development only. |
| `oidc_signer_pem_url` | `OIDC_SIGNER_PEM_URL` | *(unset)* | URL to a custom PEM certificate for validating identity provider TLS signers. |

Additionally, these are set automatically by the Helm chart:

| Environment Variable | Value | Description |
|---------------------|-------|-------------|
| `API_AUTH` | `DB` | Auth mode |
| `CFA_ROOT_URL` | `https://<dnsRecord>` | Frontend URL |
| `CORS_ORIGINS` | `<dnsRecord>` | Allowed CORS origins |

### Group → Team sync (optional)

Qualytics records the group listing presented by an OpenID Connect provider for every user, so you can inspect it while mapping groups to Teams. Recording happens whenever the provider's configured **groups claim** is present in the token.

Turning on `oidc_group_team_sync_enabled` additionally uses those groups to grant Team membership:

```yaml
secrets:
  oidc:
    oidc_group_team_sync_enabled: true
```

- Matching is **case-insensitive** against existing Team names.
- Sync is **add-only** — a user is added to any Team whose name matches a presented group, and is never removed from a Team when the group disappears.
- It is **opt-in (default `false`)** because Team membership carries data access. Enable it only once your Team names line up with your IdP group names.

> If group listings come back empty, the IdP is not emitting the claim. Most IdPs require both an extra scope (add `groups` to the provider's scopes) and a claim/token configuration change on the application registration.

---

## Cutting Over to Database-Backed Providers

`global.authType: "DB"` is an explicit maintenance-window cutover to providers configured under
**Settings → Access → Providers**. Provider rows may be staged and verified while `AUTH0` remains
authoritative.

```yaml
global:
  authType: "DB"
```

Changing to `DB` deliberately invalidates existing Auth0 browser sessions. Users must
reauthenticate with an enabled database-backed provider after the deployment restarts. The chart
does not inject Auth0 credentials into the API, CMD, or frontend DB-mode authentication paths.

Before changing the value:

1. Confirm at least one staged provider is enabled and usable.
2. Schedule a maintenance window and notify users that reauthentication is required.
3. Set `global.authType: "DB"` and deploy the chart.
4. Verify the login page lists the expected database-backed providers.

`global.authType` is validated by the chart: anything other than exactly `AUTH0` or `DB`
(case-sensitive) fails the render, and `OIDC` fails with a message pointing to this guide. A typo
such as `"db"` used to render API and CMD pods that referenced Auth0 Secret keys the chart no longer
emits — `CreateContainerConfigError` — while the frontend silently booted in Auth0 mode.

### Migrating from the removed OIDC mode

Deployments still running `global.authType: "OIDC"` must move their identity provider into the
database **before** upgrading to this chart version: the controlplane image that ships with it exits
at startup under the removed mode.

1. On your current version, open **Settings → Access → Providers**. Recent versions seeded a
   provider named *OIDC (migrated from env vars)* from the `secrets.oidc.*` values on startup; if it
   is present, verify its settings. Otherwise create an OpenID Connect provider with the same
   discovery URL (or endpoints), client ID, client secret, and scopes.
2. Add the provider's redirect URI, `https://<dnsRecord>/api/auth/oidc/callback/<provider-id>`, to
   the application registration in your IdP. The former `https://<dnsRecord>/api/callback` URI can
   stay registered until the cutover is confirmed.
3. Enable the provider and confirm a test sign-in from a second browser session.
4. Set `global.authType: "DB"`, remove the IdP values from `secrets.oidc` (only
   `oidc_group_team_sync_enabled`, `oidc_allow_insecure_transport`, and `oidc_signer_pem_url` remain
   meaningful), and deploy. Users reauthenticate once.
5. Upgrade to this chart version.

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

These settings apply to both authentication modes:

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

### On-premises identity providers

Requests the controlplane makes to an identity provider — discovery, token exchange, userinfo,
JWKS, SAML2 metadata, and the provider diagnostics in **Settings > Access** — accept publicly
routable addresses only, so a misconfigured or tampered endpoint cannot be used to reach
cluster-internal services or the cloud metadata API.

An IdP hosted inside your own network resolves to a private address and is refused by that rule.
Login reaches the IdP and then fails on the callback with `Unable to complete the token exchange
with the identity provider`, and the API log records:

```
WARNING | app.auth.ssrf:_resolve_and_validate - SSRF blocked: sso.internal.example.com resolved to unsafe IP 10.0.139.110
```

Set the following to permit those requests into private address space:

```yaml
controlplane:
  auth:
    allowPrivateNetworkFetches: true
```

| Helm Value | Environment Variable | Description |
|-----------|---------------------|-------------|
| `controlplane.auth.allowPrivateNetworkFetches` | `SSRF_ALLOW_LOOPBACK` | Default `false`. When `true`, auth provider requests may resolve to private (RFC 1918) and loopback addresses. |

Cloud metadata (`169.254.0.0/16`), multicast, and address-embedding IPv6 prefixes remain blocked
regardless of this setting, and the change is scoped to identity provider endpoints — datastore
connectivity, notifications, and integrations are unaffected. Leave it `false` when your IdP is
reachable at a public address.

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

# List the providers the login page will offer (database-backed mode)
curl -s https://<your-dns-record>/api/auth/providers/available
```

For database-backed providers, the endpoint returns the enabled providers as JSON. For Auth0, the frontend handles the login redirect.

> **Next step:** After deployment and authentication are working, your instance has a 31-day grace period. See [License Management](./license-management.md) to activate your license before the grace period ends.

---

## Troubleshooting

| Symptom | Likely Cause | Solution |
|---------|-------------|----------|
| 401 after login callback | Redirect URI mismatch | Ensure your IdP lists the provider's redirect URI, `https://<dnsRecord>/api/auth/oidc/callback/<provider-id>` |
| CORS errors in browser | `CORS_ORIGINS` not set correctly | Check that `global.dnsRecord` matches the URL in the browser |
| Login page not loading | Wrong `authType` | Verify `global.authType` matches your auth provider (`DB` or `AUTH0`) |
| `helm install`/`upgrade` fails on `global.authType` | Value is not exactly `AUTH0` or `DB`, or is the removed `OIDC` mode | Fix the case/spelling, or follow [Migrating from the removed OIDC mode](#migrating-from-the-removed-oidc-mode) — the chart rejects anything else rather than falling back to Auth0 |
| SAML login returns 403 or 413 from nginx, never reaching the app | OWASP CRS or a body-size limit on the API ingress rejected the `SAMLResponse` POST | See [SAML2 and the API ingress WAF](#saml2-and-the-api-ingress-waf) |
| "Invalid client" error | Wrong client credentials | Double-check the provider's client ID and client secret under Settings → Access → Providers |
| Auth0 connection timeout | No egress to auth.qualytics.io | Ensure firewall allows outbound HTTPS to `auth.qualytics.io` |
| User attributes missing | Claims mapping mismatch | Adjust the provider's claim mappings under Settings → Access → Providers to match your IdP's claim names |
| Discovery URL not working | IdP unreachable from the API pods | Ensure the pods can reach the provider's discovery URL over HTTPS. Run the provider diagnostics under Settings → Access → Providers, or configure explicit endpoints. |
| `Unable to complete the token exchange with the identity provider`, with `SSRF blocked: <idp-host> resolved to unsafe IP` in the API log | The IdP resolves to a private address, which auth provider requests refuse by default | Set `controlplane.auth.allowPrivateNetworkFetches: true` — see [On-premises identity providers](#on-premises-identity-providers) |
| Sessions expire too quickly | Provider session duration too short | Raise the provider's Session Duration under Settings → Access → Providers. |

---

## Additional Resources

- [Auth0 Setup Guide](https://userguide.qualytics.io/deployments/auth0-setup/) — Auth0 setup and request workflow
- [Self-Hosted Deployment Guide](https://userguide.qualytics.io/deployments/self-hosted-deployment/) — End-to-end deployment walkthrough
- [License Management](./license-management.md) — Activate and renew your deployment license
- [Cluster Sizing Guide](./cluster-sizing.md) — Choose the right cluster configuration
