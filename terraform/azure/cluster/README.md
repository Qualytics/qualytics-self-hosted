# AKS Cluster — Reference

See [`../README.md`](../README.md) for the full deployment walkthrough.

## What This Creates

| Resource | Description |
|---|---|
| Resource group | `<cluster_name>-rg`, holds everything below (and the PostgreSQL resources from `terraform/azure/postgres`) |
| Virtual network | `vnet_cidr` (`10.0.0.0/16`) with one AKS subnet (`10.0.0.0/20`) |
| AKS cluster | Azure CNI + Azure network policy, standard load balancer, system-assigned identity, a one-node `system` pool |
| Node pools × 3 | App, Spark driver, Spark executor (Spot by default), all pinned to `node_group_az` |
| Storage classes | `azure-fast` (Premium SSD, Immediate binding) and `azure-slow` (Standard SSD, WaitForFirstConsumer) |
| `qualytics` namespace | Set `create_qualytics_namespace = false` only if managing the namespace outside Terraform |
| `qualytics-egress-info` ConfigMap | Outbound public IP and AKS subnet range, read by Qualytics to show datastore allow-list addresses |
| `regcred` Secret | Docker registry pull secret — created when `docker_registry_token` is set |

## Node Pool Defaults

See [`docs/cluster-sizing.md`](../../../docs/cluster-sizing.md) for VM size recommendations by workload size.

| Pool | Label | Default VM Size | vCPUs | Memory |
|------|-------|-----------------|-------|--------|
| Application | `appNodes=true` | Standard_D8s_v5 | 8 | 32 GB |
| Spark driver | `driverNodes=true` | Standard_E8s_v5 | 8 | 64 GB |
| Spark executor | `executorNodes=true` | Standard_E8ds_v5 | 8 | 64 GB |

All three pools are pinned to one availability zone (`node_group_az`, default `1`). Managed Disks are zone-locked, so a replacement node in another zone could not attach the existing volumes. `terraform/azure/postgres` places the database primary in the same zone.

Executor nodes use Spot VMs by default (`executor_use_spot = true`). On `global.platform: azure` the chart backs Spark scratch directories with `emptyDir` (node ephemeral storage), not the temp SSD — see [`docs/cluster-sizing.md`](../../../docs/cluster-sizing.md).

## Node Taints

`enable_node_taints` defaults to `true`, in both `variables.tf` and the shipped `terraform.tfvars.example`. Add the matching `tolerations` to your Helm values — see [`../../README.md`](../../README.md#node-taints).

## Inputs

| Name | Description | Default |
|---|---|---|
| `subscription_id` | Azure subscription ID | required |
| `location` | Azure region | `eastus` |
| `cluster_name` | AKS cluster name and resource name prefix | `qualytics` |
| `kubernetes_version` | Kubernetes version | `1.33` |
| `vnet_cidr` | Virtual network CIDR | `10.0.0.0/16` |
| `aks_subnet_cidr` | AKS subnet CIDR (inside `vnet_cidr`) | `10.0.0.0/20` |
| `service_cidr` | Kubernetes service CIDR (outside `vnet_cidr`) | `10.1.0.0/16` |
| `dns_service_ip` | Cluster DNS IP (inside `service_cidr`) | `10.1.0.10` |
| `api_server_authorized_ip_ranges` | CIDRs allowed to reach the API server (empty = unrestricted) | `[]` |
| `sku_tier` | AKS tier (`Free` or `Standard`) | `Standard` |
| `node_group_az` | Availability zone for all node pools | `1` |
| `app_node_vm_size` / `_min_count` / `_max_count` / `_os_disk_size_gb` | Application pool | `Standard_D8s_v5`, 1–3, 128 GB |
| `driver_node_vm_size` / `_min_count` / `_max_count` / `_os_disk_size_gb` | Driver pool | `Standard_E8s_v5`, 0–1, 128 GB |
| `executor_node_vm_size` / `_min_count` / `_max_count` / `_os_disk_size_gb` | Executor pool | `Standard_E8ds_v5`, 1–12, 128 GB |
| `executor_use_spot` | Spot VMs for executors | `true` |
| `executor_spot_max_price` | Spot max price (`-1` = up to on-demand) | `-1` |
| `enable_node_taints` | Taint node pools for dedicated workloads | `true` |
| `create_qualytics_namespace` | Create the `qualytics` namespace | `true` |
| `docker_registry_token` | Registry token (provided by Qualytics) | `""` |
| `default_tags` | Tags applied to all resources | see variables.tf |

## Outputs

| Name | Description |
|---|---|
| `subscription_id` | Subscription hosting the cluster (used by `terraform/azure/postgres`) |
| `resource_group_name` / `resource_group_location` | Resource group (used by `terraform/azure/postgres`) |
| `node_group_az` | Node pool zone (used by `terraform/azure/postgres`) |
| `cluster_name` / `cluster_id` / `cluster_fqdn` / `cluster_version` | AKS cluster |
| `kube_config_raw` | Raw kubeconfig (sensitive) |
| `vnet_id` / `vnet_name` / `vnet_address_space` | Virtual network (used by `terraform/azure/postgres`) |
| `aks_subnet_id` | AKS subnet |
| `node_pools` | Node pool settings |
| `cluster_identity` / `kubelet_identity` | Managed identities |
| `node_resource_group` | AKS-managed node resource group |
| `configure_kubectl` | Ready-to-run `az aks get-credentials` command |
| `next_steps` | Post-apply deployment instructions printed by Terraform |

## State

State is stored in an Azure Storage blob (`azure/cluster/terraform.tfstate`); the storage account is passed at init time:

```bash
terraform init \
  -backend-config="resource_group_name=<tfstate-resource-group>" \
  -backend-config="storage_account_name=<tfstate-storage-account>" \
  -backend-config="container_name=tfstate"
```

The backend locks state with a blob lease. `terraform/azure/postgres` reads this state to find the subscription, resource group, VNet and zone.
