# Qualytics Docker Images - v2026.7.21

This guide lists the images used by Qualytics chart `2026.7.21`. The chart pulls them directly by default; use the mirroring steps when your organization requires an internal registry.

Qualytics provides the image registry token through a secure channel. This token only grants access to private container images; it is separate from the deployment identifier and platform license described in the [installation guide](../README.md#qualytics-provided-installation-configuration).

## Qualytics Application Images (Required)

These are the core Qualytics images and must be pulled from Docker Hub using the credentials provided by your Qualytics account manager.

| Component | Image | Tag |
|---|---|---|
| Control Plane (API & CMD) | `qualyticsai/controlplane` | `20260721-6961853` |
| Data Plane (Spark) | `qualyticsai/dataplane` | `20260721-1b98096` |
| Frontend | `qualyticsai/frontend` | `20260721-8ee8b05` |

### Pull commands

Read the registry token without placing it in shell history, then authenticate with Docker's standard input:

```bash
printf "Qualytics registry token: "
IFS= read -rs QUALYTICS_REGISTRY_TOKEN
echo
printf '%s' "$QUALYTICS_REGISTRY_TOKEN" | docker login \
  --username qualyticsai \
  --password-stdin
unset QUALYTICS_REGISTRY_TOKEN

docker pull qualyticsai/controlplane:20260721-6961853
docker pull qualyticsai/dataplane:20260721-1b98096
docker pull qualyticsai/frontend:20260721-8ee8b05
```

## Infrastructure Images

These are publicly available images used by the Qualytics data tier and utilities.

| Component | Image | Tag | Required |
|---|---|---|---|
| RabbitMQ | `rabbitmq` | `4.3-management` | Yes |
| Busybox (init containers) | `busybox` | `latest` | Yes |
| PostgreSQL | `postgres` | `17` | Only when `postgres.enabled: true` |

> **Note:** PostgreSQL is optional. If you are using an external PostgreSQL datastore, set `postgres.enabled: false` in your `values.yaml` and skip this image.

### Pull commands

```bash
docker pull rabbitmq:4.3-management
docker pull busybox:latest

# Only if using the built-in PostgreSQL (postgres.enabled: true)
docker pull postgres:17
```

## Dependency Chart Images

### Ingress NGINX (Optional - when `nginx.enabled: true`)

| Component | Image |
|---|---|
| Controller | `registry.k8s.io/ingress-nginx/controller:v1.15.1` |
| Webhook Certgen | `registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9` |

```bash
docker pull registry.k8s.io/ingress-nginx/controller:v1.15.1
docker pull registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9
```

## Re-tagging for a Private Registry

After pulling, re-tag and push each image to your private registry. Example:

```bash
REGISTRY="your-registry.example.com"

# Qualytics images
docker tag qualyticsai/controlplane:20260721-6961853 "$REGISTRY/qualyticsai/controlplane:20260721-6961853"
docker tag qualyticsai/dataplane:20260721-1b98096 "$REGISTRY/qualyticsai/dataplane:20260721-1b98096"
docker tag qualyticsai/frontend:20260721-8ee8b05 "$REGISTRY/qualyticsai/frontend:20260721-8ee8b05"

# Infrastructure images
docker tag rabbitmq:4.3-management "$REGISTRY/rabbitmq:4.3-management"
docker tag busybox:latest "$REGISTRY/busybox:latest"

# Only if using the built-in PostgreSQL
docker tag postgres:17 "$REGISTRY/postgres:17"

# Push all
docker push "$REGISTRY/qualyticsai/controlplane:20260721-6961853"
docker push "$REGISTRY/qualyticsai/dataplane:20260721-1b98096"
docker push "$REGISTRY/qualyticsai/frontend:20260721-8ee8b05"
docker push "$REGISTRY/rabbitmq:4.3-management"
docker push "$REGISTRY/busybox:latest"

# Only if using the built-in PostgreSQL
docker push "$REGISTRY/postgres:17"
```

Then update your `values.yaml` to point the `imageUrl` fields to your private registry (e.g., `your-registry.example.com/qualyticsai/controlplane`).

## Installation

### 1. Create the namespace and registry secret

Use the registry token provided via secure message:

```bash
kubectl create namespace qualytics
printf "Qualytics registry token: "
IFS= read -rs QUALYTICS_REGISTRY_TOKEN
echo
kubectl create secret docker-registry regcred -n qualytics \
  --docker-username=qualyticsai \
  --docker-password="$QUALYTICS_REGISTRY_TOKEN"
unset QUALYTICS_REGISTRY_TOKEN
```

### 2. Configure the deployment identifier

Every deployment requires its own identifier from Qualytics. Paste it into the `values.yaml` used for this installation; do not base64-encode or reuse it:

```yaml
secrets:
  deployment:
    identifier: "<provided by Qualytics>"
```

### 3. Install Qualytics

```bash
helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
helm repo update

CHART_VERSION="<version provided by Qualytics>"

helm upgrade --install qualytics qualytics/qualytics \
  --namespace qualytics \
  --create-namespace \
  --version "$CHART_VERSION" \
  -f values.yaml \
  --wait \
  --timeout=5m
```
