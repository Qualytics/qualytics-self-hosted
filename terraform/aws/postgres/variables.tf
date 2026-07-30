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

variable "tfstate_key" {
  description = "S3 key of the cluster module's state file, read to discover the VPC and subnet IDs. Change this only if you passed a matching -backend-config=\"key=...\" when initialising terraform/aws/cluster."
  type        = string
  default     = "aws/cluster/terraform.tfstate"
}

variable "tfstate_region" {
  description = "Region of the S3 state bucket, when it differs from aws_region. Leave null to use aws_region."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Name prefix for all Aurora resources — must match the cluster_name used in terraform/aws/cluster"
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
  description = <<-EOT
    Aurora PostgreSQL engine version.
    Aurora enables automatic minor version upgrades by default, so after AWS applies
    one a later `terraform plan` may propose an engine_version *downgrade* back to
    this pinned value. RDS rejects downgrades — update this variable to match the
    running version instead of applying the diff:
      aws rds describe-db-clusters --query 'DBClusters[].EngineVersion'
  EOT
  type        = string
  default     = "17.9"
}

#-------------------------------------------------------------------------------
# Instance Configuration
#-------------------------------------------------------------------------------

variable "instance_class" {
  description = <<-EOT
    Aurora instance class.
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
  description = <<-EOT
    Rotation counter for the master password. Leave at the default and the password
    is NEVER rotated: no scheduled or automatic rotation is configured anywhere in
    this module, and routine `terraform apply` runs leave the password untouched.

    Increment it only when you intend to rotate. It is a keeper on
    random_password.master, so incrementing regenerates the password, sends it to
    Aurora, and updates the Secrets Manager entry in a single apply — after which you
    must copy the new value into your Helm values and upgrade the release, or the
    application can no longer authenticate.

    RDS applies a master password change immediately regardless of apply_immediately,
    so no maintenance window is involved. See ./README.md (Password rotation).
  EOT
  type        = number
  default     = 1
}

#-------------------------------------------------------------------------------
# Logging
#-------------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Aurora postgresql log group (0 = never expire)"
  type        = number
  default     = 30

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention period supported by CloudWatch Logs (0 = never expire)."
  }
}

variable "final_snapshot_identifier" {
  description = "Override the generated final snapshot name. Must be unique per account+region. Leave null to use <cluster_name>-postgres-final-<random>."
  type        = string
  default     = null
}

