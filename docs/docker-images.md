# Qualytics Docker Images - v2026.6.20

Complete list of Docker images required for a Qualytics self-hosted deployment. These images must be pulled and uploaded to your private container registry before installation.

## Qualytics Application Images (Required)

These are the core Qualytics images and must be pulled from Docker Hub using the credentials provided by your Qualytics account manager.

| Component | Image | Tag |
|---|---|---|
| Control Plane (API & CMD) | `qualyticsai/controlplane` | `20260620-774e708` |
| Data Plane (Spark) | `qualyticsai/dataplane` | `20260620-d90297f` |
| Frontend | `qualyticsai/frontend` | `20260620-c7f6fdd` |

### Pull commands

An authentication token will be provided separately via secure message.

```bash
docker login -u qualyticsai -p <token>

docker pull qualyticsai/controlplane:20260620-774e708
docker pull qualyticsai/dataplane:20260620-d90297f
docker pull qualyticsai/frontend:20260620-c7f6fdd
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
docker tag qualyticsai/controlplane:20260620-774e708 $REGISTRY/qualyticsai/controlplane:20260620-774e708
docker tag qualyticsai/dataplane:20260620-d90297f $REGISTRY/qualyticsai/dataplane:20260620-d90297f
docker tag qualyticsai/frontend:20260620-c7f6fdd $REGISTRY/qualyticsai/frontend:20260620-c7f6fdd

# Infrastructure images
docker tag rabbitmq:4.3-management $REGISTRY/rabbitmq:4.3-management
docker tag busybox:latest $REGISTRY/busybox:latest

# Only if using the built-in PostgreSQL
docker tag postgres:17 $REGISTRY/postgres:17

# Push all
docker push $REGISTRY/qualyticsai/controlplane:20260620-774e708
docker push $REGISTRY/qualyticsai/dataplane:20260620-d90297f
docker push $REGISTRY/qualyticsai/frontend:20260620-c7f6fdd
docker push $REGISTRY/rabbitmq:4.3-management
docker push $REGISTRY/busybox:latest

# Only if using the built-in PostgreSQL
docker push $REGISTRY/postgres:17
```

Then update your `values.yaml` to point the `imageUrl` fields to your private registry (e.g., `your-registry.example.com/qualyticsai/controlplane`).

## Installation

### 1. Create the namespace and registry secret

Use the authentication token provided via secure message:

```bash
kubectl create namespace qualytics
kubectl create secret docker-registry regcred -n qualytics \
  --docker-username=qualyticsai \
  --docker-password=<token>
```

### 2. Install Qualytics v2026.6.20

```bash
helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
helm repo update
helm upgrade --install qualytics qualytics/qualytics \
  --namespace qualytics \
  --create-namespace \
  --version 2026.6.20 \
  -f values.yaml \
  --wait \
  --timeout=5m
```
