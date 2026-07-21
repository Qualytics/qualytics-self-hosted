# Qualytics Docker Images

The Qualytics Helm chart pulls these images directly by default. Use this guide when your organization needs to mirror them into an internal registry before installation. For a published deployment, use the chart version provided by Qualytics; `main` may contain changes awaiting the next release.

Qualytics provides the image registry token through a secure channel. This token only grants access to private container images; it is separate from the deployment identifier and platform license described in the [installation guide](../README.md#qualytics-issued-installation-credentials).

## Qualytics Application Images (Required)

These are the core Qualytics images and must be pulled from Docker Hub using the credentials provided by your Qualytics account manager.

| Component | Image | Tag |
|---|---|---|
| Control Plane (API & CMD) | `qualyticsai/controlplane` | `20260710-2bbb2d6` |
| Data Plane (Spark) | `qualyticsai/dataplane` | `20260710-a8a46c2` |
| Frontend | `qualyticsai/frontend` | `20260710-bc0933e` |

### Pull commands

Read the registry token without placing it in shell history, then authenticate with Docker's standard input:

```bash
read -rsp "Qualytics registry token: " QUALYTICS_REGISTRY_TOKEN && echo
printf '%s' "$QUALYTICS_REGISTRY_TOKEN" | docker login \
  --username qualyticsai \
  --password-stdin
unset QUALYTICS_REGISTRY_TOKEN

docker pull qualyticsai/controlplane:20260710-2bbb2d6
docker pull qualyticsai/dataplane:20260710-a8a46c2
docker pull qualyticsai/frontend:20260710-bc0933e
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
docker tag qualyticsai/controlplane:20260710-2bbb2d6 "$REGISTRY/qualyticsai/controlplane:20260710-2bbb2d6"
docker tag qualyticsai/dataplane:20260710-a8a46c2 "$REGISTRY/qualyticsai/dataplane:20260710-a8a46c2"
docker tag qualyticsai/frontend:20260710-bc0933e "$REGISTRY/qualyticsai/frontend:20260710-bc0933e"

# Infrastructure images
docker tag rabbitmq:4.3-management "$REGISTRY/rabbitmq:4.3-management"
docker tag busybox:latest "$REGISTRY/busybox:latest"

# Only if using the built-in PostgreSQL
docker tag postgres:17 "$REGISTRY/postgres:17"

# Push all
docker push "$REGISTRY/qualyticsai/controlplane:20260710-2bbb2d6"
docker push "$REGISTRY/qualyticsai/dataplane:20260710-a8a46c2"
docker push "$REGISTRY/qualyticsai/frontend:20260710-bc0933e"
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
read -rsp "Qualytics registry token: " QUALYTICS_REGISTRY_TOKEN && echo
kubectl create secret docker-registry regcred -n qualytics \
  --docker-username=qualyticsai \
  --docker-password="$QUALYTICS_REGISTRY_TOKEN"
unset QUALYTICS_REGISTRY_TOKEN
```

### 2. Install Qualytics

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
