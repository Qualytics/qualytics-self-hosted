################################################################################
# Qualytics AKS Variables
################################################################################

#-------------------------------------------------------------------------------
# General Configuration
#-------------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region for the AKS cluster"
  type        = string
  default     = "eastus"
}

variable "cluster_name" {
  description = "Name of the AKS cluster"
  type        = string
  default     = "qualytics"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the AKS cluster"
  type        = string
  default     = "1.33"
}

variable "default_tags" {
  description = "Default tags to apply to all resources"
  type        = map(string)
  default = {
    Terraform   = "true"
    Application = "qualytics"
  }
}

#-------------------------------------------------------------------------------
# Networking Configuration
#-------------------------------------------------------------------------------

variable "vnet_cidr" {
  description = "CIDR block for the Virtual Network"
  type        = string
  default     = "10.0.0.0/16"
}

variable "aks_subnet_cidr" {
  description = "CIDR block for the AKS subnet"
  type        = string
  default     = "10.0.0.0/20"
}

variable "service_cidr" {
  description = "CIDR block for Kubernetes services"
  type        = string
  default     = "10.1.0.0/16"
}

variable "dns_service_ip" {
  description = "IP address for the Kubernetes DNS service (must be within service_cidr)"
  type        = string
  default     = "10.1.0.10"
}

variable "api_server_authorized_ip_ranges" {
  description = "List of authorized IP ranges for API server access (empty for unrestricted)"
  type        = list(string)
  default     = []
}

#-------------------------------------------------------------------------------
# Cluster Configuration
#-------------------------------------------------------------------------------

variable "sku_tier" {
  description = "AKS SKU tier (Free or Standard). Standard recommended for production."
  type        = string
  default     = "Standard"
}

variable "node_group_az" {
  description = "Availability zone to pin node pools to (e.g. '1', '2', '3'). Prevents Azure Managed Disk zone mismatch when nodes are recycled into a different zone."
  type        = string
  default     = "1"
}

#-------------------------------------------------------------------------------
# Application Node Pool Configuration
#-------------------------------------------------------------------------------

variable "app_node_vm_size" {
  description = "VM size for application nodes (API, Frontend, databases)"
  type        = string
  default     = "Standard_D8s_v5"
}

variable "app_node_min_count" {
  description = "Minimum number of application nodes"
  type        = number
  default     = 1
}

variable "app_node_max_count" {
  description = "Maximum number of application nodes"
  type        = number
  default     = 3
}

variable "app_node_os_disk_size_gb" {
  description = "OS disk size in GB for application nodes"
  type        = number
  default     = 128
}

#-------------------------------------------------------------------------------
# Spark Driver Node Pool Configuration
#-------------------------------------------------------------------------------

variable "driver_node_vm_size" {
  description = "VM size for Spark driver nodes"
  type        = string
  default     = "Standard_E8s_v5"
}

variable "driver_node_min_count" {
  description = "Minimum number of driver nodes"
  type        = number
  default     = 0
}

variable "driver_node_max_count" {
  description = "Maximum number of driver nodes"
  type        = number
  default     = 1
}

variable "driver_node_os_disk_size_gb" {
  description = "OS disk size in GB for driver nodes"
  type        = number
  default     = 128
}

#-------------------------------------------------------------------------------
# Spark Executor Node Pool Configuration
#-------------------------------------------------------------------------------

variable "executor_node_vm_size" {
  description = "VM size for Spark executor nodes (use 'ds' suffix for local temp SSD storage)"
  type        = string
  default     = "Standard_E8ds_v5"
}

variable "executor_node_min_count" {
  description = "Minimum number of executor nodes"
  type        = number
  default     = 1
}

variable "executor_node_max_count" {
  description = "Maximum number of executor nodes"
  type        = number
  default     = 12
}

variable "executor_node_os_disk_size_gb" {
  description = "OS disk size in GB for executor nodes"
  type        = number
  default     = 128
}

variable "executor_use_spot" {
  description = "Use Spot instances for executor nodes (cost savings)"
  type        = bool
  default     = true
}

variable "executor_spot_max_price" {
  description = "Maximum price per hour for Spot executor nodes (-1 = on-demand price)"
  type        = number
  default     = -1
}

#-------------------------------------------------------------------------------
# Node Configuration Options
#-------------------------------------------------------------------------------

variable "enable_node_taints" {
  description = "Enable taints on node pools for dedicated workloads"
  type        = bool
  default     = true
}

#-------------------------------------------------------------------------------
# Optional Features
#-------------------------------------------------------------------------------

variable "create_qualytics_namespace" {
  description = "Create the qualytics namespace"
  type        = bool
  default     = true
}

variable "docker_registry_token" {
  description = "Docker registry token for pulling Qualytics images (provided by Qualytics)"
  type        = string
  default     = ""
  sensitive   = true
}
