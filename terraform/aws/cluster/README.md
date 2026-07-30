# EKS Cluster — Reference

See [`../README.md`](../README.md) for the full deployment walkthrough.

## What This Creates

| Resource | Description |
|---|---|
| VPC | Public and private subnets across 3 availability zones |
| NAT Gateway | Outbound internet access for private subnets |
| EKS cluster | Auto Mode control plane (AWS-managed Karpenter) |
| IAM roles | Cluster role and Auto Mode node provisioning role |
| NodeClass × 3 | App, Spark driver, Spark executor |
| NodePool × 3 | App, Spark driver, Spark executor (Karpenter-managed) |
| `qualytics` namespace | Required for Qualytics deployment — set `create_qualytics_namespace = false` only if managing the namespace outside Terraform |
| `regcred` Secret | Docker registry pull secret — created when `docker_registry_token` is set |

## Node Pool Defaults

See [`docs/cluster-sizing.md`](../../../docs/cluster-sizing.md) for instance type recommendations by workload size.

| Pool | Label | Default Instance | vCPUs | Memory | Storage |
|------|-------|-----------------|-------|--------|---------|
| Application | `appNodes=true` | m8g.2xlarge | 8 | 32 GB | EBS |
| Spark driver | `driverNodes=true` | r8g.2xlarge | 8 | 64 GB | EBS |
| Spark executor | `executorNodes=true` | r8gd.2xlarge | 8 | 64 GB | 474 GB NVMe |

All instances are Graviton4 (ARM64). For x86, use equivalent `m7i`, `r7i`, and `r7id` families.

Executor nodes use Spot capacity by default (`executor_capacity_type = "spot"`). Set to `"on-demand"` for guaranteed capacity.

## Inputs

| Name | Description | Default |
|---|---|---|
| `aws_region` | AWS region | `us-east-1` |
| `cluster_name` | EKS cluster name | `qualytics` |
| `kubernetes_version` | Kubernetes version | `1.35` |
| `vpc_cidr` | VPC CIDR block | `10.0.0.0/16` |
| `single_nat_gateway` | Use one NAT Gateway for all AZs | `true` |
| `cluster_endpoint_public_access` | Enable public API server endpoint | `true` |
| `cluster_endpoint_public_access_cidrs` | CIDRs allowed to reach the public API endpoint. Restrict to your VPN/office for production. Aurora and pod networking are unaffected. | `["0.0.0.0/0"]` |
| `app_node_instance_types` | Instance types for application nodes | `["m8g.2xlarge"]` |
| `driver_node_instance_types` | Instance types for Spark driver nodes | `["r8g.2xlarge"]` |
| `executor_node_instance_types` | Instance types for Spark executor nodes | `["r8gd.2xlarge"]` |
| `executor_capacity_type` | `on-demand` or `spot` for executor nodes | `spot` |
| `cluster_admin_arns` | IAM principal ARNs granted cluster admin | `[]` |
| `create_qualytics_namespace` | Create `qualytics` namespace and registry secret | `true` |
| `docker_registry_token` | Docker registry token (provided by Qualytics) | `""` |
| `default_tags` | Tags applied to all resources | see variables.tf |

## Outputs

| Name | Description |
|---|---|
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | API server endpoint |
| `cluster_version` | Kubernetes version |
| `cluster_arn` | Cluster ARN |
| `vpc_id` | VPC ID |
| `private_subnets` | Private subnet IDs (used by `terraform/aws/postgres`) |
| `public_subnets` | Public subnet IDs |
| `cluster_certificate_authority_data` | Base64 cluster CA data (sensitive) |
| `cluster_oidc_provider_arn` | ARN of the cluster's OIDC identity provider |
| `configure_kubectl` | Ready-to-run `aws eks update-kubeconfig` command |
| `next_steps` | Post-apply deployment instructions printed by Terraform |

## Node Placement and Availability Zones

Karpenter provisions nodes across all three private subnets, so the Spark driver and
its executors may land in different availability zones. Inter-AZ traffic between them
(shuffle, RPC) incurs data-transfer charges.

The spread is deliberate: it gives Karpenter multiple spot capacity pools to draw from,
which materially reduces the chance of an unfulfillable executor request. If predictable
data-transfer cost matters more than spot availability, add a
`topology.kubernetes.io/zone` requirement to the `qualytics-driver` and `qualytics-exec`
NodePools — at the cost of pinning the executor fleet to a single capacity pool.

## Notes on Consolidation

Karpenter, not the Kubernetes cluster autoscaler, manages node lifecycle here. The
chart's executor setting `cluster-autoscaler.kubernetes.io/safe-to-evict=false` has no
effect under Karpenter, so executor nodes remain consolidation candidates. The chart's
Spark decommission settings cover the drain when a node is reclaimed.

The `qualytics-app` NodePool carries the highest `spec.weight` so that pods with no node
selector — notably the ingress-nginx admission-webhook pre-install Jobs — schedule onto
on-demand app nodes rather than spot executor nodes.

## Partition Portability

This module is developed and tested in the standard `aws` partition. GovCloud and China
partitions are untested.
