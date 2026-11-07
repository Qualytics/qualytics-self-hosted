# Qualytics on Azure — AKS + Azure Database for PostgreSQL

This guide walks through deploying a Qualytics self-hosted instance on Azure Kubernetes Service (AKS) with Azure Database for PostgreSQL Flexible Server as the external database.

## Architecture

```
Internet → Azure Load Balancer → nginx ingress (terminates TLS) → Qualytics pods
                                                                      ↓
                                          Azure Database for PostgreSQL (delegated subnet, private DNS)
```

- **AKS** — three autoscaling node pools pinned to one zone: app, Spark driver, Spark executor (Spot)
- **Azure Database for PostgreSQL Flexible Server** — external managed database; replaces the in-cluster PostgreSQL StatefulSet. Reachable only on a private IP in a subnet of the cluster VNet
- **TLS** — a `kubernetes.io/tls` Secret you create in the release namespace; nginx terminates TLS. See [`docs/ingress-tls.md`](../../docs/ingress-tls.md)

## Directory structure

| Directory | Description |
|---|---|
| [`cluster/`](./cluster) | Resource group, VNet, AKS cluster, node pools, storage classes |
| [`postgres/`](./postgres) | Flexible Server, delegated subnet, private DNS zone, Key Vault |

> **Upgrading from the single-directory layout?** Earlier versions of this template kept the cluster configuration directly in `terraform/azure/`. See [Upgrading from the single-directory layout](#upgrading-from-the-single-directory-layout) before running anything.

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| Terraform | >= 1.11.1 |
| Helm | >= 3.12 |
| kubectl | >= 1.28 |
| Azure CLI (`az`) | >= 2.50 |
| jq | any |

Authenticate and select the subscription Qualytics will run in:

```bash
az login
az account set --subscription "<your-subscription-id>"
```

Terraform uses this CLI session. The identity needs `Contributor` on the subscription — see [`postgres/README.md`](./postgres/README.md#permissions) for details.

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

## Step 1 — One-time: create the state storage account

Terraform stores state in an Azure Storage blob container. Create it once before the first `terraform init`, in the subscription selected above. Storage account names are 3–24 lowercase letters and digits and unique across Azure:

```bash
az group create --name <tfstate-resource-group> --location <your-region>

az storage account create \
  --name <tfstate-storage-account> \
  --resource-group <tfstate-resource-group> \
  --location <your-region> \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false

az storage account blob-service-properties update \
  --account-name <tfstate-storage-account> \
  --resource-group <tfstate-resource-group> \
  --enable-versioning true

az storage container create \
  --name tfstate \
  --account-name <tfstate-storage-account> \
  --auth-mode key
```

Note the resource group and storage account names — you pass them to `terraform init` in Steps 2 and 5. The backend locks state with a blob lease; no extra lock resource is needed.

> **One deployment per container.** Both modules use fixed blob names (`azure/cluster/terraform.tfstate`, `azure/postgres/terraform.tfstate`). To run more than one Qualytics deployment from the same storage account, give each its own container, or add `-backend-config="key=<name>/azure/cluster/terraform.tfstate"` consistently to every `init` for that deployment — and set `tfstate_key` accordingly in Step 5.

---

## Step 2 — Deploy the AKS cluster

```bash
cd "$(git rev-parse --show-toplevel)/terraform/azure/cluster"
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
subscription_id = "<your-subscription-id>"
location        = "<your-region>"
cluster_name    = "qualytics"
node_group_az   = "1"
```

See [`docs/cluster-sizing.md`](../../docs/cluster-sizing.md) for VM size recommendations.

Deploy:

```bash
terraform init \
  -backend-config="resource_group_name=<tfstate-resource-group>" \
  -backend-config="storage_account_name=<tfstate-storage-account>" \
  -backend-config="container_name=tfstate"
terraform apply
```

This creates the resource group, VNet, the AKS cluster with app/driver/executor node pools, the `azure-fast` / `azure-slow` storage classes, and the `qualytics` namespace. If you set the optional `docker_registry_token` variable it also creates the `regcred` Secret; otherwise create it in Step 3.

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

## Step 5 — Deploy Azure Database for PostgreSQL

The database module reads the subscription, resource group, VNet and zone from the cluster state — run Step 2 first.

```bash
cd "$(git rev-parse --show-toplevel)/terraform/azure/postgres"
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
cluster_name                 = "qualytics"                  # must match Step 2
tfstate_resource_group_name  = "<tfstate-resource-group>"   # same as Step 1
tfstate_storage_account_name = "<tfstate-storage-account>"  # same as Step 1
postgresql_version           = "17"
sku_name                     = "GP_Standard_D2ds_v5"        # see postgres/variables.tf for recommendations
```

> **Note:** the `tfstate_*` variables and the `-backend-config` values must point at the same storage account and container. The backend config is where Terraform writes this module's own state; the variables are where it reads the cluster state to get the resource group and VNet. If they differ, the database is deployed against the wrong network.

If you changed `vnet_cidr` or `aks_subnet_cidr` in Step 2, also set `postgres_subnet_cidr` to a free range inside the VNet.

Deploy:

```bash
terraform init \
  -backend-config="resource_group_name=<tfstate-resource-group>" \
  -backend-config="storage_account_name=<tfstate-storage-account>" \
  -backend-config="container_name=tfstate"
terraform apply
```

This creates a subnet delegated to Flexible Server in the cluster VNet, a private DNS zone linked to the VNet, the Flexible Server with the `surveillance_hub` database, and a Key Vault holding the connection credentials.

Expected duration: **10–20 minutes** (zone-redundant HA takes longest).

Retrieve the connection details:

```bash
terraform output -raw helm_values
```

or from Key Vault:

```bash
az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name "$(terraform output -raw key_vault_secret_name)" \
  --query value -o tsv | jq .
```

See [`postgres/README.md`](./postgres/README.md) for the full inputs/outputs reference, permissions, and password rotation.

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
  platform: "azure"
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
    password: "<password from Step 5 / Key Vault>"
    secrets_passphrase: "<openssl rand -base64 32>"
  rabbitmq:
    rabbitmq_password: "<openssl rand -base64 16>"

appNodeSelector:
  appNodes: "true"
driverNodeSelector:
  driverNodes: "true"
executorNodeSelector:
  executorNodes: "true"

# enable_node_taints defaults to true in Step 2 (variable default and the
# shipped terraform.tfvars.example). Remove this block if you set it to false.
tolerations:
  appNodeTolerations:
    - { key: appNodes, operator: Equal, value: "true", effect: NoSchedule }
  driverNodeTolerations:
    - { key: driverNodes, operator: Equal, value: "true", effect: NoSchedule }
  executorNodeTolerations:
    - { key: executorNodes, operator: Equal, value: "true", effect: NoSchedule }

nginx:
  enabled: true                            # template.values.yaml ships false
  controller:
    nodeSelector:
      appNodes: "true"
    tolerations:                           # same as appNodeTolerations above
      - { key: appNodes, operator: Equal, value: "true", effect: NoSchedule }

ingress:
  enabled: true
  tls:
    secretName: "qualytics-tls-cert"       # the Secret created in Step 4

postgres:
  schema: "public"
  enabled: false                           # using Azure Database for PostgreSQL, not in-cluster PostgreSQL

dataplane:
  enabled: true
  numVolumes: -1
```

**Keep `dataplane.numVolumes` at `-1`.** On `global.platform: azure` the chart backs Spark scratch directories with `emptyDir` (node ephemeral storage) rather than mounting the temp SSD — see [`docs/cluster-sizing.md`](../../docs/cluster-sizing.md).

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

---

## Step 8 — DNS configuration

```bash
kubectl get svc -n qualytics qualytics-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

**Azure DNS:**

```bash
az network dns record-set a add-record \
  --resource-group <dns-zone-resource-group> \
  --zone-name example.com \
  --record-set-name your-domain \
  --ipv4-address <ingress-ip>
```

**Other DNS providers:** Create an A record pointing `your-domain.example.com` to the ingress IP.

> **Important:** The load balancer IP is owned by the nginx controller Service, so it changes on any full redeploy — `helm uninstall`, or deleting the `qualytics` namespace. Always update the DNS record afterwards.

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

Destroy the database before the cluster — its subnet lives in the cluster VNet. `deletion_protection` defaults to `true`, so a bare `terraform destroy` fails before deleting anything; clear it first:

```bash
cd "$(git rev-parse --show-toplevel)/terraform/azure/postgres"
terraform apply -var="deletion_protection=false"
terraform destroy
```

Deleting the server deletes its data. If you need it afterwards, export it (`pg_dump`) before destroying.

```bash
cd "$(git rev-parse --show-toplevel)/terraform/azure/cluster"
terraform destroy
```

The state storage account is not destroyed by these commands — it persists for reuse. Your TLS Secret lives in the `qualytics` namespace and is destroyed with the cluster, so keep the certificate and private key stored outside the cluster.

---

## Upgrading from the single-directory layout

Earlier versions of this template kept the AKS configuration directly in `terraform/azure/` with local state. That configuration now lives, unchanged, in `terraform/azure/cluster/` with an Azure Storage backend. Resource addresses did not change, so no `terraform state mv` is needed — only the state file has to follow the code.

```bash
cd "$(git rev-parse --show-toplevel)/terraform/azure"
cp terraform.tfstate ~/qualytics-azure-terraform.tfstate.backup   # keep a copy

mv terraform.tfstate terraform.tfvars cluster/
rm -rf .terraform .terraform.lock.hcl terraform.tfstate.backup
```

Create the state storage account (Step 1), then migrate the local state into it:

```bash
cd "$(git rev-parse --show-toplevel)/terraform/azure/cluster"
terraform init \
  -backend-config="resource_group_name=<tfstate-resource-group>" \
  -backend-config="storage_account_name=<tfstate-storage-account>" \
  -backend-config="container_name=tfstate" \
  -migrate-state
# Answer "yes" when asked to copy the existing state to the new backend.

terraform plan
```

The plan must show **no resource changes** — only the new `subscription_id`, `node_group_az` and `vnet_address_space` outputs (and `next_steps` text). Apply it so those outputs land in state; the database module reads them:

```bash
terraform apply
```

> **If the plan proposes creating resources, stop.** It means Terraform did not find the old state. Applying it creates a second resource group and cluster. Restore the backup into `cluster/terraform.tfstate` and repeat the steps above.

Then continue from Step 5 to add Azure Database for PostgreSQL.

---

## Support

Contact your [Qualytics account manager](mailto:hello@qualytics.ai) for assistance.
