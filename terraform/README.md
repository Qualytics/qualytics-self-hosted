# Qualytics Terraform Templates

This directory contains Terraform templates for deploying the infrastructure required to run Qualytics self-hosted instances on major cloud providers.

## Available Templates

| Cloud Provider | Directory | Description |
|----------------|-----------|-------------|
| AWS | [`/aws`](./aws) | Amazon Elastic Kubernetes Service (EKS) |
| GCP | [`/gcp`](./gcp) | Google Kubernetes Engine (GKE) |
| Azure | [`/azure`](./azure) | Azure Kubernetes Service (AKS) |

## Overview

Each template creates a Kubernetes cluster with three dedicated node pools optimized for Qualytics workloads:

| Node Pool | Purpose | Recommended Specs |
|-----------|---------|-------------------|
| **Application** | API, Frontend, PostgreSQL, RabbitMQ | 8 vCPUs, 32 GB RAM |
| **Spark Driver** | Spark driver process | 8 vCPUs, 64 GB RAM |
| **Spark Executor** | Spark executor processes (auto-scaling) | 8 vCPUs, 64 GB RAM + Local SSD |

All templates include:
- Virtual network with appropriate subnets
- Dynamic node provisioning for executor nodes (Karpenter on AWS, cluster autoscaler on GCP/Azure)
- Node labels for workload isolation (GCP/Azure templates additionally support optional node taints)
- Optional automatic creation of the `qualytics` namespace and Docker registry secret

## Quick Start

**AWS:** the AWS deployment is two Terraform modules applied in order (`aws/cluster`, then
`aws/postgres`) plus TLS and Helm setup — follow [`aws/README.md`](./aws/README.md) instead
of the generic steps below.

**GCP / Azure:**

1. **Choose your cloud provider** and navigate to the appropriate directory
2. **Copy the example configuration**: `cp terraform.tfvars.example terraform.tfvars`
3. **Edit the configuration** with your settings (subscription/project ID, region, etc.)
4. **Initialize Terraform**: `terraform init`
5. **Preview changes**: `terraform plan`
6. **Apply changes**: `terraform apply`
7. **Configure kubectl** using the command shown in the output
8. **Deploy Qualytics** using the Helm chart

## Node Labels

All templates configure the following node labels for Qualytics workload scheduling:

- `appNodes=true` - Application nodes
- `driverNodes=true` - Spark driver nodes
- `executorNodes=true` - Spark executor nodes

## Node Taints

Applies to the GCP and Azure templates. The AWS template isolates workloads by node label
and `nodeSelector` only.

The GCP and Azure templates enable taints on their node pools by default
(`enable_node_taints`) to ensure workloads only run on appropriate nodes. Configure your
Helm values.yaml with matching tolerations:

```yaml
tolerations:
  appNodeTolerations:
    - key: appNodes
      operator: Equal
      value: "true"
      effect: NoSchedule
  driverNodeTolerations:
    - key: driverNodes
      operator: Equal
      value: "true"
      effect: NoSchedule
  executorNodeTolerations:
    - key: executorNodes
      operator: Equal
      value: "true"
      effect: NoSchedule
```

## Cost Optimization

Each template supports cost optimization features:

- **Spot/Preemptible instances** for executor nodes (configurable)
- **Cluster autoscaling** for dynamic workload scaling
- **Right-sized node pools** based on workload requirements

## Security Considerations

- All clusters use private networking where possible
- API server access can be restricted to specific IP ranges
- Managed identities are used instead of static credentials
- Node labels for workload isolation (`appNodes`, `driverNodes`, `executorNodes`)

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.3.0 (the AWS modules require >= 1.11.1 for S3 backend state locking)
- Cloud provider CLI configured with appropriate credentials:
  - AWS: `aws configure`
  - GCP: `gcloud auth application-default login`
  - Azure: `az login`
- A Qualytics-issued image registry token and a unique deployment identifier

## Post-Deployment

**AWS:** Follow the complete step-by-step guide in [`aws/README.md`](./aws/README.md) — it
covers TLS certificate setup (bring-your-own Secret), Aurora PostgreSQL, Helm
configuration, DNS, and verification.

**GCP / Azure:** After creating the cluster:

1. Verify cluster access: `kubectl get nodes`
2. Create the `qualytics` namespace and Docker registry secret (if not done automatically):
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
3. Return to the repository root, prepare the Helm configuration, and set the unique deployment identifier provided by Qualytics:
   ```bash
   cd ../..
   cp template.values.yaml values.yaml
   chmod 600 values.yaml
   ```
   ```yaml
   secrets:
     deployment:
       identifier: "<provided by Qualytics>"
   ```
4. Deploy Qualytics using Helm:
   ```bash
   helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
   helm repo update
   CHART_VERSION="<version provided by Qualytics>"
   helm upgrade --install qualytics qualytics/qualytics \
     --namespace qualytics \
     --version "$CHART_VERSION" \
     -f values.yaml \
     --wait \
     --timeout=5m
   ```

## Support

- For Terraform template issues, please open an issue in this repository
- For Qualytics-specific support, contact your [Qualytics account manager](mailto:hello@qualytics.ai)
- See the [Qualytics User Guide](https://userguide.qualytics.io/upgrades/qualytics-single-tenant-instance/) for deployment documentation
