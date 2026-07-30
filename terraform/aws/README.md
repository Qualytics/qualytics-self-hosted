# Qualytics on AWS — EKS Auto Mode + Aurora PostgreSQL

This guide walks through deploying a Qualytics self-hosted instance on AWS EKS Auto Mode with Aurora PostgreSQL as the external database.

## Architecture

```
Internet → NLB (TCP passthrough) → nginx ingress (terminates TLS) → Qualytics pods
                                                                     ↓
                                                              Aurora PostgreSQL (VPC-private)
```

- **EKS Auto Mode** — AWS-managed compute; Karpenter provisions nodes on demand
- **Aurora PostgreSQL** — external managed database; replaces the in-cluster PostgreSQL StatefulSet
- **TLS** — a `kubernetes.io/tls` Secret you create in the release namespace; nginx terminates TLS and the NLB passes TCP through. See [`docs/ingress-tls.md`](../../docs/ingress-tls.md)
- **Three node pools** — app, Spark driver, Spark executor (each on dedicated instance types)

## Directory structure

| Directory | Description |
|---|---|
| [`cluster/`](./cluster) | EKS cluster, VPC, IAM, NodePools |
| [`postgres/`](./postgres) | Aurora PostgreSQL cluster, security group, Secrets Manager |

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| Terraform | >= 1.11.1 |
| Helm | >= 3.12 |
| kubectl | >= 1.28 |
| AWS CLI | >= 2.0 |
| jq | any |

AWS credentials must have permissions to create EKS, VPC, RDS, IAM, and Secrets Manager resources.

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

The identity running Terraform needs `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, and `s3:ListBucket` on the state bucket created in Step 1 — including read access to `aws/cluster/terraform.tfstate`, which the postgres module reads to discover the VPC.

---

## Step 1 — One-time: create the S3 state backend

Terraform stores state in S3. Create the bucket once before the first `terraform init`.

```bash
aws s3api create-bucket \
  --bucket <your-tfstate-bucket> \
  --region <your-region>

aws s3api put-bucket-versioning \
  --bucket <your-tfstate-bucket> \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket <your-tfstate-bucket> \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

Note the bucket name — you pass it to `terraform init` in Steps 2 and 5.

> **One deployment per state bucket.** Both modules use fixed state keys (`aws/cluster/terraform.tfstate`, `aws/postgres/terraform.tfstate`). To run more than one Qualytics deployment from the same bucket, give each its own bucket, or add `-backend-config="key=<prefix>/aws/cluster/terraform.tfstate"` consistently to every `init` for that deployment — and set `tfstate_key` accordingly in Step 5.

---

## Step 2 — Deploy the EKS cluster

```bash
cd "$(git rev-parse --show-toplevel)/terraform/aws/cluster"
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
cluster_name       = "your-cluster-name"
aws_region         = "<your-region>"
kubernetes_version = "1.35"

# Optional: grant additional IAM users or roles cluster admin access.
# The identity running terraform apply is automatically granted admin access.
# cluster_admin_arns = ["arn:aws:iam::123456789012:role/my-ci-role"]

# See docs/cluster-sizing.md (repository root) for instance type recommendations.
app_node_instance_types      = ["m8g.2xlarge"]
driver_node_instance_types   = ["r8g.2xlarge"]
executor_node_instance_types = ["r8gd.2xlarge"]
```

Deploy:

```bash
terraform init \
  -backend-config="bucket=<your-tfstate-bucket>" \
  -backend-config="region=<your-region>"
terraform apply
```

This creates the VPC, EKS Auto Mode control plane, IAM roles, NodeClass and NodePool resources for app/driver/executor nodes, and the `qualytics` namespace. If you set the optional `docker_registry_token` variable it also creates the `regcred` Secret; otherwise create it in Step 3.

Expected duration: **12–18 minutes**.

Once complete, configure `kubectl`. This writes credentials to your kubeconfig (`~/.kube/config` on Mac/Linux, `%USERPROFILE%\.kube\config` on Windows):

```bash
aws eks update-kubeconfig --region <your-region> --name <cluster-name>
kubectl get nodes   # returns "No resources found" until pods are scheduled — this is normal
```

Confirm the node pools registered:

```bash
kubectl get nodepool
# Expect: system (built-in) plus qualytics-app, qualytics-driver, qualytics-exec
kubectl get nodeclass
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

Use a single wildcard or SAN certificate covering your domain — the chart's recommended pattern is one Secret shared by the API and frontend ingresses. See [`docs/ingress-tls.md`](../../docs/ingress-tls.md) for all options, including the legacy split `api-tls-cert` + `frontend-tls-cert` pair.

> **Why TLS terminates at nginx, not the NLB.** The chart sets `force-ssl-redirect: 'true'` on all three ingresses unconditionally. An NLB that terminates TLS and forwards plaintext HTTP to nginx therefore produces a redirect loop. Running the NLB in TCP passthrough — the chart's default port mapping — is the arrangement the chart supports.
>
> **Helm does not fail if this Secret is missing.** nginx falls back to its own self-signed certificate, so the site loads but browsers reject it. Step 9 checks for this.

---

## Step 5 — Deploy Aurora PostgreSQL

Aurora reads the VPC and subnet IDs from the cluster state file — run Step 2 first.

```bash
cd "$(git rev-parse --show-toplevel)/terraform/aws/postgres"
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
cluster_name       = "your-cluster-name"   # must match Step 2
aws_region         = "<your-region>"
tfstate_bucket     = "<your-tfstate-bucket>"   # same bucket as Step 1
postgresql_version = "17.9"
instance_class     = "db.r8g.large"   # see postgres/variables.tf for recommendations
```

> **Note:** `tfstate_bucket` in `terraform.tfvars` and the `bucket` in `-backend-config` must be the same S3 bucket. The backend config is where Terraform writes the postgres module's own state; the variable is where it reads the cluster state to get VPC and subnet IDs. If they differ, Aurora is deployed into the wrong VPC.

Optionally confirm the engine version is offered in your region before applying:

```bash
aws rds describe-db-engine-versions \
  --engine aurora-postgresql \
  --engine-version 17 \
  --region <your-region> \
  --query "DBEngineVersions[].EngineVersion" --output text
```

Deploy:

```bash
terraform init \
  -backend-config="bucket=<your-tfstate-bucket>" \
  -backend-config="region=<your-region>"
terraform apply
```

This creates the Aurora PostgreSQL cluster in the same VPC as EKS, a security group allowing port 5432 from within the VPC, a CloudWatch log group with bounded retention, and a Secrets Manager secret with the connection credentials.

Expected duration: **10–15 minutes**.

Retrieve the connection details:

```bash
aws secretsmanager get-secret-value \
  --secret-id "<cluster-name>-postgres-password" \
  --region <your-region> \
  --query SecretString \
  --output text | jq .
```

See [`postgres/README.md`](./postgres/README.md) for the full inputs/outputs reference, IAM permissions, and password rotation.

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
  platform: "aws"
  dnsRecord: "your-domain.example.com"
  authType: "OIDC"                         # or "AUTH0"

secrets:
  deployment:
    # REQUIRED. template.values.yaml ships this blank, and Helm refuses to render
    # while it is empty — copying the template is not sufficient. Paste the value
    # exactly as issued; never reuse it for another installation.
    identifier: "<provided by Qualytics>"
  oidc:
    oidc_discovery_url: "https://your-idp.example.com/.well-known/openid-configuration"
    oidc_scopes: "openid,email,profile"
    oidc_client_id: "your-client-id"
    oidc_client_secret: "your-client-secret"
  auth:
    jwt_signing_secret: "<openssl rand -base64 32>"
  postgres:
    host: "<db_host from Step 5 / Secrets Manager>"
    port: 5432
    database: "surveillance_hub"
    username: "postgres"
    password: "<password from Secrets Manager>"
    secrets_passphrase: "<openssl rand -base64 32>"
  rabbitmq:
    rabbitmq_password: "<openssl rand -base64 16>"

appNodeSelector:
  appNodes: "true"
driverNodeSelector:
  driverNodes: "true"
executorNodeSelector:
  executorNodes: "true"

nginx:
  enabled: true                            # template.values.yaml ships false
  controller:
    nodeSelector:
      appNodes: "true"
    service:
      annotations:
        # REQUIRED — Auto Mode defaults the NLB scheme to internal.
        service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
        # Instance targets preserve the client IP by default; IP targets do not.
        # The chart's per-IP rate limits depend on seeing real client addresses.
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "instance"
        # OPTIONAL — lets a load balancer node in one AZ reach nginx in another.
        # Adds cross-AZ data transfer cost.
        # service.beta.kubernetes.io/aws-load-balancer-attributes: "load_balancing.cross_zone.enabled=true"

ingress:
  enabled: true
  tls:
    secretName: "qualytics-tls-cert"       # the Secret created in Step 4

postgres:
  schema: "public"
  enabled: false                           # using Aurora, not in-cluster PostgreSQL

dataplane:
  enabled: true
  numVolumes: -1                           # required on Auto Mode — see below
  # Set driver and executor cores/memory from your tier in docs/cluster-sizing.md,
  # but keep numVolumes at -1 regardless of what the per-tier snippets there show.
```

**Leave `dataplane.numVolumes` at `-1`.** EKS Auto Mode formats the instance-store NVMe (RAID 0 across multiple drives) and uses it as the node's ephemeral storage, so Spark's scratch space lands on it automatically. A value greater than `0` makes the chart mount `hostPath /mnt/disks/nvme<n>n1` — a path nothing in these modules creates, because Auto Mode's NodeClass has no `userData` or `blockDeviceMappings` hooks.

Do **not** add a `storageClass:` block for this topology — see the appendix below.

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

The first install is slower than later upgrades: nodes are provisioned on demand and container images are pulled cold.

```bash
kubectl get pods -n qualytics
kubectl -n qualytics get secret qualytics-tls-cert
kubectl get nodepool
```

Expected: all pods `Running`, the TLS Secret present, and nodes provisioned in the `qualytics-*` pools.

---

## Step 8 — DNS configuration

```bash
kubectl get svc -n qualytics qualytics-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Route53 (alias record):**

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id <your-hosted-zone-id> \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "your-domain.example.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "<nlb-hosted-zone-id>",
          "DNSName": "dualstack.<nlb-hostname>",
          "EvaluateTargetHealth": false
        }
      }
    }]
  }'
```

Retrieve the NLB canonical hosted zone ID with:

```bash
aws elbv2 describe-load-balancers --region <your-region> \
  --query "LoadBalancers[?contains(DNSName,'<nlb-hostname>')].CanonicalHostedZoneId" \
  --output text
```

**Other DNS providers:** Create a CNAME record pointing `your-domain.example.com` to the NLB hostname.

> **Important:** The NLB is owned by the nginx controller Service, so its hostname changes on any full redeploy — `helm uninstall`, or deleting the `qualytics` namespace. Always update the DNS record afterwards.

---

## Step 9 — Verify the deployment

```bash
kubectl get pods -n qualytics

curl -sv https://your-domain.example.com 2>&1 | grep -E "issuer|subject|HTTP"

curl -s https://your-domain.example.com -o /dev/null -w "%{http_code}\n"
# Expected: 200
```

The second command deliberately omits `-k`. A `curl (60)` TLS error means the certificate is not trusted — usually the Secret from Step 4 is missing or its chain is incomplete, and nginx is serving its own self-signed certificate. Check the `issuer` line from the first command against your CA.

---

## Appendix — Persistent storage (optional)

On the path documented above the chart creates **zero** PersistentVolumeClaims: PostgreSQL is external and RabbitMQ uses `emptyDir` by default. No StorageClass is required, and none should be configured.

If you opt into in-cluster PostgreSQL (`postgres.enabled: true`) or a RabbitMQ PVC (`rabbitmq.pvc.enabled: true`) on an Auto Mode cluster, note:

- **Do not set `storageClass.create: true`.** The chart's built-in `aws` class uses provisioner `ebs.csi.aws.com` (the self-managed EBS CSI driver), which is not registered on Auto Mode. Auto Mode's managed block-storage capability registers `ebs.csi.eks.amazonaws.com` instead.
- **Auto Mode ships no StorageClass at all** — you must create one.
- `storageClass.create` and `storageClass.name` are mutually exclusive: `name` is honoured only when `create` is `false`.

Create your own class and point the chart at it:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: qualytics-auto-ebs
provisioner: ebs.csi.eks.amazonaws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain          # set deliberately; Delete discards data on PVC deletion
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
  iops: "4000"
  throughput: "200"
```

```yaml
storageClass:
  create: false
  name: "qualytics-auto-ebs"
```

Do not name your class `aws` — the chart hardcodes that name when `create: true`, so a later toggle would collide with a Helm-owned object. IOPS and throughput must be set in the class `parameters`: the chart's PVC annotations target `ebs.csi.aws.com` and are inert here.

Alternatively, mark your class `storageclass.kubernetes.io/is-default-class: "true"` and leave `storageClass` at the chart defaults — with `create: false` and `name: ""` the PVCs render with no `storageClassName` and bind to the cluster default. Without a default class they stay `Pending` indefinitely.

---

## Teardown

```bash
helm uninstall qualytics -n qualytics
```

Destroy Aurora before the cluster — Aurora lives in the cluster VPC. `deletion_protection` defaults to `true`, so a bare `terraform destroy` fails; clear it first:

```bash
cd "$(git rev-parse --show-toplevel)/terraform/aws/postgres"
terraform apply -var="deletion_protection=false" -var="skip_final_snapshot=true"
terraform destroy
```

```bash
cd "$(git rev-parse --show-toplevel)/terraform/aws/cluster"
terraform destroy
```

The S3 state bucket is not destroyed by these commands — it persists for reuse. Your TLS Secret lives in the `qualytics` namespace and is destroyed with the cluster, so keep the certificate and private key stored outside the cluster.

Dropping `-var="skip_final_snapshot=true"` leaves a final snapshot behind after the cluster is gone; it is billed as storage and must be deleted separately (`aws rds delete-db-cluster-snapshot`). Terraform also owns the Aurora CloudWatch log group, so `terraform destroy` deletes it and its logs — set `cloudwatch_log_group_skip_destroy = true` if the logs must outlive the cluster.

> **Redeployment note:** Secrets Manager holds deleted secrets for up to 30 days. If a subsequent `terraform apply` fails with `InvalidRequestException: secret is already scheduled for deletion`, force-delete the old secret first:
> ```bash
> aws secretsmanager delete-secret \
>   --secret-id "<cluster-name>-postgres-password" \
>   --force-delete-without-recovery \
>   --region <your-region>
> ```
> Then re-run `terraform apply`.

---

## Support

Contact your [Qualytics account manager](mailto:hello@qualytics.ai) for assistance.
