# Envoy Gateway (Gateway API) ingress — migration guide & coverage report

The chart can expose Qualytics through **Envoy Gateway** (Gateway API) instead of the
bundled **ingress-nginx**. Both paths are supported side by side so you can switch
controllers; nginx will eventually be removed in favour of Envoy Gateway.

This page documents:
1. how to turn it on,
2. exactly which nginx ingress behaviours migrate (and how),
3. **what cannot be migrated**, and the workarounds,
4. the validation you must do on a live controller before production.

---

## Model

- **Controller is a cluster PREREQUISITE — not a chart dependency.** Unlike nginx
  (whose routing uses the built-in `Ingress` API, so the chart can install the
  controller as a subchart), Gateway API is **all CRDs**, and Helm cannot install a
  CRD and a custom resource of it in the same release. So the Envoy Gateway controller
  + its CRDs + the `GatewayClass` must already exist; install `gateway-helm` separately
  (e.g. a Terraform add-on on a dedicated cluster — see
  [Installing the controller](#installing-the-controller)). The chart renders **only**
  the gateway routing CRs against those pre-existing CRDs.
- **One path at a time.** `ingress.enabled` (nginx) and `gateway.enabled` are
  mutually exclusive; enabling both fails the render. Keep `nginx.enabled: false` when
  using Envoy Gateway so the bundled nginx controller is not installed.
- **Self-contained config.** The gateway path reads only `gateway.*` — it does **not**
  reuse any `ingress.*` / `nginx.*` values, so nginx can be removed cleanly once every
  customer has migrated.

### Versions

| Component | Minimum | Notes |
|---|---|---|
| Envoy Gateway | **v1.8** | v1.8.x bundles Gateway API v1.5 / Envoy 1.38. Dynamic-module + Wasm TLS hardening landed in v1.8. |
| Gateway API | **v1.2** | `HTTPRoute.timeouts` reached the Standard channel in v1.2. |
| Kubernetes | **1.30** | Existing chart target. (Coraza *DynamicModule* image-volume loading needs 1.35+, so prefer the Wasm WAF path.) |

> The core routing pieces (Gateway, HTTPRoute, TLS Terminate, redirect, header
> modifiers, timeouts) are **GA / Standard channel**. Every `gateway.envoyproxy.io`
> policy CRD (BackendTrafficPolicy, SecurityPolicy, EnvoyExtensionPolicy, EnvoyProxy)
> is **`v1alpha1` (experimental)** — fields can shift between EG releases, so validate
> against your installed version.

---

## Enable it

**Step 1 — install the controller (prerequisite, once per cluster):** see
[Installing the controller](#installing-the-controller).

**Step 2 — enable the gateway path in the chart:**

```yaml
# values.yaml
ingress:
  enabled: false          # turn OFF the nginx path
nginx:
  enabled: false          # do NOT install the bundled nginx controller
gateway:
  enabled: true
  className: eg           # the EXISTING GatewayClass (created with the controller)
  tls:
    secretName: qualytics-tls-cert   # BYO kubernetes.io/tls Secret
  # optional; defaults shown
  cors: false
  httpsRedirectCode: 301
  rateLimit:
    enabled: true
    type: local           # or "global" (needs controller-side Redis RLS)
```

`gateway.*` is **self-contained** — it does not read any `ingress.*` / `nginx.*`
values (nginx is removed once everyone migrates). TLS is a BYO `kubernetes.io/tls`
Secret named by `gateway.tls.secretName` — see [ingress-tls.md](ingress-tls.md).
Security headers, gzip+brotli compression, X-Original-URI, retries and 3600s
timeouts are applied automatically (no per-feature toggles, same as the nginx path).

### Resources rendered (`templates/gateway.yaml`)

| Kind | Name | Purpose |
|---|---|---|
| `Gateway` | `<release>-gateway` | HTTPS (TLS terminate) + HTTP (redirect) listeners |
| `HTTPRoute` | `<release>-api` | `/api/anomalies/.../download` (rule 0) + `/api` (rule 1) → API |
| `HTTPRoute` | `<release>-frontend` | `/.well-known` → API (rule 0) + `/` → frontend (rule 1) |
| `HTTPRoute` | `<release>-redirect` | HTTP→HTTPS 301 |
| `BackendTrafficPolicy` | `<release>-api` / `-frontend` | retry, timeouts, rate limit, compression |
| `EnvoyProxy` | `<release>-proxy` | data-plane Envoy pod scheduling/replicas (always) |
| `SecurityPolicy` | `<release>-cors` | only when `gateway.cors: true` |

The controller, its CRDs, and the `GatewayClass` are **not** rendered by the chart —
they are the cluster prerequisite below.

---

## Installing the controller

> **Why this is a separate step (and not a chart dependency).** Helm cannot install a
> CRD and a custom resource that uses it in the **same release** — a one-shot install
> that bundled `gateway-helm` and rendered our `Gateway`/`HTTPRoute`/`BackendTrafficPolicy`
> fails with `ensure CRDs are installed first` (verified on a live cluster). nginx avoids
> this only because `Ingress` is a built-in API. So the controller + CRDs + `GatewayClass`
> are a **cluster prerequisite**, installed once, independent of the Qualytics release.

- **Shared cluster** — the controller already runs; do nothing here, just set
  `gateway.className` to the existing `GatewayClass`.
- **Dedicated cluster** — install the controller as cluster infrastructure. Two ways:

**(a) Terraform add-on** (recommended for dedicated clusters provisioned via `terraform/`):

```hcl
resource "helm_release" "envoy_gateway" {
  name             = "eg"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = "v1.8.1"
  namespace        = "envoy-gateway-system"
  create_namespace = true
}

# gateway-helm ships no GatewayClass — create the one the chart references.
resource "kubernetes_manifest" "gateway_class" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata   = { name = "eg" }
    spec       = { controllerName = "gateway.envoyproxy.io/gatewayclass-controller" }
  }
  depends_on = [helm_release.envoy_gateway]
}
```

**(b) Plain Helm + kubectl** (one-time, e.g. a runbook step):

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.1 \
  -n envoy-gateway-system --create-namespace --wait

kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF
```

Then deploy Qualytics with `gateway.enabled: true` + `gateway.className: eg`.

> ### ⚠️ The controller is a cluster-scoped singleton
> It owns **cluster-wide** Gateway API + `gateway.envoyproxy.io` CRDs in
> `envoy-gateway-system`. Don't install a second one where Envoy Gateway / Gateway API
> CRDs already exist (ownership conflicts), and remember a `helm uninstall eg` removes
> those CRDs cluster-wide (breaking any other Gateways). EG's CRDs are large — if a
> plain `helm install` ever fails on CRD size, install the CRDs first via
> `helm template oci://docker.io/envoyproxy/gateway-crds-helm --version v1.8.1 ... | kubectl apply --server-side -f -`.

---

## Migration matrix

✅ full · 🟡 partial / behavioural delta · ❌ cannot migrate

| nginx behaviour | Status | Envoy Gateway construct |
|---|---|---|
| TLS termination, BYO Secret | ✅ | `Gateway` HTTPS listener, `tls.mode: Terminate`, `certificateRefs` |
| Routing api / well-known / frontend | ✅ | `HTTPRoute` rules + `backendRefs` |
| Identity rewrite (`rewrite-target /$1`) | ✅ | no filter needed (Gateway API forwards the path unchanged) |
| 7 security response headers | ✅ | `HTTPRoute` `ResponseHeaderModifier.set` (verbatim values) |
| Timeouts 3600s | ✅ | `HTTPRoute.timeouts` + `BackendTrafficPolicy.timeout.{tcp,http}` |
| Retry (`error timeout http_503`, 3 tries) | ✅ | `BackendTrafficPolicy.retry` (`connect-failure`,`reset` + `httpStatusCodes:[503]`) |
| Never passively eject (`upstream-max-fails:0`) | ✅ | **omit** `healthCheck.passive` (off by default in EG) |
| `proxy-buffering off` (streaming route) | ✅ | Envoy streams by default (no-op, correct outcome) |
| HTTP→HTTPS redirect | 🟡 | `RequestRedirect` **301** (Gateway API core only guarantees 301/302; nginx used **308**) |
| X-Original-URI to upstream | 🟡 | `RequestHeaderModifier` with EG-only `%REQ(...)%` value (non-portable; query-string inclusion needs live check) |
| gzip + brotli compression | 🟡 | `BackendTrafficPolicy.compression` — **no content-type allow-list** (compresses all above `minContentLength`) |
| Per-IP request rate limit | 🟡 | `BackendTrafficPolicy.rateLimit` — see [rate limiting](#rate-limiting) caveats |
| `burst-multiplier` | 🟡 | folded into request count; no burst-queue (shaping differs) |
| Per-IP **connection** limit (`limit-connections`) | ❌ | no per-source-IP connection counter in EG |
| ModSecurity / OWASP CRS WAF | ❌ | no native WAF; not rendered by the chart — manual Coraza Wasm add-on (see below) |
| Body-size limits (20MB / 2.6MB) | ❌ | only via the Coraza WAF add-on (not rendered by the chart) |
| Compression content-type allow-list | ❌ | not expressible without an `EnvoyPatchPolicy` |
| Numeric route priority | ❌ | no priority field — rely on rule ordering / match specificity |

---

## What cannot be migrated (and what we did instead)

### 1. Per-IP concurrent connection limit (`limit-connections 250 / 1000`, 503 on breach)
**Why.** Envoy Gateway has no per-source-IP concurrent-connection counter.
`ClientTrafficPolicy.connection.connectionLimit` is a **per-proxy/per-listener total**
(not per IP, not synced across replicas) and attaches to the Gateway, not a route — so
the distinct 250-vs-1000 caps can't be expressed. `circuitBreaker.maxConnections` caps
*total upstream* connections, also not per-IP. nginx returns 503; there's no equivalent.
**What we do.** Drop the connection dimension and lean on per-IP **request** rate limiting,
which covers the DDoS-floor intent. A blunt total cap via `ClientTrafficPolicy` is possible
but not rendered by the chart.

### 2. Compression content-type allow-list
**Why.** EG's `compression` exposes algorithm + `minContentLength` only; there's no
content-type list. Envoy decides by `Accept-Encoding` + size.
**What we do.** gzip + brotli are migrated fully; only the 10-item type gate is lost (EG
compresses everything above `minContentLength`). Strict gating would need an
`EnvoyPatchPolicy` — out of scope for a render-CRDs-only chart.

### 3. `burst-multiplier` (leaky-bucket burst queue)
**Why.** EG rate limiting is a fixed-window token bucket (`requests` + `unit`); there is no
`burst`/`nodelay` queue knob.
**What we do.** Fold the multiplier into a higher `requests` count (e.g. 50 rps ×5 → 250/s).
Shaping differs (instantaneous allowance vs nginx's queued delayed requests).

### 4. WAF (ModSecurity / OWASP CRS) + body-size limits
**Why.** Envoy Gateway ships **no** built-in WAF. Every WAF path is an add-on (Coraza
via Wasm/DynamicModule, or `SecurityPolicy.extAuth` to an external WAF), all `v1alpha1`,
needs a BYO artifact, and must be enabled in the controller config. The nginx body-size
limits (20MB/2.6MB) likewise only exist as Coraza `SecRequestBodyLimit` directives.
**What we do.** The chart does **not** render a WAF (keeping the gateway spec lean and
avoiding a half-wired feature with no artifact to point at). To add it, attach your own
`EnvoyExtensionPolicy` to the `<release>-api` / `<release>-frontend` HTTPRoutes loading a
Coraza proxy-wasm image, carrying the same SecLang rules as the nginx path (method
allow-list `900200`, triple-`/?`→403 `14854`, URI>4096→414 `14855`,
`SecRuleRemoveById 949110`, JSON audit log, body limits). The `common.modsecurity.snippet`
helper still holds those rules. This is a manual, validate-live integration — not a chart
toggle. Until then, the gateway path has **no WAF**, a known gap vs the nginx path.

### 5. Portable HTTP→HTTPS **308** redirect
**Why.** Gateway API core conformance only guarantees `301`/`302`; `307`/`308` are
*extended* support and not guaranteed across controllers/CRD bundles.
**What we do.** Default to **301** (permanent). Override with `gateway.httpsRedirectCode: 308`
if your EG build accepts it (validate). Behavioural delta: 301 may let very old clients
change method on the redirected request.

### 6. True per-IP rate limit without controller-side Redis
**Why.** Per-distinct-IP limiting needs `type: Global`, which depends on the Envoy
Ratelimit service + Redis enabled in the **controller's** config — infrastructure the chart
does not own. A `Global` policy stays unprogrammed if that's missing.
**What we do.** Default to `type: local` (zero infra). See caveats below. Set
`gateway.rateLimit.type: global` only if your controller already has RLS.

---

## Routing precedence (read this)

Gateway API has **no numeric priority** (nginx used `100` vs `10`). Precedence for
`Exact`/`PathPrefix` is deterministic (longest match wins), but for **`RegularExpression`
it is implementation-specific** and **not guaranteed across separate HTTPRoutes**.

Mitigation built into the chart: the streaming-download regex and the `/api` prefix are
**two rules in one `HTTPRoute`** with the regex as **rule 0** — within a single route,
ties resolve to the first matching rule, so the specific download path is claimed before
the broad `/api`. The same applies to `/.well-known` (rule 0) vs `/` (rule 1) in the
frontend route. **Validate actual ordering on EG v1.8.x** (curl the download path and
confirm it isn't shadowed).

> The streaming route in nginx disabled OWASP CRS for performance. Here it shares the
> api `HTTPRoute`, so if you attach the WAF it also covers the streaming rule (more secure,
> slightly slower). To exempt it, split the streaming rule into its own `HTTPRoute` and
> leave the WAF policy off it.

---

## Rate limiting

| Mode | Per-IP? | Infra | Behaviour |
|---|---|---|---|
| `local` (default) | ❌ | none | Per-Envoy-pod token bucket. Effective ceiling = `requests × proxy replica count`. Mirrors nginx's per-controller-replica behaviour. |
| `global` | ✅ | Redis RLS in controller | True per-source-IP (`sourceCIDR` `Distinct`). |

**Multi-replica caveat (local mode):** a `local` limit of 50 rps with 2 Envoy proxy
replicas allows up to ~100 rps cluster-wide, and the burst ×5 folding compounds it. If you
raise `gateway.proxy.replicas`, lower the per-pod `requests` proportionally or switch
to `global`.

Overflow returns **429** (Envoy's fixed code, matches nginx `limit-req-status-code`).

---

## Validation checklist (before production)

`helm unittest`/`helm template` validate rendering only — the `v1alpha1` policy CRDs and
route precedence must be checked on a **live Envoy Gateway v1.8.x** controller (minikube is
fine — see the live-test ritual in CLAUDE.md):

- [ ] `kubectl get gatewayclass <name>` is **Accepted** and the EG controller is running.
- [ ] Gateway becomes **Programmed**; the two listeners (443/80) are ready.
- [ ] All three HTTPRoutes report **Accepted** + **ResolvedRefs**.
- [ ] `curl https://<host>/api/anomalies/1/source-record/download` hits the API (regex rule
      wins over `/api`); `curl https://<host>/.well-known/x` hits the API; `curl https://<host>/`
      hits the frontend.
- [ ] HTTP→HTTPS redirect returns your chosen status (301 default).
- [ ] Security response headers + `X-Original-URI` are present (and `X-Original-URI` includes
      the query string when you add `?a=b`).
- [ ] `BackendTrafficPolicy` reports **Accepted** (rate limit / retry / compression applied).
      If `type: global`, confirm the controller's Redis RLS is enabled.
- [ ] `EnvoyProxy` is **Accepted** and the data-plane pods land where expected
      (`gateway.proxy.nodeSelector`/`tolerations`, `replicas`).
- [ ] Switching from nginx: delete the orphaned nginx `Ingress` objects (they are helm
      hook resources and may linger): `kubectl delete ingress -n <ns> -l app.kubernetes.io/instance=<release>` (verify names first).
