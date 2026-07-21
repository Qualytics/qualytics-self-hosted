# CLAUDE.md - Qualytics Helm Chart Guidelines

## Project Overview

This Helm chart deploys a single-tenant instance of the Qualytics data quality platform to a CNCF-compliant Kubernetes cluster. The deployment includes:

- **Control Plane**: API service and CMD background processor
- **Data Plane**: Apache Spark 4.1.1 driver as a native `Deployment` running `spark-submit` in client mode; executor pods created directly via the Kubernetes API (dynamic executor scaling 1-12). No spark-operator dependency.
- **Frontend**: Web UI
- **Data Tier**: PostgreSQL 17 and RabbitMQ 4.3
- **Infrastructure**: Ingress with ModSecurity WAF, BYO TLS certificates (customer-provided Secret), platform-specific storage classes (AWS/GCP/Azure)
- **Dependencies**: nginx-ingress 4.15.1 (TLS is BYO — customer-provided `kubernetes.io/tls` Secret, see [docs/ingress-tls.md](docs/ingress-tls.md))

The current chart and application versions are defined in `charts/qualytics/Chart.yaml`.

## Directory Structure

```
qualytics-self-hosted/
├── README.md                           # User-facing deployment documentation (incl. Mermaid architecture diagram)
├── template.values.yaml                # Simplified customer configuration template
├── LICENSE                             # License file
└── charts/qualytics/
    ├── Chart.yaml                      # Chart metadata and dependencies
    ├── values.yaml                     # Complete default configuration
    ├── charts/                         # Packaged chart dependencies (.tgz)
    │   └── ingress-nginx-4.15.1.tgz    # NGINX ingress controller
    ├── templates/                      # template files + helpers
    │   ├── _helpers.tpl                # Template helper functions
    │   ├── api.yaml                    # API deployment & service
    │   ├── cmd.yaml                    # CMD processor deployment
    │   ├── spark.yaml                  # Spark dataplane: SA+Role+RoleBinding+ConfigMap+Service+Deployment
    │   ├── frontend.yaml               # Frontend deployment & service
    │   ├── postgres.yaml               # PostgreSQL statefulset + PVC
    │   ├── rabbitmq.yaml               # RabbitMQ statefulset + PVC
    │   ├── secrets.yaml                # Secrets for credentials
    │   ├── ingress.yaml                # Ingress with WAF (TLS is BYO Secret)
    │   ├── psql.yaml                   # PostgreSQL utility pod
    │   └── storage-classes.yaml        # Platform-specific storage classes
    └── tests/                          # Helm unit tests
        ├── api_test.yaml               # API deployment tests
        ├── cmd_test.yaml               # CMD processor tests
        ├── spark_test.yaml             # Spark application tests
        ├── frontend_test.yaml          # Frontend deployment tests
        ├── ingress_test.yaml           # Ingress tests
        ├── postgres_test.yaml          # PostgreSQL statefulset tests
        ├── psql_test.yaml              # PostgreSQL utility pod tests
        ├── rabbitmq_test.yaml          # RabbitMQ tests
        ├── secrets_test.yaml           # Secrets configuration tests
        ├── storage_classes_test.yaml   # Storage class tests
        ├── templates_test.yaml         # Template helpers tests
        └── global_test.yaml            # Global configuration tests
```

## Commands

### Development & Testing
- **Lint chart**: `helm lint charts/qualytics -f template.values.yaml -f charts/qualytics/tests/values/deployment-identifier.yaml`
- **Run unit tests**: `helm unittest charts/qualytics` (requires helm-unittest plugin)
- **Template chart**: `helm template qualytics charts/qualytics -f template.values.yaml -f charts/qualytics/tests/values/deployment-identifier.yaml`
- **Validate manifests**: `helm template qualytics charts/qualytics -f template.values.yaml -f charts/qualytics/tests/values/deployment-identifier.yaml | kubectl apply --dry-run=client -f -`
- **Package chart**: `helm package charts/qualytics`

### Installation & Updates
- **Add repository**: `helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted`
- **Set chart version**: `CHART_VERSION="<version provided by Qualytics>"`
- **Install chart**: `helm upgrade --install qualytics qualytics/qualytics --namespace qualytics --create-namespace --version "$CHART_VERSION" -f values.yaml --wait --timeout=5m`
- **Upgrade release**: `helm upgrade qualytics qualytics/qualytics --namespace qualytics --version "$CHART_VERSION" -f values.yaml --wait --timeout=5m`

- **Uninstall release**: `helm uninstall qualytics --namespace qualytics`
- **List releases**: `helm list --namespace qualytics`

### Kubernetes Management
- **Check pods**: `kubectl get pods -n qualytics`
- **View logs**: `kubectl logs -f deployment/qualytics-api -n qualytics`
- **Restart deployments**:
  - `kubectl rollout restart deployment/qualytics-api -n qualytics`
  - `kubectl rollout restart deployment/qualytics-cmd -n qualytics`
- **Get ingress IP**: `kubectl get svc -n qualytics qualytics-nginx-controller`
- **Check all resources**: `kubectl get all -n qualytics`

## Helm Testing

This chart uses **helm-unittest** plugin for comprehensive unit testing:

### Test Structure
- **Location**: `/charts/qualytics/tests/*_test.yaml` files
- **Coverage**: 12 test suites covering all major components
- **Framework**: YAML-based assertions with helm-unittest plugin
- **Installation**: `helm plugin install https://github.com/helm-unittest/helm-unittest`

### Test Components
Each component has a corresponding test file:
- `api_test.yaml` - API deployment & service tests (168 lines, 10+ test cases)
- `cmd_test.yaml` - CMD processor tests
- `spark_test.yaml` - Spark dataplane tests (Deployment + RBAC + Service + ConfigMap)
- `frontend_test.yaml` - Frontend deployment tests
- `ingress_test.yaml` - Ingress tests
- `postgres_test.yaml` - PostgreSQL statefulset tests
- `psql_test.yaml` - PostgreSQL utility pod tests
- `rabbitmq_test.yaml` - RabbitMQ tests
- `secrets_test.yaml` - Secrets configuration tests
- `storage_classes_test.yaml` - Storage class tests
- `templates_test.yaml` - Template helper function tests
- `global_test.yaml` - Global configuration tests

### Common Test Patterns
```yaml
suite: test [component] deployment
templates:
  - [component].yaml
tests:
  - it: should create [component] deployment with correct name
    asserts:
      - isKind:
          of: Deployment
        documentIndex: 0
      - equal:
          path: metadata.name
          value: RELEASE-NAME-[component]
        documentIndex: 0
```

### Test Assertions Include
- Document count validation (`hasDocuments`)
- Resource kind verification (`isKind`)
- Naming convention checks (`equal` on `metadata.name`)
- Replica count validation
- Image configuration verification
- Environment variable presence (`contains`, `notContains`)
- Resource request/limit checks
- Conditional logic testing (enabled/disabled features)
- Document index-based assertions for multi-document templates

### Running Tests
```bash
# Run all tests
helm unittest charts/qualytics

# Run specific test suite
helm unittest -f 'tests/api_test.yaml' charts/qualytics

# Run with verbose output
helm unittest -v charts/qualytics
```

### Live-testing on Minikube

`helm unittest` validates rendered YAML. It can't observe things that only happen at runtime:

- Helm hook ordering and `hook-weight` execution
- `Secret` / `ConfigMap` lookups
- `Service` endpoint population timing
- `Job` completion vs timeout
- Multi-release upgrades (reconciliation behavior)

This section is how to verify all of that against a real Kubernetes cluster before shipping a release. This pattern was used to validate the cert-manager removal, the BYO TLS Secret precedence, the postgres connection-URL sslmode logic, the Spark pod-template migration, and the native-Deployment dataplane migration that replaced the spark-operator.

#### Prerequisites

| Tool | Version | Why |
|---|---|---|
| `minikube` | any recent | local cluster driver |
| `kubectl` | 1.28+ | standard |
| `helm` | 3.12+ | chart install |
| `openssl` | any | for generating throwaway certs when exercising TLS |

#### Core pattern

1. Start a fresh minikube matching the customer-facing Kubernetes version.
2. Write a **stripped-down values file to `/tmp/`** — never into the repo.
3. `helm install` that values file and exercise features.
4. **Upgrade in-place** (`helm upgrade`) to iterate through scenarios. Much faster than uninstall/install.
5. **Cleanup ritual** at the end, every time.

**Why stripped-down values?** A full install needs private image pulls (`qualyticsai/*`), Auth0 config, 100 GiB PVCs, and customer-specific secrets. A smoke test doesn't. The trick is to disable or replace every such dependency while keeping the *template logic under test* intact.

**Knobs to routinely flip:**

| Value | Setting | Why |
|---|---|---|
| `postgres.enabled` | `false` | Skip the 100 GiB StatefulSet + PVC |
| `rabbitmq.pvc.enabled` | `false` | `emptyDir` instead of a PVC |
| `controlplane.replicas` | `0` | Deployment becomes Available instantly, no image pull |
| `frontend.replicas` | `0` | Same |
| `global.imageUrls.*ImageUrl` | `nginx` | Public placeholder; lets `helm install` succeed without `regcred`. Pods that *do* start will CrashLoopBackOff — fine if not testing with `--wait` |
| `ingress.enabled` | `false` for core tests, `true` when exercising ingress TLS | Ingress needs `nginx.enabled=true` + real Secrets to be meaningful |
| `dataplane.driver.*` / `executor.*` | `cores: 1, memory: "512m"` | Keep small so minikube can schedule |

#### Baseline values file

Keep this in `/tmp/` — it is **not** committed to the repo. It evolves as the chart does; this is a snapshot.

```yaml
# /tmp/qualytics-baseline-values.yaml
nginx:
  enabled: false
ingress:
  enabled: false
postgres:
  enabled: false
controlplane:
  replicas: 0
  smtp:
    enabled: false
frontend:
  replicas: 0
global:
  platform: "aws"
  deploymentMode: "kubernetes"
  dnsRecord: "test.local"
  authType: "AUTH0"
  imageUrls:
    controlplaneImageUrl: "nginx"
    dataplaneImageUrl: "nginx"
    frontendImageUrl: "nginx"
controlplaneImage:
  image:
    controlplaneImageTag: "latest"
dataplaneImage:
  image:
    dataplaneImageTag: "latest"
frontendImage:
  image:
    frontendImageTag: "latest"
dataplane:
  enabled: true
  sparkVersion: "4.1.1"
  numVolumes: -1
  driver:
    cores: 1
    memory: "512m"
  executor:
    instances: 1
    cores: 1
    memory: "512m"
  dynamicAllocation:
    enabled: true
    initialExecutors: 1
    minExecutors: 1
    maxExecutors: 1
secrets:
  deployment:
    identifier: test-deployment-identifier
  auth0:
    auth0_domain: auth.test.local
    auth0_audience: test
    auth0_organization: org_test
    auth0_spa_client_id: test
  auth:
    jwt_signing_secret: test
  postgres:
    host: external.test.local
    port: 5432
    database: qualytics
    username: qualytics
    password: test
    secrets_passphrase: test
  rabbitmq:
    rabbitmq_password: test
  smtp:
    smtp_sender_user: test
    smtp_sender_password: test
rabbitmq:
  pvc:
    enabled: false
```

#### Run sheet

**1. Start minikube**

```bash
minikube start --kubernetes-version=v1.35.0
kubectl config current-context    # expect: minikube
```

Match the version to what production customers use. Bump when the target moves.

**2. Baseline install**

```bash
helm upgrade --install qualytics charts/qualytics \
  -n qualytics --create-namespace \
  -f /tmp/qualytics-baseline-values.yaml \
  --timeout=10m
```

Notice: no `--wait`. Intentional when exercising hook timing. Add `--wait` if testing that a rollout actually reaches `Available`.

**3. Verify the things unit tests can't**

```bash
# Driver Deployment, headless Service, executor pod template ConfigMap
kubectl -n qualytics get deployment,svc,cm,sa,role,rolebinding -l app=qualytics-spark

# The driver pod (random suffix) — use the label, not a hardcoded name
kubectl -n qualytics get pod -l app=qualytics-spark,spark-role=driver

# Executor pod template content as actually mounted into the driver
kubectl -n qualytics get cm qualytics-spark-executor-template \
  -o jsonpath='{.data.executor-template\.yaml}'

# Driver SA can create executor pods (RBAC sanity)
kubectl auth can-i create pods \
  --as=system:serviceaccount:qualytics:qualytics-spark -n qualytics

# Helper-template output (sslmode) landed in the rendered Secret
kubectl -n qualytics get secret qualytics-creds \
  -o jsonpath='{.data.connection_url}' | base64 -d; echo

# Confirm operator/CRD is actually gone (no SparkApplication in the namespace)
kubectl -n qualytics get sparkapplication 2>&1 | head -3
```

**4. Iterate with `helm upgrade`**

Instead of uninstall/install between scenarios, just re-`helm upgrade` with different `--set` overrides. Helm tracks the release and only changes what differs.

**5. Scrape state with `custom-columns`**

Much cleaner than piping `-o yaml` through `grep`:

```bash
kubectl -n qualytics get ingress \
  -o 'custom-columns=NAME:.metadata.name,TLS-SECRET:.spec.tls[*].secretName'
```

Use `.spec.tls[*].secretName` (wildcard) when the field is an array.

**6. Exercise TLS paths with self-signed certs**

```bash
openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
  -keyout /tmp/tls.key -out /tmp/tls.crt -subj '/CN=test.local'

for n in api-tls-cert frontend-tls-cert qualytics-tls-cert; do
  kubectl -n qualytics create secret tls "$n" \
    --cert=/tmp/tls.crt --key=/tmp/tls.key
done
```

Then upgrade with each TLS configuration and diff the `custom-columns` output.

#### Cleanup ritual

Always, even if the test passed:

```bash
helm uninstall qualytics -n qualytics
kubectl delete namespace qualytics --ignore-not-found
rm -f /tmp/qualytics-*.yaml /tmp/tls.{key,crt}
minikube stop
```

Leaving minikube running between sessions is fine; stopping is what to do at the end of a work stream.

#### What this pattern DOESN'T test

- **Real private image pulls** (`regcred`) — by design, to avoid leaking tokens into local envs.
- **Let's Encrypt / real cert issuance** — self-signed certs keep tests hermetic.
- **Cluster autoscaler / Karpenter / cloud storage classes** — minikube is a single node with a local storage class.
- **Production-scale workloads** — resources are capped so minikube can schedule.

For those, use a real cloud cluster (EKS/GKE/AKS). Minikube is for behavior, not performance or production fidelity.

#### Worked example

Native-Deployment dataplane migration (replaces the spark-operator):

1. Started minikube; installed baseline + `regcred` token; pre-created `qualytics-creds` Secret with stub values.
2. `helm install` from the chart → six docs render under `templates/spark.yaml` (SA, Role, RoleBinding, ConfigMap, headless Service, Deployment).
3. Driver pod scheduled on `driverNodes=true`. `kubectl exec` into it confirmed the env-block: `POD_NAME` / `POD_NAMESPACE` / `SPARK_DRIVER_BIND_ADDRESS` from the downward API, all `MOTHERSHIP_*` vars present.
4. Container args[0] is `exec /opt/entrypoint.sh driver \ ...` — the image's entrypoint runs SPARK_CLASSPATH + LD_LIBRARY_PATH + Kerberos setup before `exec`'ing `spark-submit`. Crucially we don't pass `--deploy-mode client` or `--conf spark.driver.bindAddress=` ourselves; the entrypoint adds them.
5. SparkMothership reached steady state (`0 messages awaiting processing from qualytics-rabbitmq`) after the cmd/api dependency chain converged.
6. Driver spawned an executor pod via the chart-managed SA/Role; `kubectl auth can-i create pods --as=system:serviceaccount:qualytics:qualytics-spark` returned `yes`.
7. Side-by-side smoke against the previous SparkApplication shape confirmed byte-identical MOTHERSHIP env, executor resources, and Mothership log sequence; the driver pod resources matched after applying Spark's 384 MiB minimum K8s memory overhead floor and emitting `Mi` (mebibytes) instead of `M` (megabytes).
8. Cleaned up, minikube stopped.

Total wall time: ~12 minutes. That's the full-behavior signal you can't get from `helm unittest` alone.

## Code Style Guidelines

### Naming Conventions
- **Resources**: Use `{{ .Release.Name }}-[component]` pattern
  - Example: `qualytics-api`, `qualytics-postgres`, `qualytics-spark`
- **Services**: `{{ .Release.Name }}-[component]-service` or `{{ .Release.Name }}-[component]`
  - Example: `qualytics-api-service`, `qualytics-postgres`
- **Template Helpers**: `qualytics.[component].[function]` in `_helpers.tpl`
  - Example: `qualytics.postgres.connection_url`, `qualytics.global.size`

### Template Formatting
- **Indentation**: 2 spaces for YAML files
- **Whitespace Control**: Use `{{-` and `-}}` for clean output
- **Conditions**: Use `{{- if .Values.path.to.value }}` for conditional resource generation
- **Multi-Document Templates**: Separate with `---` in same file
- **Comments**: Use `#` for inline documentation and explanations

### Values Organization
- **Structure**: Organize by component, with global settings at top level
- **Hierarchy**: `global` → `secrets` → `dataplane` → `controlplane` → `frontend` → component-specific
- **Toggles**: Use `enabled` flags for optional components (e.g., `postgres.enabled`, `ingress.enabled`, `dataplane.enabled`)
- **Platform Awareness**: Support `global.platform` values: `aws`, `gcp`, `azure`

### Labels & Metadata
- **Standard Labels**: Include `app` labels for resource selection
- **Node Selectors**:
  - `appNodeSelector` for control plane components
  - `driverNodeSelector` for Spark driver
  - `executorNodeSelector` for Spark executors
- **Tolerations**: Separate tolerations for each node type

### Security Requirements
- **TLS**: BYO (Bring Your Own) — customer creates `kubernetes.io/tls` Secrets in the release namespace. See [docs/ingress-tls.md](docs/ingress-tls.md).
  - Ingress: `ingress.tls.secretName` (shared, recommended) with fallback to legacy `api-tls-cert` / `frontend-tls-cert` split pair.
  - Postgres/RabbitMQ internal TLS: optional, consumes pre-existing `postgres-tls` / `rabbitmq-tls` Secrets.
- **Image Pull Secrets**: Reference `regcred` for private Docker registry access
- **Secrets**: Use `secretKeyRef` for sensitive environment variables
- **Secret Management**: All credentials stored in `qualytics-creds` secret

### Resource Patterns
- **Deployment Strategy**: `Recreate` (no rolling updates for stateful dependencies)
- **Image Pull Policy**: `IfNotPresent`
- **Termination Grace Period**: Default 10 seconds
- **Resource Requests/Limits**: Always specify for production workloads
- **Service Account**: `qualytics-spark` (chart-managed via `dataplane.rbac.create`) used by the Spark driver Deployment to create executor pods directly via the K8s API.

### Configuration Best Practices
- **Toggleability**: Make features configurable in values.yaml when possible
- **Platform Awareness**: Support AWS/GCP/Azure-specific configurations (storage classes, volumes)
- **Documentation**: Document all values with descriptive comments in values.yaml
- **Dynamic Values**: Use `tpl` function for templated values (e.g., DNS records, image URLs)
- **Default Values**: Provide sensible defaults in values.yaml
- **Simplified Config**: Use template.values.yaml for quick start deployments

## Template Helpers

### Available Helpers in _helpers.tpl

**1. `qualytics.postgres.connection_url`**
- Generates PostgreSQL connection URL with dynamic host resolution
- Uses internal service DNS when `postgres.enabled=true`
- Falls back to external host when disabled
- Applies SSL mode based on TLS enablement (`prefer` vs `require`)
- Format: `user:password@host:port/database?sslmode=X`
- Used in: API and CMD deployments via `POSTGRES_CONNECTION_URL` secret

**2. `qualytics.global.size`**
- Determines deployment size based on Spark driver cores
- Sizes:
  - `small` (1-4 cores)
  - `medium` (5-8 cores)
  - `large` (9-16 cores)
  - `xlarge` (17-32 cores)
  - `unspecified` (>32 cores)
- Used for `APP_DEPLOYMENT_SIZE` environment variable in control plane

## Component Configuration

### Dataplane (Spark)
- **Version**: Spark 4.1.1
- **Shape**: native Kubernetes `Deployment` (replicas: 1, strategy: Recreate) running `/opt/entrypoint.sh driver` which `exec`s `spark-submit --deploy-mode client …`. The pod's PID 1 is the driver JVM. Executors are created directly through the Kubernetes API. The entrypoint contract is documented below.
- **Driver pod naming**: `<release>-spark-<rs-hash>-<pod-hash>` (Deployment-managed, random suffix). Use `kubectl logs deployment/<release>-spark` or `-l spark-role=driver` rather than hardcoding pod names. Deployment was chosen over StatefulSet for auto-recovery on node failure (StatefulSet pods stay `Terminating` indefinitely on vanilla EKS until the `out-of-service` taint is applied, which nothing in EKS does automatically).
- **Resources rendered into the chart bundle** (when `dataplane.enabled=true` and `global.deploymentMode="kubernetes"`):
  1. `ServiceAccount` (`qualytics-spark` by default; gated on `dataplane.rbac.create`)
  2. `Role` — pods + configmaps + persistentvolumeclaims + services CRUD + watch
  3. `RoleBinding` to the SA
  4. `ConfigMap` `<release>-spark-executor-template` — Spark-style pod template referenced via `--conf spark.kubernetes.executor.podTemplateFile=/opt/spark/conf/executor-template.yaml`
  5. headless `Service` `<release>-spark-driver` for driver↔executor RPC (ports 7078 / 7079 / 4040)
  6. `Deployment` `<release>-spark`
- **RBAC opt-out**: `dataplane.rbac.create=false` lets you BYO an existing SA when the cluster restricts ServiceAccount creation. Override SA name via `dataplane.rbac.serviceAccountName`. Annotations (e.g. `eks.amazonaws.com/role-arn` for IRSA, GCP Workload Identity) go on `dataplane.rbac.serviceAccountAnnotations`.
- **Driver pod resources**: derived from `dataplane.driver.cores` / `dataplane.driver.memory` and the `qualytics.spark.driver.podMemoryMb` helper, which mirrors Spark's `KubernetesUtils.calculatePodMemoryOverhead`: `pod_mem = heap + max(memoryOverheadFactor * heap, 384 MiB)`. Output is `Mi` (mebibytes) so it matches what the operator-managed flow produced.
- **Executor resources**: computed by Spark from `--conf spark.executor.cores` / `.memory`; same overhead floor formula. The chart doesn't set them on the pod template directly.
- **Dynamic Allocation**: 1-12 executors (configurable; `dataplane.dynamicAllocation.enabled` is respected, not hardcoded). Shuffle tracking and idle-timeout confs are passed unconditionally; they're inert when DA is off.
- **Volumes**: Platform-specific NVMe/SSD mounts for scratch space at `/tmp/spark-local-dir-<n>`. Live in the executor pod template (the ConfigMap), not at CR level — there's no operator translating CR volumes anymore.
- **Kerberos**: Optional (`dataplane.kerberos.enabled`). When true, the chart adds `krb5-conf` + `keytab` Secret-mounted volumes + `KERBEROS_*` / `MOTHERSHIP_SPARK_KRB_*` env to both the driver Deployment and the executor pod template.
- **Main Class**: `io.qualytics.dataplane.SparkMothership`
- **Extra Packages**: Teradata + IBM DB2 JDBC drivers, passed to spark-submit via `--packages`.
- **Restart behavior**: Pod's `restartPolicy: Always` (Deployment requirement). On JVM exit, kubelet restarts the container in-place — same pod UID. On full pod loss (node failure, manual delete, helm upgrade with Recreate), Deployment's ReplicaSet creates a new pod with a new UID. The functional guarantee — "always a driver running" — is met in both cases.
- **Node Scheduling**: `driverNodeSelector` on the driver Deployment, `executorNodeSelector` on the executor pod template. Tolerations follow the same split.

#### Driver entrypoint invariants (do not regress)

The dataplane image's `/opt/entrypoint.sh` does load-bearing setup before `spark-submit` (SPARK_CLASSPATH, LD_LIBRARY_PATH for libpostal JNI, Kerberos kinit + renewal daemon, libnss_wrapper passwd entry, gosu user-switch). The chart relies on this contract:

1. **Don't override `command:` past the entrypoint.** The chart uses `command: ["/bin/bash","-c"]` with `exec /opt/entrypoint.sh driver \ ...` — bash invokes the entrypoint, which then `exec`s spark-submit. If you bypass the entrypoint, classpath setup is missing, libpostal native libs fail to load, Kerberos doesn't kinit, and SIGTERM handling breaks.
2. **Don't pass `--deploy-mode client` or `--conf spark.driver.bindAddress=` from the chart.** The entrypoint's `driver` case adds both. Duplicate `--conf` lines confuse spark-submit's parser.
3. **Set `SPARK_DRIVER_BIND_ADDRESS` from `status.podIP` via the downward API.** The entrypoint substitutes it into the bindAddress conf and propagates it to executors via `spark.executorEnv.SPARK_DRIVER_POD_IP`. An empty value breaks spark-submit.

#### Pod-template invariants (do not regress)

1. **Executor pod template always emits `containers[0].name: spark-kubernetes-executor`**, regardless of `dataplane.kerberos.enabled`. Spark 4.1.1's `KubernetesUtils.selectSparkContainer` NPEs when the parsed template has no `containers` field — the container stanza must always be present, and only env/volumeMounts are gated on kerberos. The `should always emit executor containers[0].name regardless of kerberos` unit test exists specifically to catch this.
2. **Container names `spark-kubernetes-driver` / `spark-kubernetes-executor` are magic strings** matched by `spark.kubernetes.{driver,executor}.podTemplateContainerName`. Renaming them silently breaks Spark's merge — env + volumeMounts just won't land on the executor pod.
3. **`spark-local-dir-` prefix is no longer load-bearing**, since the chart now writes scratch volumes directly into the executor pod template (rather than relying on the operator's CR-volume translation that only matched that prefix). The prefix is still used by convention.

### Control Plane API
- **Replicas**: Configurable via `controlplane.replicas`
- **Resources**: Configurable via `controlplane.resources`
- **Image**: Configured by `global.imageUrls.controlplaneImageUrl` and `controlplaneImage.image.controlplaneImageTag`
- **Port**: 8000
- **Features**:
  - SMTP email notifications (optional)
  - Authentication (AUTH0 or OIDC)
  - Proxy support (HTTP/SOCKS5)
  - TLS certificate verification control
- **Environment**: Connects to PostgreSQL and RabbitMQ
- **Strategy**: Recreate deployment

### Control Plane CMD
- **Replicas**: 1
- **Resources**: Configurable via `controlplaneCmd.resources`
- **Purpose**: Background job processor
- **Similar configuration to API**: Same image and environment variables

### Frontend
- **Replicas**: Configurable via `frontend.replicas`
- **Resources**: Configurable via `frontend.resources`
- **Image**: Configured by `global.imageUrls.frontendImageUrl` and `frontendImage.image.frontendImageTag`
- **Port**: 8080
- **Strategy**: Recreate deployment

### PostgreSQL
- **Type**: StatefulSet
- **Replicas**: 1
- **Image**: `postgres:17`
- **Storage**: 100Gi persistent volume (default)
- **Backup Storage**: Configurable via `postgres.pvc.backupStorageSize`
- **Resources**: Configurable via `postgres.resources`
- **TLS**: Optional — set `postgres.tls.enabled: true` and pre-create the `postgres-tls` Secret in the namespace.
- **Service**: Headless service (clusterIP: None)
- **Port**: 5432
- **Upgrade Support**: Can use `pgautoupgrade/pgautoupgrade:17-bookworm` for auto-upgrade

### RabbitMQ
- **Type**: StatefulSet
- **Replicas**: 1
- **Image**: Configured by `rabbitmq.image`; currently RabbitMQ 4.3
- **Storage**: Uses `emptyDir` by default; persistence is optional via `rabbitmq.pvc.enabled`
- **Resources**: Configurable via `rabbitmq.resources`
- **TLS**: Optional — set `rabbitmq.tls.enabled: true` and pre-create the `rabbitmq-tls` Secret in the namespace.
- **Ports**:
  - 5672 (AMQP)
  - 5671 (AMQP-TLS)
  - 15672 (Management UI)
  - 30671 (NodePort for external access, optional)
- **User**: `user` (hardcoded)
- **Password**: Configurable via `secrets.rabbitmq.rabbitmq_password`
- **Inbound Access**: Optional external access via NodePort

### Ingress
- **Class**: nginx
- **ModSecurity WAF**: OWASP core rules enabled
- **Rate Limiting**: 10 RPS per IP with 2x burst multiplier
- **Compression**: GZIP and Brotli support
- **SSL**: Automatic redirect to HTTPS (force-ssl-redirect)
- **TLS**: BYO Secret. Default: single shared `ingress.tls.secretName`; falls back to legacy `api-tls-cert` + `frontend-tls-cert` split pair for backwards compatibility. See [docs/ingress-tls.md](docs/ingress-tls.md).
- **Body Limits**: 20MB with files, 2.6MB without files
- **Timeouts**: 3600s for proxy connect/read/send
- **Security Headers**:
  - X-Frame-Options: SAMEORIGIN
  - X-Content-Type-Options: nosniff
  - Referrer-Policy: same-origin
  - Strict-Transport-Security: max-age=31536000
  - Content-Security-Policy
  - Permissions-Policy
- **CORS**: Optional (disabled by default)
- **Routes**:
  - `/api/?(.*)` → API service
  - `/?(.*)` → Frontend service

### Storage Classes
- **Creation**: Optional (controlled by `storageClass.create`)
- **Custom Name**: Use `storageClass.name` to specify existing storage class
- **Platform-Specific**: Automatic creation based on `global.platform`

## Platform-Specific Configuration

### AWS
- **Storage**: EBS gp3 volumes with IOPS/throughput settings
  - Annotations: `ebs.csi.aws.com/iops: 8000`, `ebs.csi.aws.com/throughput: 250`
- **Storage Class**: `aws` (gp3, 8000 IOPS, 250 MB/s throughput)
- **Spark Volumes**: `/mnt/disks/nvme[1-4]n1/spark-local-dir-[1-4]`
- **Recommended Nodes**:
  - App: t3.2xlarge (8 vCPUs, 32 GB)
  - Driver: r5.2xlarge (8 vCPUs, 64 GB)
  - Executor: r5d.2xlarge (8 vCPUs, 64 GB) with local NVMe

### GCP
- **Storage**: Persistent Disks (SSD and standard)
- **Storage Classes**:
  - `gcp-fast` (pd-ssd, immediate binding)
  - `gcp-slow` (pd-standard, WaitForFirstConsumer)
- **Spark Volumes**: `/mnt/disks/ssd[0-3]/spark-local-dir-[1-4]`
- **Recommended Nodes**:
  - App: n2-standard-8 (8 vCPUs, 32 GB)
  - Driver: n2-highmem-8 (8 vCPUs, 64 GB)
  - Executor: n2-highmem-8 (8 vCPUs, 64 GB)

### Azure
- **Storage**: Managed Disks (Premium and Standard)
- **Storage Classes**:
  - `azure-fast` (Premium_LRS, immediate binding)
  - `azure-slow` (StandardSSD_LRS, WaitForFirstConsumer)
- **Spark Volumes**: `/mnt/resource/spark-local-dir-[1-4]`
- **Recommended Nodes**:
  - App: Standard_D8_v5 (8 vCPUs, 32 GB)
  - Driver: Standard_E8s_v5 (8 vCPUs, 64 GB)
  - Executor: Standard_E8s_v5 (8 vCPUs, 64 GB)

## Configuration Files

### values.yaml (Full Configuration)
- **Purpose**: Complete default configuration for the chart
- **Sections**:
  1. nginx subchart (ingress controller)
  2. Ingress configuration
  3. Global values (platform, DNS, auth type, image URLs)
  4. Image tags (controlplane, dataplane, frontend)
  5. Storage class configuration
  6. Node scheduling (selectors and tolerations)
  7. Deployment identifier and secrets (auth0, oidc, auth, postgres, smtp, rabbitmq)
  8. Dataplane configuration (Spark settings, including `dataplane.rbac.{create,serviceAccountName,serviceAccountAnnotations}`)
  9. Controlplane configuration (API and CMD)
  10. Frontend configuration
  11. PostgreSQL configuration
  12. RabbitMQ configuration
  13. Busybox utility image

### template.values.yaml (Simplified Configuration)
- **Purpose**: Quick start configuration template
- **Includes**: Essential settings only
- **Sections**:
  1. Global configuration (platform, DNS, auth type)
  2. Deployment identifier and authentication secrets (auth0, auth, postgres, rabbitmq)
  3. Node scheduling (with default enabled selectors)
  4. Dependencies (with node selectors)
  5. Ingress configuration
  6. Controlplane configuration (SMTP, egress)
  7. Dataplane configuration
  8. Storage configuration

### Chart.yaml
- **API Version**: v2
- **Type**: application
- **Version**: date-based (`YYYY.M.D`) — bump on every change.
- **App Version**: same as chart version.
- **Dependencies**:
  1. ingress-nginx 4.15.1 (condition: `nginx.enabled`)

## Authentication Configuration

### AUTH0 (Default)
- **Type**: Set `global.authType: "AUTH0"`
- **Required Secrets**:
  - `auth0_domain` (default: auth.qualytics.io)
  - `auth0_audience` (API identifier)
  - `auth0_organization` (organization ID)
  - `auth0_spa_client_id` (SPA client ID)
- **Egress Requirement**: Access to `https://auth.qualytics.io`

### OIDC (Custom IdP)
- **Type**: Set `global.authType: "OIDC"`
- **Required Secrets**:
  - `oidc_scopes`
  - `oidc_authorization_endpoint`
  - `oidc_token_endpoint`
  - `oidc_userinfo_endpoint`
  - `oidc_client_id`
  - `oidc_client_secret`
  - User mapping keys (id, email, name, fname, lname, picture, provider)
- **Optional**:
  - `oidc_allow_insecure_transport` (default: false)
  - `oidc_signer_pem_url` (for custom certificate validation)
- **Use Case**: Air-gapped deployments or custom enterprise IdP

## Node Scheduling

### Node Labels
- **appNodes=true**: Application components (API, CMD, Frontend)
- **driverNodes=true**: Spark driver Deployment
- **executorNodes=true**: Spark executor pods (set in the executor pod template ConfigMap)
- **Alternative**: Use `sparkNodes=true` for combined driver/executor nodes

### Node Selectors
- **Global Selectors**:
  - `appNodeSelector`: Applied to API, CMD, Frontend
  - `driverNodeSelector`: Applied to Spark driver
  - `executorNodeSelector`: Applied to Spark executors
- **Component-Specific**: Each component can have its own node selector

### Tolerations
- **Global Tolerations**:
  - `tolerations.appNodeTolerations`
  - `tolerations.driverNodeTolerations`
  - `tolerations.executorNodeTolerations`
- **Format**: Standard Kubernetes toleration format

### No Node Selectors
- Set all node selectors to `{}` to allow scheduling on any node
- Not recommended for production (limits autoscaling efficiency)

## Deployment Workflow

### Prerequisites
1. CNCF-compliant Kubernetes cluster (v1.30+)
2. `kubectl` configured for cluster access
3. `helm` CLI (v3.12+)
4. Qualytics-issued container-registry token
5. Unique deployment identifier provided by Qualytics
6. Auth0 or OIDC configuration details

### Initial Setup
1. **Create namespace and registry secret**:
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

2. **Create configuration file**:
   ```bash
   cp template.values.yaml values.yaml
   chmod 600 values.yaml
   # Set secrets.deployment.identifier to the value provided by Qualytics,
   # then edit the remaining customer-specific settings.
   ```

3. **Deploy Qualytics**:
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

### DNS + TLS
- Customer-managed DNS + customer-provided TLS Secret.
  - Create an A record pointing to the ingress IP.
  - Set `global.dnsRecord` in values.yaml.
  - Mint a cert (corporate CA, Let's Encrypt outside the chart, cloud-managed, etc.) and create a `kubernetes.io/tls` Secret. See [docs/ingress-tls.md](docs/ingress-tls.md).

### Upgrades
```bash
CHART_VERSION="<version provided by Qualytics>"
helm upgrade qualytics qualytics/qualytics \
  --namespace qualytics \
  --version "$CHART_VERSION" \
  -f values.yaml \
  --wait \
  --timeout=5m
```

## Troubleshooting

### Common Issues

**1. Pods stuck in Pending state**
- Check node resources: `kubectl describe nodes`
- Verify node selectors match cluster labels
- Ensure storage classes are available
- Check PVC status: `kubectl get pvc -n qualytics`

**2. Image pull errors**
- Verify registry secret: `kubectl get secret regcred -n qualytics -o yaml`
- Check image accessibility from cluster
- Verify credentials are current

**3. Ingress not working**
- Ensure ingress controller is running: `kubectl get pods -n qualytics | grep nginx`
- Check ingress resources: `kubectl describe ingress -n qualytics`
- Verify DNS configuration
- Check TLS certificates: `kubectl get certificates -n qualytics`

**4. Database connection errors**
- Check PostgreSQL pod: `kubectl logs -f statefulset/qualytics-postgres -n qualytics`
- Verify connection URL: Check `qualytics-creds` secret
- Test internal DNS: `kubectl run -it --rm debug --image=busybox --restart=Never -n qualytics -- nslookup qualytics-postgres`

**5. Spark jobs failing**
- Check driver logs by selector (the pod has a random suffix): `kubectl logs deployment/qualytics-spark -n qualytics --tail=200 -f` or `kubectl logs -l spark-role=driver -n qualytics`
- Verify executor resources: `kubectl get pods -n qualytics -l spark-role=executor`
- Check dynamic allocation: look for executor scaling in driver logs
- Verify volumes mounted correctly: `kubectl get cm qualytics-spark-executor-template -n qualytics -o jsonpath='{.data.executor-template\.yaml}'`
- Verify driver SA can manage executor pods: `kubectl auth can-i create pods --as=system:serviceaccount:qualytics:qualytics-spark -n qualytics` should return `yes`

## Recent Focus Areas
- Native-Deployment dataplane: replaced the SparkApplication CRD + spark-operator with a chart-managed Deployment + RBAC + headless Service + executor pod template ConfigMap. Driver runs `spark-submit` in client mode and creates executor pods directly via the K8s API.
- Spark pod-template migration (disabled the mutating admission webhook) — historical, superseded by the above
- cert-manager removal (BYO TLS Secrets)
- Apache Spark 4.1 + RabbitMQ 4.3 upgrades
- PostgreSQL 17 upgrade support
- Enhanced ingress security (ModSecurity WAF, rate limiting)
- Multi-platform storage class support

## Additional Resources
- [Qualytics User Guide](https://userguide.qualytics.io/upgrades/qualytics-single-tenant-instance/)
- [Spark on Kubernetes (Apache)](https://spark.apache.org/docs/latest/running-on-kubernetes.html) — for client-mode driver semantics + executor pod template
- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
- [Ingress TLS (BYO Secret)](docs/ingress-tls.md)
