################################################################################
# Qualytics Aurora PostgreSQL Variables
################################################################################

#-------------------------------------------------------------------------------
# General Configuration
#-------------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region — must match the region used in terraform/aws/cluster"
  type        = string
  default     = "us-east-1"
}

variable "tfstate_bucket" {
  description = "S3 bucket name used as the Terraform state backend — must match the bucket used in terraform/aws/cluster"
  type        = string
}

variable "cluster_name" {
  description = "Name prefix for all Aurora resources — should match your EKS cluster_name in terraform/aws"
  type        = string
  default     = "qualytics"
}

variable "default_tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    Terraform   = "true"
    Application = "qualytics"
  }
}

#-------------------------------------------------------------------------------
# Database Configuration
#-------------------------------------------------------------------------------

variable "database_name" {
  description = "Name of the initial database created in Aurora"
  type        = string
  default     = "surveillance_hub"
}

variable "administrator_login" {
  description = "Master username for Aurora PostgreSQL"
  type        = string
  default     = "postgres"
}

variable "postgresql_version" {
  description = "Aurora PostgreSQL engine version"
  type        = string
  default     = "17.9"
}

#-------------------------------------------------------------------------------
# Instance Configuration
#-------------------------------------------------------------------------------

variable "instance_class" {
  description = <<-EOT
    Aurora instance class. See docs/cluster-sizing.md for sizing guidance.
    Recommendations:
      db.r8g.large   —  2 vCPU,  16 GB  (development / small production)
      db.r8g.xlarge  —  4 vCPU,  32 GB  (medium production)
      db.r8g.2xlarge —  8 vCPU,  64 GB  (large production)
    r8g = Graviton 4 (ARM) — best price/performance ratio on AWS.
    Use r7g or r6g if r8g is not available in your region.
  EOT
  type        = string
  default     = "db.r8g.large"
}

variable "instances" {
  description = <<-EOT
    Map of Aurora instance configurations. Each key is an instance number.
    Add a second entry for a read replica:
      instances = { 1 = {}, 2 = {} }
  EOT
  type        = map(any)
  default     = { 1 = {} }
}

#-------------------------------------------------------------------------------
# Backup and Maintenance
#-------------------------------------------------------------------------------

variable "backup_retention_period" {
  description = "Number of days to retain automated backups (1-35)"
  type        = number
  default     = 7
}

variable "preferred_backup_window" {
  description = "Daily time range for automated backups, UTC (format: hh24:mi-hh24:mi)"
  type        = string
  default     = "03:00-04:00"
}

variable "apply_immediately" {
  description = "Apply cluster changes immediately. false = apply during the next maintenance window. Set to true only for non-production environments."
  type        = bool
  default     = false
}

#-------------------------------------------------------------------------------
# Safety Controls
#-------------------------------------------------------------------------------

variable "deletion_protection" {
  description = "Prevent the Aurora cluster from being deleted via Terraform or the AWS Console. Recommended true for production."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot when destroying the cluster. Set to true only for non-production environments."
  type        = bool
  default     = false
}

variable "master_password_wo_version" {
  description = "Increment this integer to force a password rotation. Triggers random_password to generate a new value and updates Secrets Manager."
  type        = number
  default     = 1
}

