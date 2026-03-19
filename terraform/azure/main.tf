################################################################################
# Qualytics AKS Cluster Terraform Configuration
#
# This template creates an AKS cluster with the recommended node pools for
# deploying Qualytics. Customize the variables in terraform.tfvars to match
# your requirements.
################################################################################

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.qualytics.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.qualytics.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.qualytics.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.qualytics.kube_config[0].cluster_ca_certificate)
}

################################################################################
# Local Variables
################################################################################

locals {
  name            = var.cluster_name
  cluster_version = var.kubernetes_version

  tags = merge(var.default_tags, {
    Cluster = local.name
  })
}

################################################################################
# Resource Group
################################################################################

resource "azurerm_resource_group" "qualytics" {
  name     = "${local.name}-rg"
  location = var.location

  tags = local.tags
}

################################################################################
# Virtual Network
################################################################################

resource "azurerm_virtual_network" "qualytics" {
  name                = "${local.name}-vnet"
  location            = azurerm_resource_group.qualytics.location
  resource_group_name = azurerm_resource_group.qualytics.name
  address_space       = [var.vnet_cidr]

  tags = local.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "${local.name}-aks-subnet"
  resource_group_name  = azurerm_resource_group.qualytics.name
  virtual_network_name = azurerm_virtual_network.qualytics.name
  address_prefixes     = [var.aks_subnet_cidr]
}

################################################################################
# AKS Cluster
################################################################################

resource "azurerm_kubernetes_cluster" "qualytics" {
  name                = local.name
  location            = azurerm_resource_group.qualytics.location
  resource_group_name = azurerm_resource_group.qualytics.name
  dns_prefix          = local.name
  kubernetes_version  = local.cluster_version

  # Default node pool (system)
  default_node_pool {
    name                 = "system"
    node_count           = 1
    vm_size              = "Standard_D2s_v5"
    vnet_subnet_id       = azurerm_subnet.aks.id
    os_disk_size_gb      = 50
    type                 = "VirtualMachineScaleSets"
    auto_scaling_enabled = false

    node_labels = {
      "nodepool-type" = "system"
    }

    tags = local.tags
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
    service_cidr      = var.service_cidr
    dns_service_ip    = var.dns_service_ip
  }

  sku_tier = var.sku_tier

  # Enable API server public access (can be restricted with authorized IP ranges)
  api_server_access_profile {
    authorized_ip_ranges = var.api_server_authorized_ip_ranges
  }

  tags = local.tags
}

################################################################################
# Application Node Pool
# For: API, Frontend, PostgreSQL, RabbitMQ, Spark Operator, Cert-Manager
# Pinned to a single zone to prevent Azure Managed Disk AZ mismatch:
# Managed Disks are zone-locked, so replacement nodes must come up in the same zone.
################################################################################

resource "azurerm_kubernetes_cluster_node_pool" "app" {
  name                  = "app"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.qualytics.id
  vm_size               = var.app_node_vm_size
  vnet_subnet_id        = azurerm_subnet.aks.id
  os_disk_size_gb       = var.app_node_os_disk_size_gb
  zones                 = [var.node_group_az]

  auto_scaling_enabled = true
  min_count            = var.app_node_min_count
  max_count            = var.app_node_max_count

  node_labels = {
    appNodes = "true"
  }

  node_taints = var.enable_node_taints ? ["appNodes=true:NoSchedule"] : []

  tags = local.tags
}

################################################################################
# Spark Driver Node Pool
# For: Spark driver process
################################################################################

resource "azurerm_kubernetes_cluster_node_pool" "driver" {
  name                  = "driver"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.qualytics.id
  vm_size               = var.driver_node_vm_size
  vnet_subnet_id        = azurerm_subnet.aks.id
  os_disk_size_gb       = var.driver_node_os_disk_size_gb
  zones                 = [var.node_group_az]

  auto_scaling_enabled = true
  min_count            = var.driver_node_min_count
  max_count            = var.driver_node_max_count

  node_labels = {
    driverNodes = "true"
  }

  node_taints = var.enable_node_taints ? ["driverNodes=true:NoSchedule"] : []

  tags = local.tags
}

################################################################################
# Spark Executor Node Pool
# For: Spark executor processes (data processing)
# Uses Spot instances for cost optimization when enabled
################################################################################

resource "azurerm_kubernetes_cluster_node_pool" "executor" {
  name                  = "executor"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.qualytics.id
  vm_size               = var.executor_node_vm_size
  vnet_subnet_id        = azurerm_subnet.aks.id
  os_disk_size_gb       = var.executor_node_os_disk_size_gb
  zones                 = [var.node_group_az]

  auto_scaling_enabled = true
  min_count            = var.executor_node_min_count
  max_count            = var.executor_node_max_count

  # Spot instances for cost savings
  priority        = var.executor_use_spot ? "Spot" : "Regular"
  eviction_policy = var.executor_use_spot ? "Delete" : null
  spot_max_price  = var.executor_use_spot ? var.executor_spot_max_price : null

  node_labels = {
    executorNodes = "true"
  }

  node_taints = var.enable_node_taints ? ["executorNodes=true:NoSchedule"] : []

  tags = local.tags
}

################################################################################
# Kubernetes Namespace and Docker Registry Secret
################################################################################

resource "kubernetes_namespace" "qualytics" {
  count = var.create_qualytics_namespace ? 1 : 0

  metadata {
    name = "qualytics"
  }

  depends_on = [azurerm_kubernetes_cluster.qualytics]
}

resource "kubernetes_secret" "docker_registry" {
  count = var.create_qualytics_namespace && var.docker_registry_token != "" ? 1 : 0

  metadata {
    name      = "regcred"
    namespace = kubernetes_namespace.qualytics[0].metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "https://index.docker.io/v1/" = {
          username = "qualyticsai"
          password = var.docker_registry_token
          auth     = base64encode("qualyticsai:${var.docker_registry_token}")
        }
      }
    })
  }

  depends_on = [kubernetes_namespace.qualytics]
}
