################################################################################
# Qualytics AKS Storage Classes
#
# Creates custom storage classes for Qualytics workloads:
# - azure-fast: Premium SSD for high-performance workloads (databases)
# - azure-slow: Standard SSD for general workloads (backups, logs)
################################################################################

resource "kubernetes_storage_class" "azure_fast" {
  metadata {
    name = "azure-fast"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "qualytics"
    }
  }

  storage_provisioner    = "disk.csi.azure.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    skuName = "Premium_LRS"
  }

  depends_on = [azurerm_kubernetes_cluster.qualytics]
}

resource "kubernetes_storage_class" "azure_slow" {
  metadata {
    name = "azure-slow"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "qualytics"
    }
  }

  storage_provisioner    = "disk.csi.azure.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    skuName = "StandardSSD_LRS"
  }

  depends_on = [azurerm_kubernetes_cluster.qualytics]
}
