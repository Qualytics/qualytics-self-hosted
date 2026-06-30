# Ingress TLS — Bring Your Own Certificate

The Qualytics chart expects TLS certificates to be provided as standard Kubernetes `tls` Secrets in the release namespace. You control where certificates come from — corporate CA, Let's Encrypt managed outside the chart, cloud-provider managed certs, service mesh, etc. — and the chart mounts the Secret(s) you create.

This page shows the three supported patterns.

## What Secrets the chart expects

| Feature toggle | Secret name referenced by the chart | Needed when |
|---|---|---|
| `ingress.enabled: true` | `ingress.tls.secretName` (when set) **or** `ingress.tls.apiSecretName` (defaults to `api-tls-cert`) | Always |
| `ingress.enabled: true` | `ingress.tls.secretName` (when set) **or** `ingress.tls.frontendSecretName` (defaults to `frontend-tls-cert`) | Always |
| `postgres.tls.enabled: true` | `postgres-tls` | Only when enabling in-pod TLS for the bundled PostgreSQL |
| `rabbitmq.tls.enabled: true` | `rabbitmq-tls` | Only when enabling AMQPS on 5671 |

**Precedence rule for the ingress TLS Secret**:
1. If `ingress.tls.secretName` is set (non-empty), that Secret is used by **both** the API and frontend ingresses.
2. Otherwise, the chart uses `ingress.tls.apiSecretName` for the API ingress and `ingress.tls.frontendSecretName` for the frontend ingress. These default to `api-tls-cert` and `frontend-tls-cert` so existing installs keep working with no values changes.

All four are standard `kubernetes.io/tls` Secrets with a PEM-encoded cert + private key.

---

## Pattern 1 — Single shared certificate (recommended for new deployments)

One wildcard or SAN certificate served by both the API and frontend ingresses. Fewer Secrets to manage, fewer places for rotations to go stale.

```bash
kubectl create secret tls qualytics-tls-cert -n qualytics \
  --cert=./fullchain.pem \
  --key=./privkey.pem
```

```yaml
# values.yaml
ingress:
  enabled: true
  tls:
    secretName: qualytics-tls-cert
```

When `secretName` is set, it takes precedence over `apiSecretName` and `frontendSecretName` — both ingresses use the shared Secret regardless of what the per-ingress fields are set to. The DNS record is the same for both ingresses, so a SAN or wildcard cert is a natural fit.

---

## Pattern 2 — Separate certificates per ingress

If you want a distinct Secret for each ingress — for example, different certs issued to different hostnames, or independent rotation schedules — create two Secrets and leave `ingress.tls.secretName` empty. With no shared Secret set, the chart uses the per-ingress Secret names, which default to `api-tls-cert` and `frontend-tls-cert`:

```bash
kubectl create secret tls api-tls-cert -n qualytics \
  --cert=./api-fullchain.pem --key=./api-privkey.pem
kubectl create secret tls frontend-tls-cert -n qualytics \
  --cert=./frontend-fullchain.pem --key=./frontend-privkey.pem
```

```yaml
# values.yaml — no ingress.tls settings needed; chart uses the default Secret names
ingress:
  enabled: true
```

To use different Secret names, override the per-ingress fields:

```yaml
ingress:
  enabled: true
  tls:
    apiSecretName: my-api-cert
    frontendSecretName: my-frontend-cert
```

If you want explicit names that differ from the defaults:

```yaml
ingress:
  enabled: true
  tls:
    apiSecretName: my-api-cert
    frontendSecretName: my-frontend-cert
```

---

## Pattern 3 — TLS terminated upstream (cloud LB / service mesh)

If your cloud load balancer or Istio/Linkerd gateway handles TLS, skip the chart's ingress entirely:

```yaml
ingress:
  enabled: false
```

Route traffic from the external TLS-terminating hop to the `qualytics-api-service` and `qualytics-frontend-service` ClusterIP Services directly.

---

## PostgreSQL / RabbitMQ in-pod TLS

Both are off by default. When enabled, the chart mounts a pre-existing Secret into the pod — you create it yourself:

```bash
kubectl create secret tls postgres-tls -n qualytics \
  --cert=./postgres-fullchain.pem --key=./postgres-privkey.pem

kubectl create secret tls rabbitmq-tls -n qualytics \
  --cert=./rabbitmq-fullchain.pem --key=./rabbitmq-privkey.pem
```

```yaml
postgres:
  tls:
    enabled: true
rabbitmq:
  tls:
    enabled: true
```

Since both services are reached through an in-cluster `Service` (not through the public ingress), most single-tenant deployments on a private VPC treat pod-to-pod traffic as implicit-trust and leave these off.

---

## Rotation

A Secret update is picked up by the ingress controller automatically (nginx reloads on Secret change). For postgres/rabbitmq, roll the StatefulSet pod(s) after updating the Secret so the new cert is read at container start:

```bash
kubectl -n qualytics rollout restart statefulset/qualytics-postgres
kubectl -n qualytics rollout restart statefulset/qualytics-rabbitmq
```

## Troubleshooting

**`secret "<name>" not found` at `helm install`**
Helm doesn't fail on missing Secret at install time — nginx reports it when the ingress is probed. Create the Secret before (or simultaneously with) the Helm release.

**Browser warns about certificate name mismatch**
Confirm the Secret's cert covers `global.dnsRecord` (the `CN` or a `subjectAltName`). Wildcards must match the exact label depth of the hostname.

**HTTP 421 "Misdirected Request"**
nginx strict SNI rejection — usually means you pointed more than one ingress host at the same SNI cert. Either add a SAN to the cert, or split back to per-ingress Secrets via `ingress.tls.apiSecretName` / `frontendSecretName`.
