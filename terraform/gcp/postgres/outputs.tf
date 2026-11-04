################################################################################
# Qualytics AlloyDB for PostgreSQL Outputs
################################################################################

#-------------------------------------------------------------------------------
# Connection Details
# These are the values you need to configure Qualytics via Helm.
# See helm_values below for a ready-to-paste block.
#-------------------------------------------------------------------------------

output "db_host" {
  description = "Private IP of the AlloyDB primary instance — use as secrets.postgres.host in values.yaml"
  value       = google_alloydb_instance.primary.ip_address
}

output "db_port" {
  description = "PostgreSQL port"
  value       = 5432
}

output "db_name" {
  description = "Database name — use as secrets.postgres.database in values.yaml"
  value       = var.database_name
}

output "db_username" {
  description = "Administrator username — use as secrets.postgres.username in values.yaml"
  value       = var.administrator_login
  sensitive   = true
}

output "db_password" {
  description = "Administrator password — also stored in Secret Manager at db_secret_id"
  value       = random_password.master.result
  sensitive   = true
}

#-------------------------------------------------------------------------------
# Secret Store Reference
#-------------------------------------------------------------------------------

output "db_secret_id" {
  description = "Secret Manager secret storing the full database credentials (username, password, host, port, dbname)"
  value       = google_secret_manager_secret.master.id
}

#-------------------------------------------------------------------------------
# Infrastructure Details
#-------------------------------------------------------------------------------

output "alloydb_cluster_id" {
  description = "The AlloyDB cluster ID"
  value       = google_alloydb_cluster.this.cluster_id
}

output "alloydb_cluster_name" {
  description = "The AlloyDB cluster resource name (projects/<project>/locations/<region>/clusters/<id>)"
  value       = google_alloydb_cluster.this.name
}

output "alloydb_primary_instance_name" {
  description = "The AlloyDB primary instance resource name"
  value       = google_alloydb_instance.primary.name
}

output "psa_range" {
  description = "Internal range reserved on the VPC for private services access"
  value       = "${google_compute_global_address.alloydb.address}/${google_compute_global_address.alloydb.prefix_length}"
}

#-------------------------------------------------------------------------------
# Next Steps
#-------------------------------------------------------------------------------

output "helm_values" {
  description = "Paste this block into your values.yaml to connect Qualytics to AlloyDB. The password is also stored in Secret Manager — see db_secret_id."
  sensitive   = true
  value       = <<-EOT

    ============================================================
    AlloyDB for PostgreSQL Successfully Created!
    ============================================================

    Add the following to your values.yaml, then run helm upgrade:

    postgres:
      enabled: false  # use AlloyDB instead of the in-cluster PostgreSQL

    secrets:
      postgres:
        host: "${google_alloydb_instance.primary.ip_address}"
        port: 5432
        database: "${var.database_name}"
        username: "${var.administrator_login}"
        password: "${random_password.master.result}"

    ============================================================
    The password above is also stored in Secret Manager:
    ${google_secret_manager_secret.master.id}
    ============================================================

  EOT
}
