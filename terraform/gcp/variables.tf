################################################################################
# Qualytics GKE Variables
################################################################################

#-------------------------------------------------------------------------------
# General Configuration
#-------------------------------------------------------------------------------

variable "tenant_name" {
  description = "Tenant name used for project naming"
  type        = string
}

variable "project_id" {
  description = "GCP project ID where resources will be created (auto-generated if not provided)"
  type        = string
  default     = ""
}

variable "billing_account" {
  description = "GCP billing account ID for project creation"
  type        = string
}

variable "folder_id" {
  description = "GCP folder ID for project creation"
  type        = string
}

variable "region" {
  description = "GCP region for the GKE cluster"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "qualytics"
}

variable "default_labels" {
  description = "Default labels to apply to all resources"
  type        = map(string)
  default = {
    terraform   = "true"
    application = "qualytics"
  }
}

variable "deletion_protection" {
  description = "Enable deletion protection for the cluster"
  type        = bool
  default     = true
}

#-------------------------------------------------------------------------------
# Networking Configuration
#-------------------------------------------------------------------------------

variable "subnet_cidr" {
  description = "CIDR block for the GKE nodes subnet"
  type        = string
  default     = "10.10.0.0/16"
}

variable "pods_cidr" {
  description = "Secondary CIDR block for GKE pods"
  type        = string
  default     = "10.11.0.0/16"
}

variable "services_cidr" {
  description = "Secondary CIDR block for GKE services"
  type        = string
  default     = "10.12.0.0/16"
}

variable "master_authorized_networks" {
  description = "List of CIDR blocks authorized to access the GKE master endpoint"
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [
    {
      cidr_block   = "0.0.0.0/0"
      display_name = "Public Access"
    }
  ]
}

#-------------------------------------------------------------------------------
# Application Node Pool Configuration
#-------------------------------------------------------------------------------

variable "app_node_machine_type" {
  description = "Machine type for application nodes (API, Frontend, databases)"
  type        = string
  default     = "n4-standard-8"
}

variable "app_node_min_size" {
  description = "Minimum number of application nodes"
  type        = number
  default     = 1
}

variable "app_node_max_size" {
  description = "Maximum number of application nodes"
  type        = number
  default     = 3
}

#-------------------------------------------------------------------------------
# Spark Driver Node Pool Configuration
#-------------------------------------------------------------------------------

variable "driver_node_machine_type" {
  description = "Machine type for Spark driver nodes"
  type        = string
  default     = "n4-highmem-8"
}

variable "driver_node_min_size" {
  description = "Minimum number of driver nodes"
  type        = number
  default     = 0
}

variable "driver_node_max_size" {
  description = "Maximum number of driver nodes"
  type        = number
  default     = 1
}

#-------------------------------------------------------------------------------
# Spark Executor Node Pool Configuration
#-------------------------------------------------------------------------------

variable "executor_node_machine_type" {
  description = "Machine type for Spark executor nodes (use N2 series for local SSD support)"
  type        = string
  default     = "n2-highmem-8"
}

variable "executor_node_min_size" {
  description = "Minimum number of executor nodes"
  type        = number
  default     = 1
}

variable "executor_node_max_size" {
  description = "Maximum number of executor nodes"
  type        = number
  default     = 12
}

variable "executor_use_spot" {
  description = "Use spot instances for executor nodes (cost savings)"
  type        = bool
  default     = true
}

variable "executor_local_ssd_count" {
  description = "Number of local SSDs to attach to executor nodes (375GB each). Set to 0 to disable."
  type        = number
  default     = 2
}

#-------------------------------------------------------------------------------
# Node Configuration Options
#-------------------------------------------------------------------------------

variable "enable_node_taints" {
  description = "Enable taints on node groups for dedicated workloads"
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
