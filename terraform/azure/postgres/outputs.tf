################################################################################
# Qualytics Azure Database for PostgreSQL Outputs
################################################################################

#-------------------------------------------------------------------------------
# Connection Details
# These are the values you need to configure Qualytics via Helm.
# See helm_values below for a ready-to-paste block.
#-------------------------------------------------------------------------------

output "db_host" {
  description = "Private FQDN of the Flexible Server — use as secrets.postgres.host in values.yaml"
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "db_port" {
  description = "PostgreSQL port"
  value       = 5432
}

output "db_name" {
  description = "Database name — use as secrets.postgres.database in values.yaml"
  value       = azurerm_postgresql_flexible_server_database.this.name
}

output "db_username" {
  description = "Administrator username — use as secrets.postgres.username in values.yaml"
  value       = var.administrator_login
  sensitive   = true
}

output "db_password" {
  description = "Administrator password — also stored in Key Vault at key_vault_secret_id"
  value       = random_password.master.result
  sensitive   = true
}

#-------------------------------------------------------------------------------
# Secret Store Reference
#-------------------------------------------------------------------------------

output "key_vault_name" {
  description = "Key Vault holding the database credentials"
  value       = azurerm_key_vault.postgres.name
}

output "key_vault_secret_name" {
  description = "Key Vault secret storing the full database credentials (username, password, host, port, dbname)"
  value       = azurerm_key_vault_secret.master.name
}

output "key_vault_secret_id" {
  description = "Versionless ID of the Key Vault secret"
  value       = azurerm_key_vault_secret.master.versionless_id
}

#-------------------------------------------------------------------------------
# Infrastructure Details
#-------------------------------------------------------------------------------

output "server_name" {
  description = "The Flexible Server name"
  value       = azurerm_postgresql_flexible_server.this.name
}

output "server_id" {
  description = "The Flexible Server resource ID"
  value       = azurerm_postgresql_flexible_server.this.id
}

output "postgres_subnet_id" {
  description = "Subnet delegated to the Flexible Server"
  value       = azurerm_subnet.postgres.id
}

output "private_dns_zone_name" {
  description = "Private DNS zone resolving the server FQDN inside the VNet"
  value       = azurerm_private_dns_zone.postgres.name
}

#-------------------------------------------------------------------------------
# Next Steps
#-------------------------------------------------------------------------------

output "helm_values" {
  description = "Paste this block into your values.yaml to connect Qualytics to Azure Database for PostgreSQL. The password is also stored in Key Vault — see key_vault_secret_id."
  sensitive   = true
  value       = <<-EOT

    ============================================================
    Azure Database for PostgreSQL Successfully Created!
    ============================================================

    Add the following to your values.yaml, then run helm upgrade:

    postgres:
      enabled: false  # use Azure Database for PostgreSQL instead of the in-cluster PostgreSQL

    secrets:
      postgres:
        host: "${azurerm_postgresql_flexible_server.this.fqdn}"
        port: 5432
        database: "${azurerm_postgresql_flexible_server_database.this.name}"
        username: "${var.administrator_login}"
        password: "${random_password.master.result}"

    ============================================================
    The password above is also stored in Key Vault:
    ${azurerm_key_vault.postgres.name} / ${azurerm_key_vault_secret.master.name}
    ============================================================

  EOT
}
