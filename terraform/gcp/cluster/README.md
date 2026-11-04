# GKE Cluster — Reference

See [`../README.md`](../README.md) for the full deployment walkthrough.

## What This Creates

| Resource | Description |
|---|---|
| GCP project | Created only when `project_id = ""` (requires `billing_account` and `folder_id`) |
| Required APIs | `compute`, `container`, `servicenetworking` |
| VPC network | One private subnet with secondary ranges for pods and services |
| Cloud NAT | Outbound internet access for private nodes, with `nat_ip_count` static IPs |
| GKE cluster | Regional control plane, default node pool removed |
| Node pools × 3 | App, Spark driver, Spark executor (local SSDs, Spot by default) |
| `qualytics` namespace | Set `create_qualytics_namespace = false` only if managing the namespace outside Terraform |
| `qualytics-egress-info` ConfigMap | Public (Cloud NAT) and private egress ranges, read by Qualytics to show datastore allow-list addresses |
| `regcred` Secret | Docker registry pull secret — created when `docker_registry_token` is set |

## Node Pool Defaults

See [`docs/cluster-sizing.md`](../../../docs/cluster-sizing.md) for machine type recommendations by workload size.

| Pool | Label | Default Machine | vCPUs | Memory | Storage |
|------|-------|-----------------|-------|--------|---------|
| Application | `appNodes=true` | n4-standard-8 | 8 | 32 GB | PD |
| Spark driver | `driverNodes=true` | n4-highmem-8 | 8 | 64 GB | PD |
| Spark executor | `executorNodes=true` | n2-highmem-8 | 8 | 64 GB | 2 × 375 GB Local SSD |

N4 machines do not support local SSDs, so executors use the N2 series. GKE mounts each local SSD at `/mnt/disks/ssd<n>`; set the chart's `dataplane.numVolumes` to `executor_local_ssd_count`.

Executor nodes use Spot VMs by default (`executor_use_spot = true`).

## Node Taints

`enable_node_taints` defaults to `true` in `variables.tf`, but the shipped `terraform.tfvars.example` sets it to `false`. When enabled, add the matching `tolerations` to your Helm values — see [`../../README.md`](../../README.md#node-taints).

## Inputs

| Name | Description | Default |
|---|---|---|
| `tenant_name` | Tenant name, used for project naming | required |
| `project_id` | Existing project ID; empty to create one | `""` |
| `billing_account` | Billing account for project creation | required (may be `""` when `project_id` is set) |
| `folder_id` | Folder for project creation | required (may be `""` when `project_id` is set) |
| `region` | GCP region | `us-central1` |
| `cluster_name` | GKE cluster name and resource name prefix | `qualytics` |
| `deletion_protection` | GKE deletion protection | `true` |
| `subnet_cidr` | Node subnet CIDR | `10.10.0.0/16` |
| `pods_cidr` | Pods secondary range | `10.11.0.0/16` |
| `services_cidr` | Services secondary range | `10.12.0.0/16` |
| `nat_ip_count` | Static Cloud NAT IPs | `1` |
| `master_authorized_networks` | CIDRs allowed to reach the API server | `0.0.0.0/0` |
| `app_node_machine_type` / `_min_size` / `_max_size` | Application pool | `n4-standard-8`, 1–3 |
| `driver_node_machine_type` / `_min_size` / `_max_size` | Driver pool | `n4-highmem-8`, 0–1 |
| `executor_node_machine_type` / `_min_size` / `_max_size` | Executor pool | `n2-highmem-8`, 1–12 |
| `executor_use_spot` | Spot VMs for executors | `true` |
| `executor_local_ssd_count` | Local SSDs per executor node (375 GB each) | `2` |
| `enable_node_taints` | Taint node pools for dedicated workloads | `true` |
| `create_qualytics_namespace` | Create the `qualytics` namespace | `true` |
| `docker_registry_token` | Registry token (provided by Qualytics) | `""` |
| `default_labels` | Labels applied to all resources | see variables.tf |

## Outputs

| Name | Description |
|---|---|
| `project_id` | Project hosting the cluster (used by `terraform/gcp/postgres`) |
| `region` | Cluster region |
| `cluster_name` | GKE cluster name |
| `cluster_endpoint` | API server endpoint |
| `cluster_ca_certificate` | Base64 cluster CA (sensitive) |
| `cluster_location` | Cluster location |
| `network_name` / `network_id` | VPC network (`network_id` is used by `terraform/gcp/postgres`) |
| `subnet_name` / `subnet_id` | Node subnet |
| `node_pools` | Node pool settings |
| `configure_kubectl` | Ready-to-run `gcloud container clusters get-credentials` command |
| `next_steps` | Post-apply deployment instructions printed by Terraform |

## State

State is stored in GCS under the `gcp/cluster` prefix; the bucket is passed at init time:

```bash
terraform init -backend-config="bucket=<your-tfstate-bucket>"
```

`terraform/gcp/postgres` reads this state to find the project and network, so the identity running that module needs read access to the bucket.
