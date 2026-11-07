################################################################################
# Qualytics Azure Database for PostgreSQL Variables
################################################################################

#-------------------------------------------------------------------------------
# General Configuration
#-------------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name prefix for all PostgreSQL resources — must match the cluster_name used in terraform/azure/cluster"
  type        = string
  default     = "qualytics"
}

variable "tfstate_resource_group_name" {
  description = "Resource group of the storage account used as the Terraform state backend — must match the one used in terraform/azure/cluster"
  type        = string
}

variable "tfstate_storage_account_name" {
  description = "Storage account used as the Terraform state backend — must match the one used in terraform/azure/cluster"
  type        = string
}

variable "tfstate_container_name" {
  description = "Blob container holding the Terraform state — must match the one used in terraform/azure/cluster"
  type        = string
  default     = "tfstate"
}

variable "tfstate_key" {
  description = "Blob name of the cluster module's state, read to discover the subscription, resource group, VNet and zone. Change this only if you passed a matching -backend-config=\"key=...\" when initialising terraform/azure/cluster."
  type        = string
  default     = "azure/cluster/terraform.tfstate"
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
# Naming
#-------------------------------------------------------------------------------

variable "server_name" {
  description = "Optional explicit Flexible Server name (3-63 lowercase letters, digits and hyphens). It becomes a public DNS label, so it must be unique across Azure. Leave null for <cluster_name>-pg-<random suffix>."
  type        = string
  default     = null

  validation {
    condition     = var.server_name == null || can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.server_name))
    error_message = "server_name must be 3-63 characters of lowercase letters, digits and hyphens, and must not start or end with a hyphen."
  }
}

variable "key_vault_name" {
  description = "Optional explicit Key Vault name (3-24 letters, digits and hyphens, starting with a letter). Key Vault names are unique across Azure. Leave null for a name derived from cluster_name plus a random suffix."
  type        = string
  default     = null

  validation {
    condition     = var.key_vault_name == null || can(regex("^[a-zA-Z](-?[a-zA-Z0-9])+$", var.key_vault_name)) && length(coalesce(var.key_vault_name, "x")) >= 3 && length(coalesce(var.key_vault_name, "x")) <= 24
    error_message = "key_vault_name must be 3-24 letters, digits and hyphens, start with a letter, not end with a hyphen, and contain no consecutive hyphens."
  }
}

variable "key_vault_admin_object_ids" {
  description = "Additional Entra ID object IDs (users, groups, service principals) granted secret access on the Key Vault. The identity running Terraform is always granted; add any other identity that will run this module later (e.g. a CI service principal)."
  type        = list(string)
  default     = []
}

#-------------------------------------------------------------------------------
# Database Configuration
#-------------------------------------------------------------------------------

variable "database_name" {
  description = "Database Qualytics connects to (secrets.postgres.database in values.yaml)"
  type        = string
  default     = "surveillance_hub"
}

variable "administrator_login" {
  description = "Administrator username"
  type        = string
  default     = "postgres"

  validation {
    condition     = !contains(["azure_superuser", "azure_pg_admin", "admin", "administrator", "root", "guest", "public"], var.administrator_login) && !startswith(var.administrator_login, "pg_")
    error_message = "administrator_login cannot be azure_superuser, azure_pg_admin, admin, administrator, root, guest, public, or start with pg_."
  }
}

variable "postgresql_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "17"

  validation {
    condition     = contains(["14", "15", "16", "17", "18"], var.postgresql_version)
    error_message = "postgresql_version must be a PostgreSQL major version supported by Azure Database for PostgreSQL Flexible Server (14-18)."
  }
}

#-------------------------------------------------------------------------------
# Compute & Storage
#-------------------------------------------------------------------------------

variable "sku_name" {
  description = <<-EOT
    Flexible Server SKU (<tier>_<vm size>). Recommendations:
      GP_Standard_D2ds_v5  —  2 vCPU,  8 GB  (development / small production)
      GP_Standard_D4ds_v5  —  4 vCPU, 16 GB  (medium production)
      GP_Standard_D8ds_v5  —  8 vCPU, 32 GB  (large production)
    Memory-optimized (MO_Standard_E*ds_v5) doubles memory per vCPU.
    Burstable (B_*) SKUs do not support high availability.
  EOT
  type        = string
  default     = "GP_Standard_D2ds_v5"

  validation {
    condition     = can(regex("^(B|GP|MO)_", var.sku_name))
    error_message = "sku_name must start with B_, GP_ or MO_ (e.g. GP_Standard_D2ds_v5)."
  }
}

variable "storage_mb" {
  description = "Storage size in MB (32768 = 32 GB). Storage can grow but never shrink."
  type        = number
  default     = 32768
}

variable "storage_tier" {
  description = "Optional performance tier for the storage (P4-P80). Leave null for the default tier of storage_mb."
  type        = string
  default     = null
}

variable "auto_grow_enabled" {
  description = "Grow storage automatically before it fills up"
  type        = bool
  default     = true
}

variable "high_availability_mode" {
  description = "ZoneRedundant keeps a standby in another zone with automatic failover (recommended for production, roughly doubles compute cost). SameZone keeps the standby in the primary's zone. Disabled runs a single server with no HA."
  type        = string
  default     = "ZoneRedundant"

  validation {
    condition     = contains(["ZoneRedundant", "SameZone", "Disabled"], var.high_availability_mode)
    error_message = "high_availability_mode must be ZoneRedundant, SameZone or Disabled."
  }

  validation {
    condition     = var.high_availability_mode == "Disabled" || !startswith(var.sku_name, "B_")
    error_message = "Burstable (B_*) SKUs do not support high availability: set high_availability_mode = \"Disabled\" or use a GP_ / MO_ SKU."
  }
}

#-------------------------------------------------------------------------------
# Networking
#-------------------------------------------------------------------------------

variable "postgres_subnet_cidr" {
  description = "CIDR of the subnet delegated to the Flexible Server. Must be inside the cluster VNet (vnet_cidr in terraform/azure/cluster) and not overlap the AKS subnet. The default sits right after the default AKS subnet (10.0.0.0/20)."
  type        = string
  default     = "10.0.16.0/24"

  validation {
    condition     = can(cidrhost(var.postgres_subnet_cidr, 0)) && try(tonumber(split("/", var.postgres_subnet_cidr)[1]) <= 28, false)
    error_message = "postgres_subnet_cidr must be a valid CIDR no smaller than /28."
  }
}

#-------------------------------------------------------------------------------
# Backup & Maintenance
#-------------------------------------------------------------------------------

variable "backup_retention_days" {
  description = "Point-in-time-restore backup retention in days (7-35)"
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 7 and 35."
  }
}

variable "geo_redundant_backup_enabled" {
  description = "Store backups in the paired region as well. Can only be set when the server is created."
  type        = bool
  default     = false
}

variable "maintenance_window" {
  description = "Preferred maintenance window (UTC). day_of_week: 0 = Sunday ... 6 = Saturday."
  type = object({
    day_of_week  = number
    start_hour   = number
    start_minute = number
  })
  default = {
    day_of_week  = 0
    start_hour   = 3
    start_minute = 0
  }
}

#-------------------------------------------------------------------------------
# Safety Controls
#-------------------------------------------------------------------------------

variable "deletion_protection" {
  description = "Stop Terraform from deleting or replacing the server. Terraform-side only (Flexible Server has no server-side equivalent) and read from state, so tearing down means applying this as false before destroying. Recommended true for production."
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
    the server, and updates the Key Vault secret in a single apply — after which
    you must copy the new value into your Helm values and upgrade the release, or
    the application can no longer authenticate. See ./README.md (Password rotation).
  EOT
  type        = number
  default     = 1
}
