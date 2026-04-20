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
| **Application** | API, Frontend, PostgreSQL, RabbitMQ, operators | 8 vCPUs, 32 GB RAM |
| **Spark Driver** | Spark driver process | 8 vCPUs, 64 GB RAM |
| **Spark Executor** | Spark executor processes (auto-scaling) | 8 vCPUs, 64 GB RAM + Local SSD |

All templates include:
- Virtual network with appropriate subnets
- Cluster autoscaling for executor nodes
- Node labels and optional taints for workload isolation
- Optional automatic creation of the `qualytics` namespace and Docker registry secret

## Quick Start

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

By default, templates can enable taints on node pools to ensure workloads only run on appropriate nodes. Configure your Helm values.yaml with matching tolerations:

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
- Network policies are enabled for pod-level security

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.3.0
- Cloud provider CLI configured with appropriate credentials:
  - AWS: `aws configure`
  - GCP: `gcloud auth application-default login`
  - Azure: `az login`
- Docker registry credentials from your Qualytics account manager

## Post-Deployment

After creating the cluster:

1. Verify cluster access: `kubectl get nodes`
2. Create Docker registry secret (if not done automatically):
   ```bash
   kubectl create secret docker-registry regcred -n qualytics \
     --docker-username=qualyticsai \
     --docker-password=<token-from-qualytics>
   ```
3. Deploy Qualytics using Helm:
   ```bash
   helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
   helm repo update
   helm upgrade --install qualytics qualytics/qualytics \
     --namespace qualytics \
     -f values.yaml \
     --wait \
     --timeout=5m
   ```

## Support

- For Terraform template issues, please open an issue in this repository
- For Qualytics-specific support, contact your [Qualytics account manager](mailto:hello@qualytics.ai)
- See the [Qualytics User Guide](https://userguide.qualytics.io/upgrades/qualytics-single-tenant-instance/) for deployment documentation
