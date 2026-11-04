################################################################################
# Qualytics Azure Database for PostgreSQL Terraform Configuration
#
# Creates an Azure Database for PostgreSQL Flexible Server reachable only
# through a delegated subnet in the same virtual network as your AKS cluster.
# The subscription, resource group, virtual network and zone are read
# automatically from the cluster state — run terraform/azure/cluster first,
# then run this directory.
#
# Prerequisites:
#   cd terraform/azure/cluster && terraform apply    (creates AKS cluster + VNet)
#   cd terraform/azure/postgres && terraform apply   (this file)
################################################################################

terraform {
  # Write-only arguments (administrator_password_wo) require Terraform 1.11+.
  required_version = ">= 1.11.1"

  backend "azurerm" {
    key = "azure/postgres/terraform.tfstate"
    # storage account, container and its resource group are supplied at init time:
    # terraform init \
    #   -backend-config="resource_group_name=<tfstate-resource-group>" \
    #   -backend-config="storage_account_name=<tfstate-storage-account>" \
    #   -backend-config="container_name=tfstate"
  }

  required_providers {
    azurerm = {
      # 4.55 accepts PostgreSQL 18 on the Flexible Server (4.50 does not);
      # administrator_password_wo is available from earlier 4.x.
      source  = "hashicorp/azurerm"
      version = "~> 4.55"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  # Defaults kept deliberately: on destroy the Key Vault and its secret are
  # purged rather than left soft-deleted, so redeploying does not collide.
  features {}

  subscription_id = local.subscription_id
}

################################################################################
# Remote State — reads the subscription, resource group, VNet and zone from
# the cluster apply
################################################################################

data "terraform_remote_state" "cluster" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.tfstate_resource_group_name
    storage_account_name = var.tfstate_storage_account_name
    container_name       = var.tfstate_container_name
    key                  = var.tfstate_key
  }
}

data "azurerm_client_config" "current" {}

################################################################################
# Local Variables
################################################################################

locals {
  name    = var.cluster_name
  cluster = data.terraform_remote_state.cluster.outputs

  subscription_id     = local.cluster.subscription_id
  resource_group_name = local.cluster.resource_group_name
  location            = local.cluster.resource_group_location
  vnet_id             = local.cluster.vnet_id
  vnet_name           = local.cluster.vnet_name
  vnet_address_space  = local.cluster.vnet_address_space

  # Server names become public DNS labels (<name>.postgres.database.azure.com)
  # and Key Vault names are global too, so both carry a random suffix unless
  # set explicitly. Key Vault names are 3-24 alphanumerics/hyphens.
  server_name    = coalesce(var.server_name, "${local.name}-pg-${random_string.suffix.result}")
  key_vault_name = coalesce(var.key_vault_name, "${substr(replace(local.name, "/[^a-zA-Z0-9]/", ""), 0, 16)}pg${random_string.suffix.result}")

  tags = merge(var.default_tags, {
    Cluster = local.name
  })
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

################################################################################
# Networking
# The server gets a private IP in a subnet delegated to Flexible Server, and
# its name resolves through a private DNS zone linked to the cluster VNet.
# There is no public endpoint.
################################################################################

resource "azurerm_subnet" "postgres" {
  name                 = "${local.name}-postgres-subnet"
  resource_group_name  = local.resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = [var.postgres_subnet_cidr]

  delegation {
    name = "postgresql-flexible-server"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_network_security_group" "postgres" {
  name                = "${local.name}-postgres-nsg"
  location            = local.location
  resource_group_name = local.resource_group_name

  security_rule {
    name                       = "AllowPostgreSQLFromVNet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefixes    = local.vnet_address_space
    destination_address_prefix = "*"
  }

  tags = local.tags
}

resource "azurerm_subnet_network_security_group_association" "postgres" {
  subnet_id                 = azurerm_subnet.postgres.id
  network_security_group_id = azurerm_network_security_group.postgres.id
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${local.name}.private.postgres.database.azure.com"
  resource_group_name = local.resource_group_name

  tags = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${local.name}-postgres-dns-link"
  resource_group_name   = local.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = local.vnet_id

  tags = local.tags
}

################################################################################
# Database Password
# Stored in Key Vault
################################################################################

resource "random_password" "master" {
  length  = 32
  special = false

  # administrator_password_wo below is a write-only argument: Azure only
  # receives a new value when administrator_password_wo_version changes. Keying
  # the generated password to the same variable keeps the two in lockstep, so
  # one apply both regenerates the password and triggers the send. Without this
  # keeper, bumping the version re-sends the identical password and "rotation"
  # is a no-op.
  #
  # The keeper is also what makes rotation opt-in: while password_wo_version
  # stays at its default, this value is stable in state and routine
  # `terraform apply` runs never change the password.
  #
  # Corollary: do not force-replace this resource on its own (`-replace`,
  # `taint`). That regenerates the password in state and Key Vault while the
  # unchanged password_wo_version means the server never receives it — a
  # silent lockout. Bump password_wo_version instead.
  keepers = {
    version = tostring(var.password_wo_version)
  }
}

resource "azurerm_key_vault" "postgres" {
  name                = local.key_vault_name
  location            = local.location
  resource_group_name = local.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  # Access policies rather than Azure RBAC: they take effect immediately (RBAC
  # role assignments can take minutes to propagate, failing the secret write on
  # first apply) and need no Microsoft.Authorization/roleAssignments/write
  # permission. Inline blocks are kept until the vault itself is deleted, so a
  # destroy never revokes Terraform's access before the secret is removed.
  rbac_authorization_enabled = false

  dynamic "access_policy" {
    for_each = toset(concat([data.azurerm_client_config.current.object_id], var.key_vault_admin_object_ids))

    content {
      tenant_id          = data.azurerm_client_config.current.tenant_id
      object_id          = access_policy.value
      secret_permissions = ["Get", "List", "Set", "Delete", "Recover", "Purge"]
    }
  }

  tags = local.tags
}

resource "azurerm_key_vault_secret" "master" {
  name         = "${local.name}-postgres-password"
  key_vault_id = azurerm_key_vault.postgres.id
  content_type = "application/json"

  # Stores a structured JSON object so a single secret holds all connection fields.
  value = jsonencode({
    username = var.administrator_login
    password = random_password.master.result
    host     = azurerm_postgresql_flexible_server.this.fqdn
    port     = 5432
    dbname   = var.database_name
  })

  tags = local.tags
}

################################################################################
# Flexible Server
################################################################################

resource "azurerm_postgresql_flexible_server" "this" {
  name                = local.server_name
  resource_group_name = local.resource_group_name
  location            = local.location
  version             = var.postgresql_version

  sku_name          = var.sku_name
  storage_mb        = var.storage_mb
  storage_tier      = var.storage_tier
  auto_grow_enabled = var.auto_grow_enabled

  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  # Same zone as the AKS node pools, so the primary is not a cross-zone hop
  # away from the application.
  zone = local.cluster.node_group_az

  # The password is self-managed via random_password, and NOTHING rotates it
  # automatically. Rotation only happens when an operator explicitly increments
  # password_wo_version (default 1) and re-applies — see ./README.md.
  administrator_login               = var.administrator_login
  administrator_password_wo         = random_password.master.result
  administrator_password_wo_version = var.password_wo_version

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  # ZoneRedundant keeps a standby in another zone with automatic failover;
  # SameZone keeps it in the primary's zone. Azure picks the standby zone.
  dynamic "high_availability" {
    for_each = var.high_availability_mode == "Disabled" ? [] : [var.high_availability_mode]

    content {
      mode = high_availability.value
    }
  }

  maintenance_window {
    day_of_week  = var.maintenance_window.day_of_week
    start_hour   = var.maintenance_window.start_hour
    start_minute = var.maintenance_window.start_minute
  }

  tags = local.tags

  lifecycle {
    # After an HA failover Azure swaps the primary and standby zones; without
    # this the next apply would try to move them back.
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.postgres,
    azurerm_private_dns_zone_virtual_network_link.postgres,
  ]
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_connections" {
  name      = "log_connections"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_checkpoints" {
  name      = "log_checkpoints"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

################################################################################
# Deletion Protection
# The Flexible Server has no deletion_protection argument, and an Azure
# CanNotDelete lock would not help: Terraform deletes the lock first because it
# depends on the server. Instead this guard depends on every resource above, so
# Terraform always destroys it first — on `terraform destroy` and on any change
# that would replace the server — and its destroy step fails while protection
# is on, stopping the run before anything else is deleted.
#
# It reads the value stored at the last apply, so turning protection off means
# applying deletion_protection = false before destroying (see ./README.md).
################################################################################

resource "terraform_data" "deletion_protection" {
  input            = var.deletion_protection
  triggers_replace = azurerm_postgresql_flexible_server.this.id

  provisioner "local-exec" {
    when    = destroy
    command = self.input ? "echo deletion_protection is true - apply with deletion_protection=false before destroying or replacing the server && exit 1" : "echo deletion_protection is false"
  }

  depends_on = [
    azurerm_postgresql_flexible_server.this,
    azurerm_postgresql_flexible_server_database.this,
    azurerm_postgresql_flexible_server_configuration.log_connections,
    azurerm_postgresql_flexible_server_configuration.log_checkpoints,
    azurerm_key_vault.postgres,
    azurerm_key_vault_secret.master,
    azurerm_subnet.postgres,
    azurerm_subnet_network_security_group_association.postgres,
    azurerm_network_security_group.postgres,
    azurerm_private_dns_zone.postgres,
    azurerm_private_dns_zone_virtual_network_link.postgres,
  ]
}
