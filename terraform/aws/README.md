# Qualytics on AWS — EKS Auto Mode + Aurora PostgreSQL

This guide walks through deploying a Qualytics self-hosted instance on AWS EKS Auto Mode with Aurora PostgreSQL as the external database.

## Architecture

```
Internet → NLB (TLS/ACM) → nginx ingress → Qualytics pods
                                            ↓
                                     Aurora PostgreSQL (VPC-private)
```

- **EKS Auto Mode** — AWS-managed compute; Karpenter provisions nodes on demand
- **Aurora PostgreSQL** — external managed database; replaces the in-cluster PostgreSQL StatefulSet
- **ACM** — TLS certificate auto-issued and auto-renewed; attached to the NLB
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

AWS credentials must have permissions to create EKS, VPC, RDS, IAM, Secrets Manager, and ACM resources.

---

## Step 1 — One-time: Create S3 state backend

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

Note the bucket name — you will pass it to `terraform init` in the next steps.

---

## Step 2 — One-time: Request ACM certificate

ACM issues and auto-renews the TLS certificate. The private key never leaves AWS — no Kubernetes Secret is needed.

> **Already have a certificate?** If you have an existing ACM certificate for your domain, skip to the end of this step and retrieve its ARN:
> ```bash
> aws acm list-certificates --region <your-region> \
>   --query "CertificateSummaryList[?DomainName=='your-domain.example.com'].CertificateArn" \
>   --output text
> ```
> If you have a certificate from a third-party CA (Let's Encrypt, DigiCert, corporate CA, etc.), import it into ACM first — it will then work identically to a native ACM certificate:
> ```bash
> aws acm import-certificate \
>   --certificate fileb://cert.pem \
>   --private-key fileb://privkey.pem \
>   --certificate-chain fileb://chain.pem \
>   --region <your-region>
> ```
> Note that imported certificates do not auto-renew — you will need to re-import when they expire.

```bash
CERT_ARN=$(aws acm request-certificate \
  --domain-name "your-domain.example.com" \
  --validation-method DNS \
  --region <your-region> \
  --output text --query "CertificateArn")

echo "Certificate ARN: $CERT_ARN"

aws acm describe-certificate \
  --certificate-arn "$CERT_ARN" \
  --region <your-region> \
  --query "Certificate.DomainValidationOptions[0].ResourceRecord"
```

Add the returned CNAME record to your DNS provider (Route53, Cloudflare, or any other). The DNS provider and domain registrar do not need to be in the same AWS account as the certificate.

```bash
aws acm wait certificate-validated \
  --certificate-arn "$CERT_ARN" \
  --region <your-region> \
  && echo "Certificate validated: $CERT_ARN"
```

Save the `CERT_ARN` — you will need it in Step 5.

---

## Step 3 — Deploy EKS cluster

```bash
cd terraform/aws/cluster
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
cluster_name          = "your-cluster-name"
aws_region            = "<your-region>"
kubernetes_version    = "1.35"
docker_registry_token = "dckr_oat_..."   # from your Qualytics account manager

# Optional: grant additional IAM users or roles cluster admin access.
# The identity running terraform apply is automatically granted admin access.
# cluster_admin_arns = ["arn:aws:iam::123456789012:role/my-ci-role"]

# See docs/cluster-sizing.md for instance type recommendations by workload size.
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

This creates the VPC, EKS Auto Mode control plane, IAM roles, NodeClass and NodePool resources for app/driver/executor nodes, the `qualytics` namespace, and the `regcred` Docker registry Secret.

Expected duration: **12–18 minutes**.

Once complete, configure `kubectl` to connect to the cluster. This writes credentials to your kubeconfig file (`~/.kube/config` on Mac/Linux, `%USERPROFILE%\.kube\config` on Windows) and works on both platforms:

```bash
aws eks update-kubeconfig --region <your-region> --name <cluster-name>
kubectl get nodes   # returns "No resources found" until pods are scheduled — this is normal
```

See [`cluster/README.md`](./cluster/README.md) for the full inputs/outputs reference.

---

## Step 4 — Deploy Aurora PostgreSQL

Aurora reads the VPC and subnet IDs from the cluster state file — run Step 3 first.

```bash
cd terraform/aws/postgres
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
cluster_name       = "your-cluster-name"   # must match Step 3
aws_region         = "<your-region>"
tfstate_bucket     = "<your-tfstate-bucket>"   # same bucket as Step 1
postgresql_version = "17.9"
instance_class     = "db.r8g.large"   # see docs/cluster-sizing.md for sizing guidance
```

> **Note:** `tfstate_bucket` in `terraform.tfvars` and the `bucket` in `-backend-config` must be the same S3 bucket. The backend config is where Terraform writes the postgres module's own state; the variable is where it reads the cluster state to get VPC and subnet IDs. If they differ, Aurora is deployed into the wrong VPC.

Deploy:

```bash
terraform init \
  -backend-config="bucket=<your-tfstate-bucket>" \
  -backend-config="region=<your-region>"
terraform apply
```

This creates the Aurora PostgreSQL cluster in the same VPC as EKS, a security group allowing port 5432 from within the VPC, and a Secrets Manager secret with the connection credentials.

Expected duration: **10–15 minutes**.

Retrieve the connection details from AWS Secrets Manager:

```bash
aws secretsmanager get-secret-value \
  --secret-id "<cluster-name>-postgres-password" \
  --region <your-region> \
  --query SecretString \
  --output text | jq .
```

See [`postgres/README.md`](./postgres/README.md) for the full inputs/outputs reference, IAM permissions, and password rotation instructions.

---

## Step 5 — Configure Helm values

```bash
cd qualytics-self-hosted
cp template.values.yaml values.yaml
```

Edit `values.yaml`:

```yaml
storageClass:
  create: true
  name: "aws"

global:
  platform: "aws"
  awsAutoMode: true                        # EKS Auto Mode
  dnsRecord: "your-domain.example.com"
  authType: "OIDC"                         # or "AUTH0"

secrets:
  oidc:
    oidc_discovery_url: "https://your-idp.example.com/.well-known/openid-configuration"
    oidc_client_id: "your-client-id"
    oidc_client_secret: "your-client-secret"
    oidc_scopes: "openid,email,profile"
  auth:
    jwt_signing_secret: "<openssl rand -base64 32>"
  postgres:
    host: "<host from Secrets Manager>"
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
  enabled: true
  controller:
    nodeSelector:
      appNodes: "true"
    service:
      targetPorts:
        https: http                        # NLB terminates TLS, forwards HTTP to nginx
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
        service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "<CERT_ARN from Step 2>"
        service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
        service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"

ingress:
  enabled: true
  upstreamTLS: true                        # TLS terminated at NLB — no Kubernetes Secret needed

postgres:
  enabled: false                           # using Aurora, not in-cluster PostgreSQL

dataplane:
  enabled: true
  numVolumes: -1                           # Auto Mode mounts NVMe automatically
  # Set driver and executor cores/memory based on your chosen instance types.
  # See docs/cluster-sizing.md for recommended values.

rabbitmq:
  pvc:
    enabled: false
```

---

## Step 6 — Deploy Qualytics

```bash
helm upgrade --install qualytics charts/qualytics \
  --namespace qualytics \
  --create-namespace \
  -f values.yaml \
  --wait \
  --timeout=10m
```

Expected duration: **3–5 minutes** for pods to reach Running state (nodes provision on first schedule).

```bash
kubectl get pods -n qualytics
kubectl get storageclass aws
```

Expected output:
- All pods in `Running` state
- StorageClass `aws` with provisioner `ebs.csi.eks.amazonaws.com`

---

## Step 7 — DNS configuration

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

> **Important:** The NLB hostname changes whenever the `qualytics` namespace is deleted and redeployed. Always update the DNS record after a full redeploy.

---

## Step 8 — Verify deployment

```bash
kubectl get pods -n qualytics

curl -sv https://your-domain.example.com 2>&1 | grep -E "issuer|subject|HTTP"

curl -sk https://your-domain.example.com -o /dev/null -w "%{http_code}"
# Expected: 200
```

---

## Teardown

```bash
# 1. Uninstall Helm release
helm uninstall qualytics -n qualytics

# 2. Destroy Aurora (must be before cluster — Aurora lives in the cluster VPC)
cd terraform/aws/postgres && terraform destroy

# 3. Destroy EKS cluster and VPC
cd terraform/aws/cluster && terraform destroy
```

The ACM certificate and S3 state bucket are not destroyed by these commands — they persist for reuse.

> **Redeployment note:** Secrets Manager holds deleted secrets for up to 30 days. If a subsequent `terraform apply` fails with `InvalidRequestException: secret is already scheduled for deletion`, force-delete the old secret first:
> ```bash
> aws secretsmanager delete-secret \
>   --secret-id "<cluster-name>-postgres-password" \
>   --force-delete-without-recovery \
>   --region <your-region>
> ```
> Then re-run `terraform apply`.
