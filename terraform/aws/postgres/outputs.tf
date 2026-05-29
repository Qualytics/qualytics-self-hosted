################################################################################
# Qualytics Aurora PostgreSQL Outputs
################################################################################

#-------------------------------------------------------------------------------
# Connection Details
# These are the values you need to configure Qualytics via Helm.
# See helm_values below for a ready-to-paste block.
#-------------------------------------------------------------------------------

output "db_host" {
  description = "Aurora cluster writer endpoint — use as secrets.postgres.host in values.yaml"
  value       = module.aurora.cluster_endpoint
}

output "db_reader_endpoint" {
  description = "Aurora cluster reader endpoint — for read-only connections (not used by Qualytics directly)"
  value       = module.aurora.cluster_reader_endpoint
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
  description = "Master username — use as secrets.postgres.username in values.yaml"
  value       = var.administrator_login
  sensitive   = true
}

output "db_password" {
  description = "Master password — also stored in Secrets Manager at db_secret_arn"
  value       = random_password.master.result
  sensitive   = true
}

#-------------------------------------------------------------------------------
# Secret Store Reference
#-------------------------------------------------------------------------------

output "db_secret_arn" {
  description = "AWS Secrets Manager ARN storing the full database credentials (username, password, host, port, dbname)"
  value       = aws_secretsmanager_secret.master.arn
}

#-------------------------------------------------------------------------------
# Infrastructure Details
#-------------------------------------------------------------------------------

output "cluster_id" {
  description = "The Aurora cluster identifier"
  value       = module.aurora.cluster_id
}

output "cluster_arn" {
  description = "The Aurora cluster ARN"
  value       = module.aurora.cluster_arn
}

output "security_group_id" {
  description = "Security group ID attached to the Aurora cluster"
  value       = aws_security_group.aurora.id
}

#-------------------------------------------------------------------------------
# Next Steps
#-------------------------------------------------------------------------------

output "helm_values" {
  description = "Paste this block into your values.yaml to connect Qualytics to Aurora. The password is also stored in Secrets Manager — see db_secret_arn."
  sensitive   = true
  value       = <<-EOT

    ============================================================
    Aurora PostgreSQL Successfully Created!
    ============================================================

    Add the following to your values.yaml, then run helm upgrade:

    postgres:
      enabled: false  # use Aurora instead of the in-cluster PostgreSQL

    secrets:
      postgres:
        host: "${module.aurora.cluster_endpoint}"
        port: 5432
        database: "${var.database_name}"
        username: "${var.administrator_login}"
        password: "${random_password.master.result}"

    ============================================================
    The password above is also stored in AWS Secrets Manager:
    ${aws_secretsmanager_secret.master.arn}
    ============================================================

  EOT
}
