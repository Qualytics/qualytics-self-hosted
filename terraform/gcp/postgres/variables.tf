################################################################################
# Qualytics AlloyDB for PostgreSQL Variables
################################################################################

#-------------------------------------------------------------------------------
# General Configuration
#-------------------------------------------------------------------------------

variable "region" {
  description = "GCP region — must match the region used in terraform/gcp/cluster"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "Name prefix for all AlloyDB resources — must match the cluster_name used in terraform/gcp/cluster"
  type        = string
  default     = "qualytics"
}

variable "tfstate_bucket" {
  description = "GCS bucket used as the Terraform state backend — must match the bucket used in terraform/gcp/cluster"
  type        = string
}

variable "tfstate_prefix" {
  description = "GCS prefix of the cluster module's state, read to discover the project and VPC network. Change this only if you passed a matching -backend-config=\"prefix=...\" when initialising terraform/gcp/cluster."
  type        = string
  default     = "gcp/cluster"
}

variable "default_labels" {
  description = "Labels applied to all resources"
  type        = map(string)
  default = {
    terraform   = "true"
    application = "qualytics"
  }
}

#-------------------------------------------------------------------------------
# Database Configuration
#-------------------------------------------------------------------------------

variable "database_name" {
  description = "Database name Qualytics connects to (secrets.postgres.database in values.yaml)"
  type        = string
  default     = "surveillance_hub"
}

variable "administrator_login" {
  description = "Username of the AlloyDB initial (administrator) user"
  type        = string
  default     = "postgres"
}

variable "postgresql_version" {
  description = "PostgreSQL major version for AlloyDB (rendered as POSTGRES_<version>)"
  type        = string
  default     = "17"

  validation {
    condition     = contains(["14", "15", "16", "17", "18"], var.postgresql_version)
    error_message = "postgresql_version must be a PostgreSQL major version supported by AlloyDB (14-18)."
  }
}

#-------------------------------------------------------------------------------
# Instance Configuration
#-------------------------------------------------------------------------------

variable "cpu_count" {
  description = <<-EOT
    vCPUs for the primary instance. Memory is fixed at 8 GB per vCPU.
    Recommendations:
      2  —  16 GB  (development / small production)
      4  —  32 GB  (medium production)
      8  —  64 GB  (large production)
  EOT
  type        = number
  default     = 2
}

variable "machine_type" {
  description = "Optional explicit machine type for the primary instance (e.g. n2-highmem-4, c4a-highmem-4-lssd). Its vCPU count must equal cpu_count. Leave null to let AlloyDB pick the default N2 shape for cpu_count."
  type        = string
  default     = null
}

variable "availability_type" {
  description = "REGIONAL keeps a standby in a second zone with automatic failover (recommended for production, roughly doubles instance cost). ZONAL is a single node with no HA."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "ZONAL"], var.availability_type)
    error_message = "availability_type must be REGIONAL or ZONAL."
  }
}

#-------------------------------------------------------------------------------
# Private Services Access
#-------------------------------------------------------------------------------

variable "psa_prefix_length" {
  description = "Prefix length of the internal range reserved on the VPC for AlloyDB (private services access). /16 leaves room for other Google-managed services; AlloyDB itself needs at least a /24."
  type        = number
  default     = 16

  validation {
    condition     = var.psa_prefix_length >= 8 && var.psa_prefix_length <= 24
    error_message = "psa_prefix_length must be between 8 and 24."
  }
}

variable "psa_address" {
  description = "Optional first address of the private services access range (e.g. \"10.20.0.0\"). Set it to keep the range clear of networks you peer with or reach over VPN. Leave null to let Google pick an unused range."
  type        = string
  default     = null
}

#-------------------------------------------------------------------------------
# Backup
#-------------------------------------------------------------------------------

variable "backup_retention_count" {
  description = "Number of daily automated backups to retain"
  type        = number
  default     = 7
}

variable "backup_start_hour" {
  description = "Hour of the day (0-23, UTC) at which the daily automated backup starts"
  type        = number
  default     = 3

  validation {
    condition     = var.backup_start_hour >= 0 && var.backup_start_hour <= 23 && floor(var.backup_start_hour) == var.backup_start_hour
    error_message = "backup_start_hour must be an integer between 0 and 23."
  }
}

#-------------------------------------------------------------------------------
# Safety Controls
#-------------------------------------------------------------------------------

variable "deletion_protection" {
  description = "Prevent Terraform from deleting the AlloyDB cluster. Terraform-side only (GCP has no server-side equivalent) and read from state, so tearing down means applying this as false before destroying. Recommended true for production."
  type        = bool
  default     = true
}

variable "password_wo_version" {
  description = <<-EOT
    Rotation counter for the administrator password. Leave at the default and the
    password is NEVER rotated: no scheduled or automatic rotation is configured
    anywhere in this module, and routine `terraform apply` runs leave the password
    untouched.

    Increment it only when you intend to rotate. It is a keeper on
    random_password.master, so incrementing regenerates the password, sends it to
    AlloyDB, and updates the Secret Manager entry in a single apply — after which
    you must copy the new value into your Helm values and upgrade the release, or
    the application can no longer authenticate. See ./README.md (Password rotation).
  EOT
  type        = number
  default     = 1
}
