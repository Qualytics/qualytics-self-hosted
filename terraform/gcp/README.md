# Qualytics on GCP — GKE + AlloyDB for PostgreSQL

This guide walks through deploying a Qualytics self-hosted instance on Google Kubernetes Engine (GKE) with AlloyDB for PostgreSQL as the external database.

## Architecture

```
Internet → External passthrough LB → nginx ingress (terminates TLS) → Qualytics pods
                                                                        ↓
                                                    AlloyDB for PostgreSQL (private services access)
```

- **GKE** — regional control plane with three autoscaling node pools: app, Spark driver, Spark executor (local SSDs)
- **AlloyDB for PostgreSQL** — external managed database; replaces the in-cluster PostgreSQL StatefulSet. Reachable only on a private IP through private services access on the cluster VPC
- **TLS** — a `kubernetes.io/tls` Secret you create in the release namespace; nginx terminates TLS. See [`docs/ingress-tls.md`](../../docs/ingress-tls.md)

## Directory structure

| Directory | Description |
|---|---|
| [`cluster/`](./cluster) | Project (optional), VPC, Cloud NAT, GKE cluster, node pools |
| [`postgres/`](./postgres) | AlloyDB cluster + primary instance, private services access, Secret Manager |

> **Upgrading from the single-directory layout?** Earlier versions of this template kept the cluster configuration directly in `terraform/gcp/`. See [Upgrading from the single-directory layout](#upgrading-from-the-single-directory-layout) before running anything.

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| Terraform | >= 1.11.1 |
| Helm | >= 3.12 |
| kubectl | >= 1.28 |
| Google Cloud SDK (`gcloud`) | any recent |
| jq | any |

Authenticate Terraform with Application Default Credentials:

```bash
gcloud auth application-default login
```

The identity needs permission to create projects (only if the template creates one), networks, GKE, AlloyDB, Secret Manager, and service networking resources — see [`postgres/README.md`](./postgres/README.md#iam-permissions) for the AlloyDB roles.

You also need, from your Qualytics account manager:

- an image-registry token, and
- a unique deployment identifier for this installation.

Finally, you need a TLS certificate and private key for your domain (corporate CA, Let's Encrypt, or any other issuer).

---

## Step 0 — Clone the repository

```bash
git clone https://github.com/qualytics/qualytics-self-hosted.git
cd qualytics-self-hosted
```

All paths below are relative to the repository root. Each step begins with an absolute `cd` so the sequence works regardless of where you are.

---

## Step 1 — One-time: create the GCS state backend

Terraform stores state in a GCS bucket. Create it once before the first `terraform init`, in a project you already have (it can be a different project from the one Qualytics runs in):

```bash
gcloud storage buckets create gs://<your-tfstate-bucket> \
  --project=<your-admin-project> \
  --location=<your-region> \
  --uniform-bucket-level-access \
  --public-access-prevention

gcloud storage buckets update gs://<your-tfstate-bucket> --versioning
```

Note the bucket name — you pass it to `terraform init` in Steps 2 and 5. The GCS backend locks state natively; no extra lock table is needed.

> **One deployment per state bucket.** Both modules use fixed state prefixes (`gcp/cluster`, `gcp/postgres`). To run more than one Qualytics deployment from the same bucket, give each its own bucket, or add `-backend-config="prefix=<name>/gcp/cluster"` consistently to every `init` for that deployment — and set `tfstate_prefix` accordingly in Step 5.

---

## Step 2 — Deploy the GKE cluster

```bash
cd "$(git rev-parse --show-toplevel)/terraform/gcp/cluster"
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
```

Edit `terraform.tfvars`. Either point it at an existing project:

```hcl
tenant_name  = "your-tenant-name"
project_id   = "your-gcp-project-id"
region       = "<your-region>"
cluster_name = "qualytics"

# Required by the variable definitions even when project_id is set; unused then.
billing_account = ""
folder_id       = ""
```

or leave `project_id = ""` and set `billing_account` and `folder_id` to have Terraform create the project.

See [`docs/cluster-sizing.md`](../../docs/cluster-sizing.md) for machine type recommendations.

Deploy:

```bash
terraform init -backend-config="bucket=<your-tfstate-bucket>"
terraform apply
```

This creates the VPC, Cloud NAT, the GKE cluster with app/driver/executor node pools, and the `qualytics` namespace. If you set the optional `docker_registry_token` variable it also creates the `regcred` Secret; otherwise create it in Step 3.

Once complete, configure `kubectl`:

```bash
terraform output -raw configure_kubectl | sh
kubectl get nodes
```

See [`cluster/README.md`](./cluster/README.md) for the full inputs/outputs reference.

---

## Step 3 — Create the image-pull Secret

Terraform created the `qualytics` namespace. Create the registry Secret with a no-echo prompt so the token never lands in your shell history:

```bash
printf "Qualytics registry token: "
IFS= read -rs QUALYTICS_REGISTRY_TOKEN
echo
kubectl create secret docker-registry regcred -n qualytics \
  --docker-username=qualyticsai \
  --docker-password="$QUALYTICS_REGISTRY_TOKEN"
unset QUALYTICS_REGISTRY_TOKEN
```

> If you set `create_qualytics_namespace = false` in Step 2, run `kubectl create namespace qualytics` first.

---

## Step 4 — Create the TLS Secret

nginx terminates TLS inside the cluster, so the certificate lives in a Kubernetes Secret. Create it before installing the chart:

```bash
kubectl create secret tls qualytics-tls-cert -n qualytics \
  --cert=./fullchain.pem \
  --key=./privkey.pem
```

Use a single wildcard or SAN certificate covering your domain — the chart's recommended pattern is one Secret shared by the API and frontend ingresses. See [`docs/ingress-tls.md`](../../docs/ingress-tls.md) for all options.

> **Helm does not fail if this Secret is missing.** nginx falls back to its own self-signed certificate, so the site loads but browsers reject it. Step 9 checks for this.

---

## Step 5 — Deploy AlloyDB for PostgreSQL

AlloyDB reads the project and VPC network from the cluster state — run Step 2 first.

```bash
cd "$(git rev-parse --show-toplevel)/terraform/gcp/postgres"
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
cluster_name       = "qualytics"               # must match Step 2
region             = "<your-region>"           # must match Step 2
tfstate_bucket     = "<your-tfstate-bucket>"   # same bucket as Step 1
postgresql_version = "17"
cpu_count          = 2                         # see postgres/variables.tf for recommendations
```

> **Note:** `tfstate_bucket` in `terraform.tfvars` and the `bucket` in `-backend-config` must be the same GCS bucket. The backend config is where Terraform writes the AlloyDB module's own state; the variable is where it reads the cluster state to get the project and network. If they differ, AlloyDB is deployed against the wrong network.

Deploy:

```bash
terraform init -backend-config="bucket=<your-tfstate-bucket>"
terraform apply
```

This enables the AlloyDB and Secret Manager APIs, reserves an internal range on the cluster VPC and peers it with Google's service network (private services access), creates the AlloyDB cluster and primary instance, and stores the connection credentials in Secret Manager.

Expected duration: **15–25 minutes** (most of it is the primary instance).

Retrieve the connection details:

```bash
terraform output -raw helm_values
```

or from Secret Manager:

```bash
gcloud secrets versions access latest \
  --secret="<cluster-name>-alloydb-password" \
  --project="$(cd ../cluster && terraform output -raw project_id)" | jq .
```

See [`postgres/README.md`](./postgres/README.md) for the full inputs/outputs reference, IAM roles, and password rotation.

---

## Step 6 — Configure Helm values

```bash
cd "$(git rev-parse --show-toplevel)"
cp template.values.yaml values.yaml
chmod 600 values.yaml
```

Edit `values.yaml`. The keys below are the ones that differ from the template for this topology:

```yaml
global:
  platform: "gcp"
  dnsRecord: "your-domain.example.com"

secrets:
  deployment:
    # REQUIRED. template.values.yaml ships this blank, and Helm refuses to render
    # while it is empty — copying the template is not sufficient. Paste the value
    # exactly as issued; never reuse it for another installation.
    identifier: "<provided by Qualytics>"
  auth:
    jwt_signing_secret: "<openssl rand -base64 32>"
  postgres:
    host: "<db_host from Step 5>"
    port: 5432
    database: "surveillance_hub"
    username: "postgres"
    password: "<password from Step 5 / Secret Manager>"
    secrets_passphrase: "<openssl rand -base64 32>"
  rabbitmq:
    rabbitmq_password: "<openssl rand -base64 16>"

appNodeSelector:
  appNodes: "true"
driverNodeSelector:
  driverNodes: "true"
executorNodeSelector:
  executorNodes: "true"

# Only when enable_node_taints = true in Step 2 (the variable default).
# The shipped terraform.tfvars.example sets it to false.
# tolerations:
#   appNodeTolerations:
#     - { key: appNodes, operator: Equal, value: "true", effect: NoSchedule }
#   driverNodeTolerations:
#     - { key: driverNodes, operator: Equal, value: "true", effect: NoSchedule }
#   executorNodeTolerations:
#     - { key: executorNodes, operator: Equal, value: "true", effect: NoSchedule }

nginx:
  enabled: true                            # template.values.yaml ships false
  controller:
    nodeSelector:
      appNodes: "true"

ingress:
  enabled: true
  tls:
    secretName: "qualytics-tls-cert"       # the Secret created in Step 4

postgres:
  schema: "public"
  enabled: false                           # using AlloyDB, not in-cluster PostgreSQL

dataplane:
  enabled: true
  numVolumes: 2                            # = executor_local_ssd_count from Step 2
```

**Set `dataplane.numVolumes` to `executor_local_ssd_count`.** GKE mounts each local SSD at `/mnt/disks/ssd<n>`, which is where the chart points Spark's scratch directories when `global.platform` is `gcp`. Use `-1` if you set `executor_local_ssd_count = 0`.

---

## Step 7 — Deploy Qualytics

```bash
helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
helm repo update
CHART_VERSION="<version provided by Qualytics>"
helm upgrade --install qualytics qualytics/qualytics \
  --namespace qualytics \
  --version "$CHART_VERSION" \
  -f values.yaml \
  --wait \
  --timeout=10m
```

```bash
kubectl get pods -n qualytics
kubectl -n qualytics get secret qualytics-tls-cert
```

Expected: all pods `Running` and the TLS Secret present.

> **First boot against AlloyDB.** AlloyDB creates only the built-in `postgres` database. If the API logs `database "surveillance_hub" does not exist`, create it once as `postgres` — see [`postgres/README.md`](./postgres/README.md#the-qualytics-database) — and restart the API and CMD deployments.

---

## Step 8 — DNS configuration

```bash
kubectl get svc -n qualytics qualytics-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

**Cloud DNS:**

```bash
gcloud dns record-sets create your-domain.example.com. \
  --zone=<your-managed-zone> \
  --type=A --ttl=300 \
  --rrdatas=<ingress-ip>
```

**Other DNS providers:** Create an A record pointing `your-domain.example.com` to the ingress IP.

> **Important:** The load balancer is owned by the nginx controller Service, so its IP changes on any full redeploy — `helm uninstall`, or deleting the `qualytics` namespace. Always update the DNS record afterwards.

---

## Step 9 — Verify the deployment

```bash
kubectl get pods -n qualytics

curl -sv https://your-domain.example.com 2>&1 | grep -E "issuer|subject|HTTP"

curl -s https://your-domain.example.com -o /dev/null -w "%{http_code}\n"
# Expected: 200
```

The second command deliberately omits `-k`. A `curl (60)` TLS error means the certificate is not trusted — usually the Secret from Step 4 is missing or its chain is incomplete, and nginx is serving its own self-signed certificate.

---

## Teardown

```bash
helm uninstall qualytics -n qualytics
```

Destroy AlloyDB before the cluster — AlloyDB is peered into the cluster VPC. `deletion_protection` defaults to `true`, so a bare `terraform destroy` fails; clear it first:

```bash
cd "$(git rev-parse --show-toplevel)/terraform/gcp/postgres"
terraform apply -var="deletion_protection=false"
terraform destroy
```

Deleting the cluster deletes its data. If you need it afterwards, export it (`pg_dump`) before destroying.

```bash
cd "$(git rev-parse --show-toplevel)/terraform/gcp/cluster"
terraform apply -var="deletion_protection=false"
terraform destroy
```

The GCS state bucket is not destroyed by these commands — it persists for reuse. Your TLS Secret lives in the `qualytics` namespace and is destroyed with the cluster, so keep the certificate and private key stored outside the cluster.

---

## Upgrading from the single-directory layout

Earlier versions of this template kept the GKE configuration directly in `terraform/gcp/` with local state. That configuration now lives, unchanged, in `terraform/gcp/cluster/` with a GCS backend. Resource addresses did not change, so no `terraform state mv` is needed — only the state file has to follow the code.

```bash
cd "$(git rev-parse --show-toplevel)/terraform/gcp"
cp terraform.tfstate ~/qualytics-gcp-terraform.tfstate.backup   # keep a copy

mv terraform.tfstate terraform.tfvars cluster/
rm -rf .terraform .terraform.lock.hcl terraform.tfstate.backup
```

Create the state bucket (Step 1), then migrate the local state into it:

```bash
cd "$(git rev-parse --show-toplevel)/terraform/gcp/cluster"
terraform init -backend-config="bucket=<your-tfstate-bucket>" -migrate-state
# Answer "yes" when asked to copy the existing state to the new backend.

terraform plan
```

The plan must show **no resource changes** — only the new `project_id` and `region` outputs (and `next_steps` text). Apply it so those outputs land in state; the AlloyDB module reads them:

```bash
terraform apply
```

> **If the plan proposes creating resources, stop.** It means Terraform did not find the old state. Applying it creates a second cluster — and, if the template created the project, a second project. Restore the backup into `cluster/terraform.tfstate` and repeat the steps above.

Then continue from Step 5 to add AlloyDB.

---

## Support

Contact your [Qualytics account manager](mailto:hello@qualytics.ai) for assistance.
