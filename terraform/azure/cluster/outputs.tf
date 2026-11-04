################################################################################
# Qualytics AKS Outputs
################################################################################

#-------------------------------------------------------------------------------
# Cluster Information
#-------------------------------------------------------------------------------

output "cluster_name" {
  description = "The name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.qualytics.name
}

output "cluster_id" {
  description = "The ID of the AKS cluster"
  value       = azurerm_kubernetes_cluster.qualytics.id
}

output "cluster_fqdn" {
  description = "The FQDN of the AKS cluster"
  value       = azurerm_kubernetes_cluster.qualytics.fqdn
}

output "cluster_version" {
  description = "The Kubernetes version of the cluster"
  value       = azurerm_kubernetes_cluster.qualytics.kubernetes_version
}

output "kube_config_raw" {
  description = "Raw kubeconfig for the cluster"
  value       = azurerm_kubernetes_cluster.qualytics.kube_config_raw
  sensitive   = true
}

#-------------------------------------------------------------------------------
# Resource Group
#-------------------------------------------------------------------------------

output "subscription_id" {
  description = "Azure subscription hosting the cluster (read by terraform/azure/postgres)"
  value       = var.subscription_id
}

output "resource_group_name" {
  description = "The name of the resource group"
  value       = azurerm_resource_group.qualytics.name
}

output "resource_group_location" {
  description = "The location of the resource group"
  value       = azurerm_resource_group.qualytics.location
}

output "node_group_az" {
  description = "Availability zone the node pools are pinned to (read by terraform/azure/postgres to co-locate the database primary)"
  value       = var.node_group_az
}

#-------------------------------------------------------------------------------
# Networking
#-------------------------------------------------------------------------------

output "vnet_id" {
  description = "The ID of the Virtual Network"
  value       = azurerm_virtual_network.qualytics.id
}

output "vnet_name" {
  description = "The name of the Virtual Network"
  value       = azurerm_virtual_network.qualytics.name
}

output "vnet_address_space" {
  description = "Address space of the Virtual Network (read by terraform/azure/postgres for its subnet NSG rule)"
  value       = azurerm_virtual_network.qualytics.address_space
}

output "aks_subnet_id" {
  description = "The ID of the AKS subnet"
  value       = azurerm_subnet.aks.id
}

#-------------------------------------------------------------------------------
# Node Pools
#-------------------------------------------------------------------------------

output "node_pools" {
  description = "Map of node pool names to their configurations"
  value = {
    app_nodes = {
      name      = azurerm_kubernetes_cluster_node_pool.app.name
      vm_size   = var.app_node_vm_size
      min_count = var.app_node_min_count
      max_count = var.app_node_max_count
    }
    driver_nodes = {
      name      = azurerm_kubernetes_cluster_node_pool.driver.name
      vm_size   = var.driver_node_vm_size
      min_count = var.driver_node_min_count
      max_count = var.driver_node_max_count
    }
    executor_nodes = {
      name      = azurerm_kubernetes_cluster_node_pool.executor.name
      vm_size   = var.executor_node_vm_size
      min_count = var.executor_node_min_count
      max_count = var.executor_node_max_count
    }
  }
}

#-------------------------------------------------------------------------------
# Identity
#-------------------------------------------------------------------------------

output "cluster_identity" {
  description = "The managed identity of the AKS cluster"
  value = {
    principal_id = azurerm_kubernetes_cluster.qualytics.identity[0].principal_id
    tenant_id    = azurerm_kubernetes_cluster.qualytics.identity[0].tenant_id
  }
}

output "kubelet_identity" {
  description = "The kubelet identity of the AKS cluster"
  value = {
    client_id   = azurerm_kubernetes_cluster.qualytics.kubelet_identity[0].client_id
    object_id   = azurerm_kubernetes_cluster.qualytics.kubelet_identity[0].object_id
    resource_id = azurerm_kubernetes_cluster.qualytics.kubelet_identity[0].user_assigned_identity_id
  }
}

output "node_resource_group" {
  description = "The auto-generated resource group for AKS nodes"
  value       = azurerm_kubernetes_cluster.qualytics.node_resource_group
}

#-------------------------------------------------------------------------------
# kubectl Configuration
#-------------------------------------------------------------------------------

output "configure_kubectl" {
  description = "Command to configure kubectl for the cluster"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.qualytics.name} --name ${azurerm_kubernetes_cluster.qualytics.name}"
}

#-------------------------------------------------------------------------------
# Next Steps
#-------------------------------------------------------------------------------

output "next_steps" {
  description = "Instructions for deploying Qualytics"
  value       = <<-EOT

    ============================================================
    AKS Cluster Successfully Created!
    ============================================================

    Next steps to deploy Qualytics:

    1. Configure kubectl:
       az aks get-credentials --resource-group ${azurerm_resource_group.qualytics.name} --name ${azurerm_kubernetes_cluster.qualytics.name}

    2. Verify cluster access:
       kubectl get nodes

    3. Prepare values.yaml using the repository template and set the unique
       secrets.deployment.identifier provided by Qualytics.

    4. If you haven't already, create the Docker registry secret:
       printf "Qualytics registry token: "
       IFS= read -rs QUALYTICS_REGISTRY_TOKEN
       echo
       kubectl create secret docker-registry regcred -n qualytics \
         --docker-username=qualyticsai \
         --docker-password="$QUALYTICS_REGISTRY_TOKEN"
       unset QUALYTICS_REGISTRY_TOKEN

    5. Create the TLS Secret for your domain (see docs/ingress-tls.md)

    6. Deploy Azure Database for PostgreSQL:
       See terraform/azure/postgres

    7. Deploy Qualytics using Helm:
       helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
       helm repo update
       CHART_VERSION="<version provided by Qualytics>"
       helm upgrade --install qualytics qualytics/qualytics \
         --namespace qualytics \
         --version "$CHART_VERSION" \
         -f values.yaml \
         --wait \
         --timeout=5m

    Full step-by-step guide: terraform/azure/README.md
    https://github.com/qualytics/qualytics-self-hosted

  EOT
}
