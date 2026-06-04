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
  default     = "1.35"
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

variable "cluster_endpoint_public_access_cidrs" {
  description = "List of CIDR blocks that can access the public EKS API server endpoint. Defaults to open (0.0.0.0/0). Restrict to your office or VPN CIDR for production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

#-------------------------------------------------------------------------------
# Application Node Configuration
#-------------------------------------------------------------------------------

variable "app_node_instance_types" {
  description = "Instance types for application nodes (API, Frontend, RabbitMQ). Karpenter selects from this list."
  type        = list(string)
  default     = ["m8g.2xlarge"]
}

#-------------------------------------------------------------------------------
# Spark Driver Node Configuration
#-------------------------------------------------------------------------------

variable "driver_node_instance_types" {
  description = "Instance types for Spark driver nodes. Karpenter selects from this list."
  type        = list(string)
  default     = ["r8g.2xlarge"]
}

#-------------------------------------------------------------------------------
# Spark Executor Node Configuration
#-------------------------------------------------------------------------------

variable "executor_node_instance_types" {
  description = "Instance types for Spark executor nodes. Use instances with local NVMe SSDs (e.g. r8gd, c7gd, m7gd families)."
  type        = list(string)
  default     = ["r8gd.2xlarge"]
}

variable "executor_capacity_type" {
  description = "Capacity type for executor nodes: 'on-demand' or 'spot'"
  type        = string
  default     = "spot"

  validation {
    condition     = contains(["on-demand", "spot"], var.executor_capacity_type)
    error_message = "executor_capacity_type must be 'on-demand' or 'spot'."
  }
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
# Optional Features
#-------------------------------------------------------------------------------

variable "create_qualytics_namespace" {
  description = "Create the qualytics namespace and Docker registry secret. Set to false only if managing the namespace outside Terraform."
  type        = bool
  default     = true
}

variable "docker_registry_token" {
  description = "Docker registry token for pulling Qualytics images (provided by Qualytics)"
  type        = string
  default     = ""
  sensitive   = true
}
