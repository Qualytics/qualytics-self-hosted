################################################################################
# Qualytics EKS Variables
################################################################################

#-------------------------------------------------------------------------------
# General Configuration
#-------------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for the EKS cluster"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "qualytics"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
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

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway for all AZs (cost savings for non-production)"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Enable public access to the EKS cluster endpoint"
  type        = bool
  default     = true
}

#-------------------------------------------------------------------------------
# Application Node Group Configuration
#-------------------------------------------------------------------------------

variable "app_node_instance_types" {
  description = "Instance types for application nodes (API, Frontend, databases)"
  type        = list(string)
  default     = ["m8g.2xlarge"]
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

variable "app_node_desired_size" {
  description = "Desired number of application nodes"
  type        = number
  default     = 1
}

#-------------------------------------------------------------------------------
# Spark Driver Node Group Configuration
#-------------------------------------------------------------------------------

variable "driver_node_instance_types" {
  description = "Instance types for Spark driver nodes"
  type        = list(string)
  default     = ["r8g.2xlarge"]
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

variable "driver_node_desired_size" {
  description = "Desired number of driver nodes"
  type        = number
  default     = 1
}

#-------------------------------------------------------------------------------
# Spark Executor Node Group Configuration
#-------------------------------------------------------------------------------

variable "executor_node_instance_types" {
  description = "Instance types for Spark executor nodes (should have local NVMe SSDs)"
  type        = list(string)
  default     = ["r8gd.2xlarge"]
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

variable "executor_node_desired_size" {
  description = "Desired number of executor nodes"
  type        = number
  default     = 1
}

variable "executor_capacity_type" {
  description = "Capacity type for executor nodes (ON_DEMAND or SPOT)"
  type        = string
  default     = "SPOT"
}

#-------------------------------------------------------------------------------
# Cluster Authentication
#-------------------------------------------------------------------------------

variable "cluster_admin_arns" {
  description = "List of IAM principal ARNs (roles or users) to grant cluster admin access"
  type        = list(string)
  default     = []
}

#-------------------------------------------------------------------------------
# Node Configuration Options
#-------------------------------------------------------------------------------

variable "enable_nvme_setup" {
  description = "Enable NVMe instance store setup for executor nodes"
  type        = bool
  default     = true
}

#-------------------------------------------------------------------------------
# Optional Features
#-------------------------------------------------------------------------------

variable "enable_cluster_autoscaler" {
  description = "Enable Cluster Autoscaler IAM role"
  type        = bool
  default     = true
}

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
