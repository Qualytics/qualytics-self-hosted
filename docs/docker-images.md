# Qualytics Docker Images - v2026.11.25

This guide lists the images used by Qualytics chart `2026.11.25`. The chart pulls them directly by default; use the mirroring steps when your organization requires an internal registry.

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
| Control Plane (API & CMD) | `qualyticsai/controlplane` | `20261124-0ea3d35` | `qualytics-api` and `qualytics-cmd` Deployments |
| Data Plane (Spark) | `qualyticsai/dataplane` | `20261124-67804c2` | `qualytics-dataplane` driver Deployment and every executor pod the driver creates |
| Frontend | `qualyticsai/frontend` | `20261124-7ce5fc4` | `qualytics-frontend` Deployment |

### Pull commands

An authentication token will be provided separately via secure message. Alongside it,
Qualytics also provides your **deployment identifier** — a signed token that identifies this
deployment to Qualytics-hosted services (for example the Qualytics LLM provider for AgentQ).
Set it as `secrets.deployment.identifier` in your values file; it is required — the
control plane will not start without a signed, valid identifier — and each deployment
must use its own. Contact Qualytics support if you have not received yours.

Read the registry token without placing it in shell history, then authenticate with Docker's standard input:

```bash
printf "Qualytics registry token: "
IFS= read -rs QUALYTICS_REGISTRY_TOKEN
echo
printf '%s' "$QUALYTICS_REGISTRY_TOKEN" | docker login \
  --username qualyticsai \
  --password-stdin
unset QUALYTICS_REGISTRY_TOKEN

docker pull qualyticsai/controlplane:20261124-0ea3d35
docker pull qualyticsai/dataplane:20261124-67804c2
docker pull qualyticsai/frontend:20261124-7ce5fc4
```

## Infrastructure Images

These are publicly available images used by the Qualytics data tier and utilities.

| Component | Image | Tag | Required | Used by |
|---|---|---|---|---|
| RabbitMQ | `rabbitmq` | `4.3-management` | Yes | `qualytics-rabbitmq` StatefulSet |
| Busybox (init containers) | `busybox` | `latest` | Yes | RabbitMQ init containers |
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
| Controller | `docker.io/qualyticsai/ingress-nginx-controller:v1.30.8-qualytics.1` |
| Chroot controller (when `nginx.controller.image.chroot: true`) | `docker.io/qualyticsai/ingress-nginx-controller-chroot:v1.30.8-qualytics.1` |
| Webhook Certgen | `registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9` |

```bash
docker pull docker.io/qualyticsai/ingress-nginx-controller:v1.30.8-qualytics.1
docker pull registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9
```

When upgrading from `2026.11.24` or earlier, pass your original `-f values.yaml` or use `--reset-then-reuse-values` to apply stored overrides to the new chart defaults. Helm's `--reuse-values` carries the old controller image forward. If your values explicitly pin a controller, update that pin to select the Qualytics build.

For a private mirror, copy the applicable Qualytics controller image to your registry before the upgrade. The webhook certificate jobs continue to use the upstream certgen image.

To use a compatible replacement controller, set `registry`, `image`, `tag`, and the replacement image's published `digest` under `nginx.controller.image`. If your values use a full `repository` override, update it along with the tag and digest. With `chroot: true`, set `digestChroot` to the digest of the chroot build. A full `repository` override must name that build explicitly.

## Re-tagging for a Private Registry

After pulling, re-tag and push each image to your private registry. Example:

```bash
REGISTRY="your-registry.example.com"

# Qualytics images
docker tag qualyticsai/controlplane:20261124-0ea3d35 "$REGISTRY/qualyticsai/controlplane:20261124-0ea3d35"
docker tag qualyticsai/dataplane:20261124-67804c2 "$REGISTRY/qualyticsai/dataplane:20261124-67804c2"
docker tag qualyticsai/frontend:20261124-7ce5fc4 "$REGISTRY/qualyticsai/frontend:20261124-7ce5fc4"

# Infrastructure images
docker tag rabbitmq:4.3-management "$REGISTRY/rabbitmq:4.3-management"
docker tag busybox:latest "$REGISTRY/busybox:latest"

# Only if using the built-in PostgreSQL
docker tag postgres:17 "$REGISTRY/postgres:17"

# Push all
docker push "$REGISTRY/qualyticsai/controlplane:20261124-0ea3d35"
docker push "$REGISTRY/qualyticsai/dataplane:20261124-67804c2"
docker push "$REGISTRY/qualyticsai/frontend:20261124-7ce5fc4"
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

# Only when nginx.enabled is true. A byte-for-byte mirror keeps the pinned
# manifest digest. If the mirror changes the manifest, set its new digest.
nginx:
  imagePullSecrets:
    - name: regcred
  controller:
    image:
      registry: your-registry.example.com
    admissionWebhooks:
      patch:
        image:
          registry: your-registry.example.com
```

Image *tags* stay in `controlplaneImage.image.controlplaneImageTag`, `dataplaneImage.image.dataplaneImageTag`, and `frontendImage.image.frontendImageTag`; mirroring does not change them.

Qualytics workloads use `global.imagePullSecrets` (default `["regcred"]`). The optional ingress controller and webhook jobs use `nginx.imagePullSecrets`, a list of objects with a `name` field as shown above.

- **Registry requires credentials**: keep the default and point the `regcred` Secret at your private registry's credentials instead of Docker Hub — or create a Secret with a different name and list it here.
- **Registry allows unauthenticated pulls** (e.g. an anonymous internal Artifactory): set `global.imagePullSecrets: []` and leave `nginx.imagePullSecrets` empty.

```yaml
global:
  imagePullSecrets: []
```

### JDBC drivers resolved at runtime

Beyond container images, the Spark driver passes `dataplane.extraPackages` to `spark-submit --packages`, which Ivy resolves from Maven Central when the driver starts:

| Coordinate | Purpose |
|---|---|
| `com.teradata.jdbc:terajdbc:20.00.00.56` | Teradata datastore connectivity |
| `com.ibm.db2:jcc:12.1.4.0` | IBM DB2 datastore connectivity |

If your cluster has no route to Maven Central, resolve these coordinates from an internal Maven repository (JFrog Artifactory, Sonatype Nexus, …) instead via `dataplane.ivy` — see [Resolving JDBC Drivers from an Internal Maven Repository](./custom-maven-repository.md). Mirroring the container images alone does not cover these artifacts. Deployments that do not use Teradata or DB2 can drop the coordinates they do not need from `dataplane.extraPackages`.

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
