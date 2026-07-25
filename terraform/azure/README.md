# Qualytics AKS Terraform Template

This Terraform template creates an Azure Kubernetes Service (AKS) cluster configured for running Qualytics self-hosted deployments.

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.3.0
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) >= 2.50.0
- Azure subscription with permissions to create resources
- A Qualytics-issued image registry token and a unique deployment identifier

## What This Template Creates

- **Resource Group**: Container for all Azure resources
- **Virtual Network**: Isolated network with dedicated AKS subnet
- **AKS Cluster**: Kubernetes 1.30+ with three specialized node pools:

| Node Pool | Purpose | Default VM Size | vCPUs | Memory |
|-----------|---------|-----------------|-------|--------|
| App | API, Frontend, PostgreSQL, RabbitMQ | Standard_D8s_v5 | 8 | 32 GB |
| Driver | Spark driver process | Standard_E8s_v5 | 8 | 64 GB |
| Executor | Spark executors (auto-scaling) | Standard_E8ds_v5 | 8 | 64 GB |

- **Storage Classes**:
  - `azure-fast`: Premium SSD for databases (Immediate binding)
  - `azure-slow`: Standard SSD for backups (WaitForFirstConsumer)

## Quick Start

1. **Authenticate with Azure**:
   ```bash
   az login
   az account set --subscription "your-subscription-id"
   ```

2. **Configure variables**:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your values
   ```

3. **Initialize and apply**:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. **Configure kubectl**:
   ```bash
   az aks get-credentials --resource-group qualytics-rg --name qualytics
   kubectl get nodes
   ```

## Configuration

### Required Variables

| Variable | Description |
|----------|-------------|
| `subscription_id` | Your Azure subscription ID |

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `cluster_name` | `qualytics` | Name of the AKS cluster |
| `location` | `eastus` | Azure region |
| `kubernetes_version` | `1.33` | Kubernetes version |
| `executor_use_spot` | `true` | Use Spot instances for executors |
| `enable_node_taints` | `true` | Enable node taints for workload isolation |

See `variables.tf` for the complete list of configurable options.

## Node Labels

The node pools are labeled to support Qualytics workload scheduling:

- `appNodes=true` - Application components
- `driverNodes=true` - Spark driver
- `executorNodes=true` - Spark executors

## Cost Optimization

- **Spot Instances**: Executor nodes use Azure Spot VMs by default (up to 90% savings)
- **Auto-scaling**: Executor pool scales from 1-12 nodes based on workload
- **SKU Tier**: Use `Free` tier for development/testing

## Security Considerations

- API server access can be restricted using `api_server_authorized_ip_ranges`
- Uses Azure CNI for pod networking with Network Policy support
- System-assigned managed identity (no service principal credentials required)

## Next Steps

After the cluster is created:

1. Obtain the image registry token and a unique deployment identifier from Qualytics
2. Deploy NGINX Ingress Controller
3. Configure DNS for your domain
4. Prepare `values.yaml` and deploy Qualytics using Helm by following the [main README](../../README.md)

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

## Support

For questions about this template, please open an issue in this repository.
For Qualytics-specific support, contact your Qualytics account manager.
