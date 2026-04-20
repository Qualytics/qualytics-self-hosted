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

output "resource_group_name" {
  description = "The name of the resource group"
  value       = azurerm_resource_group.qualytics.name
}

output "resource_group_location" {
  description = "The location of the resource group"
  value       = azurerm_resource_group.qualytics.location
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

    3. If you haven't already, create the Docker registry secret:
       kubectl create secret docker-registry regcred -n qualytics \
         --docker-username=qualyticsai \
         --docker-password=<token-from-qualytics>

    4. Deploy Qualytics using Helm:
       helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
       helm repo update
       helm upgrade --install qualytics qualytics/qualytics \
         --namespace qualytics \
         -f values.yaml \
         --wait \
         --timeout=5m

    For more information, visit:
    https://github.com/qualytics/qualytics-self-hosted

  EOT
}
