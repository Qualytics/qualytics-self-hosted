# Qualytics Docker Images - v2026.7.27

This guide lists the images used by Qualytics chart `2026.7.27`. The chart pulls them directly by default; use the mirroring steps when your organization requires an internal registry.

Qualytics provides the image registry token through a secure channel. This token only grants access to private container images; it is separate from the deployment identifier and platform license described in the [installation guide](../README.md#qualytics-provided-installation-configuration).

> **Confirm the tags for your chart version.** Image tags are pinned per chart release, so ask Helm instead of trusting this page if you are installing a different version:
>
> ```bash
> helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
> helm repo update
> CHART_VERSION="<version provided by Qualytics>"
> helm show values qualytics/qualytics --version "$CHART_VERSION" | grep -E "ImageUrl|ImageTag|imageUrl|imageTag"
> ```

## Qualytics Application Images (Required)

These are the core Qualytics images and must be pulled from Docker Hub using the credentials provided by your Qualytics account manager.

| Component | Image | Tag | Used by |
|---|---|---|---|
| Control Plane (API & CMD) | `qualyticsai/controlplane` | `20260727-96a50bc` | `qualytics-api` and `qualytics-cmd` Deployments |
| Data Plane (Spark) | `qualyticsai/dataplane` | `20260727-4c630c4` | `qualytics-spark` driver Deployment and every executor pod the driver creates |
| Frontend | `qualyticsai/frontend` | `20260727-0593cf2` | `qualytics-frontend` Deployment |

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

docker pull qualyticsai/controlplane:20260727-96a50bc
docker pull qualyticsai/dataplane:20260727-4c630c4
docker pull qualyticsai/frontend:20260727-0593cf2
```

## Infrastructure Images

These are publicly available images used by the Qualytics data tier and utilities.

| Component | Image | Tag | Required | Used by |
|---|---|---|---|---|
| RabbitMQ | `rabbitmq` | `4.3-management` | Yes | `qualytics-rabbitmq` StatefulSet |
| Busybox (init containers) | `busybox` | `latest` | Yes | RabbitMQ init containers, and the Spark driver init container when `dataplane.numVolumes > 0` |
| PostgreSQL | `postgres` | `17` | Only when `postgres.enabled: true` | `qualytics-postgres` StatefulSet, the snapshotter and maintenance CronJobs, and the `qualytics-psql` utility Deployment (kept at 0 replicas) |

> **Note:** PostgreSQL is optional. If you are using an external PostgreSQL datastore, set `postgres.enabled: false` in your `values.yaml` and skip this image. See [External PostgreSQL Setup](./external-postgres-setup.md).

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

> The ingress-nginx subchart pins these images **by digest** as well as by tag. Re-tagging them into a private registry changes the digest, so the mirrored values below must clear `digest` and `digestChroot` or the pods will fail to pull.

## Re-tagging for a Private Registry

After pulling, re-tag and push each image to your private registry. Example:

```bash
REGISTRY="your-registry.example.com"

# Qualytics images
docker tag qualyticsai/controlplane:20260727-96a50bc "$REGISTRY/qualyticsai/controlplane:20260727-96a50bc"
docker tag qualyticsai/dataplane:20260727-4c630c4 "$REGISTRY/qualyticsai/dataplane:20260727-4c630c4"
docker tag qualyticsai/frontend:20260727-0593cf2 "$REGISTRY/qualyticsai/frontend:20260727-0593cf2"

# Infrastructure images
docker tag rabbitmq:4.3-management "$REGISTRY/rabbitmq:4.3-management"
docker tag busybox:latest "$REGISTRY/busybox:latest"

# Only if using the built-in PostgreSQL
docker tag postgres:17 "$REGISTRY/postgres:17"

# Push all
docker push "$REGISTRY/qualyticsai/controlplane:20260727-96a50bc"
docker push "$REGISTRY/qualyticsai/dataplane:20260727-4c630c4"
docker push "$REGISTRY/qualyticsai/frontend:20260727-0593cf2"
docker push "$REGISTRY/rabbitmq:4.3-management"
docker push "$REGISTRY/busybox:latest"

# Only if using the built-in PostgreSQL
docker push "$REGISTRY/postgres:17"
```

Then point the chart at your registry. Every image location is a separate value, so all of these need updating — a missed one silently falls back to Docker Hub:

```yaml
global:
  imageUrls:
    controlplaneImageUrl: "your-registry.example.com/qualyticsai/controlplane"
    dataplaneImageUrl: "your-registry.example.com/qualyticsai/dataplane"
    frontendImageUrl: "your-registry.example.com/qualyticsai/frontend"

busybox:
  image:
    imageUrl: "your-registry.example.com/busybox"

rabbitmq:
  image:
    imageUrl: "your-registry.example.com/rabbitmq"

# Only when postgres.enabled: true
postgres:
  image:
    imageUrl: "your-registry.example.com/postgres"

# Only when nginx.enabled: true — clear the pinned digests, they no longer match
nginx:
  controller:
    image:
      registry: your-registry.example.com
      digest: ""
      digestChroot: ""
    admissionWebhooks:
      patch:
        image:
          registry: your-registry.example.com
          digest: ""
```

Image *tags* stay in `controlplaneImage.image.controlplaneImageTag`, `dataplaneImage.image.dataplaneImageTag`, and `frontendImage.image.frontendImageTag`; mirroring does not change them.

The `regcred` Secret is still referenced by every pod, so keep it in the namespace and point it at your private registry's credentials instead of Docker Hub.

### JDBC drivers resolved at runtime

Beyond container images, the Spark driver passes `dataplane.extraPackages` to `spark-submit --packages`, which Ivy resolves from Maven Central when the driver starts:

| Coordinate | Purpose |
|---|---|
| `com.teradata.jdbc:terajdbc:20.00.00.56` | Teradata datastore connectivity |
| `com.ibm.db2:jcc:12.1.4.0` | IBM DB2 datastore connectivity |

If your cluster has no route to Maven Central, resolve these coordinates from an internal Maven repository (JFrog Artifactory, Sonatype Nexus, …) instead by setting `dataplane.ivySettingsSecret` — see [Resolving JDBC Drivers from an Internal Maven Repository](./custom-maven-repository.md). Mirroring the container images alone does not cover these artifacts. Deployments that do not use Teradata or DB2 can drop the coordinates they do not need from `dataplane.extraPackages`.

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
