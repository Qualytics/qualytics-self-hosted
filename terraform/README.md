# Qualytics Terraform Templates

This directory contains Terraform templates for deploying the infrastructure required to run Qualytics self-hosted instances on major cloud providers.

## Available Templates

| Cloud Provider | Directory | Description |
|----------------|-----------|-------------|
| AWS | [`/aws`](./aws) | Amazon Elastic Kubernetes Service (EKS) + Aurora PostgreSQL |
| GCP | [`/gcp`](./gcp) | Google Kubernetes Engine (GKE) + AlloyDB for PostgreSQL |
| Azure | [`/azure`](./azure) | Azure Kubernetes Service (AKS) + Azure Database for PostgreSQL |

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

Each deployment is two Terraform modules applied in order — `<cloud>/cluster` then
`<cloud>/postgres` — plus TLS and Helm setup. The second module creates the cloud-managed
PostgreSQL (Aurora on AWS, AlloyDB on GCP, Azure Database for PostgreSQL Flexible Server on
Azure) that Qualytics uses instead of the in-cluster StatefulSet. Follow the guide for your
cloud:

- [`aws/README.md`](./aws/README.md)
- [`gcp/README.md`](./gcp/README.md)
- [`azure/README.md`](./azure/README.md)

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

- [Terraform](https://www.terraform.io/downloads) >= 1.3.0 (the AWS modules require >= 1.11.1 for S3 backend state locking; `gcp/postgres` and `azure/postgres` require >= 1.11.1 for write-only password arguments)
- Cloud provider CLI configured with appropriate credentials:
  - AWS: `aws configure`
  - GCP: `gcloud auth application-default login`
  - Azure: `az login`
- A Qualytics-issued image registry token and a unique deployment identifier

## Post-Deployment

Follow the complete step-by-step guide for your cloud — [`aws/README.md`](./aws/README.md),
[`gcp/README.md`](./gcp/README.md) or [`azure/README.md`](./azure/README.md). Each covers
TLS certificate setup (bring-your-own Secret), the managed PostgreSQL (Aurora / AlloyDB /
Azure Database for PostgreSQL), Helm configuration, DNS, and verification.

## Support

- For Terraform template issues, please open an issue in this repository
- For Qualytics-specific support, contact your [Qualytics account manager](mailto:hello@qualytics.ai)
- See the [Qualytics User Guide](https://userguide.qualytics.io/upgrades/qualytics-single-tenant-instance/) for deployment documentation
