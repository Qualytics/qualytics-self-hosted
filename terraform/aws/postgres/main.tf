################################################################################
# Qualytics Aurora PostgreSQL Terraform Configuration
#
# Creates an Aurora PostgreSQL cluster inside the same VPC as your EKS cluster.
# Networking (VPC ID, private subnets) is read automatically from the cluster
# state file — run terraform/aws/cluster first, then run this directory.
#
# Prerequisites:
#   cd terraform/aws/cluster && terraform apply   (creates EKS cluster + VPC)
#   cd terraform/aws/postgres && terraform apply  (this file)
################################################################################

terraform {
  required_version = ">= 1.11.1"

  backend "s3" {
    key          = "aws/postgres/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
    # bucket and region are supplied at init time:
    # terraform init -backend-config="bucket=<your-tfstate-bucket>" \
    #               -backend-config="region=<your-region>"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.default_tags
  }
}

################################################################################
# Remote State — reads VPC and subnet IDs from the cluster apply
################################################################################

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.tfstate_bucket
    key    = var.tfstate_key
    region = coalesce(var.tfstate_region, var.aws_region)
  }
}

################################################################################
# Data Sources
################################################################################

# Fetches the VPC CIDR block so the security group can allow all intra-VPC
# PostgreSQL traffic without requiring a separate variable.
data "aws_vpc" "cluster" {
  id = data.terraform_remote_state.cluster.outputs.vpc_id
}

################################################################################
# Local Variables
################################################################################

locals {
  name       = var.cluster_name
  vpc_id     = data.terraform_remote_state.cluster.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.cluster.outputs.private_subnets

  tags = merge(var.default_tags, {
    Cluster = local.name
  })
}

################################################################################
# Database Password
# Stored in AWS Secrets Manager
################################################################################

resource "random_password" "master" {
  length  = 32
  special = false

  # master_password_wo below is a write-only argument: Aurora only receives a new
  # value when master_password_wo_version changes. Keying the generated password to
  # the same variable keeps the two in lockstep, so one apply both regenerates the
  # password and triggers the send. Without this keeper, bumping the version
  # re-sends the identical password and "rotation" is a no-op.
  #
  # The keeper is also what makes rotation opt-in: while master_password_wo_version
  # stays at its default, this value is stable in state and routine `terraform apply`
  # runs never change the password.
  #
  # Corollary: do not force-replace this resource on its own (`-replace`, `taint`).
  # That regenerates the password in state and Secrets Manager while the unchanged
  # wo_version means Aurora never receives it — a silent lockout. Bump
  # master_password_wo_version instead.
  keepers = {
    version = tostring(var.master_password_wo_version)
  }
}

# Suffixes the final snapshot name so a teardown/redeploy cycle under the same
# cluster_name does not collide with the snapshot left by the previous destroy
# (snapshot identifiers must be unique per account+region). Keyed to the cluster
# name rather than a timestamp, which would produce a perpetual diff.
resource "random_id" "final_snapshot" {
  byte_length = 4
  keepers = {
    id = var.cluster_name
  }
}

resource "aws_secretsmanager_secret" "master" {
  name        = "${local.name}-postgres-password"
  description = "Master credentials for Aurora PostgreSQL cluster ${local.name}"

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id

  # Stores a structured JSON object so a single secret holds all connection fields.
  secret_string = jsonencode({
    username = var.administrator_login
    password = random_password.master.result
    host     = module.aurora.cluster_endpoint
    port     = 5432
    dbname   = var.database_name
  })
}

################################################################################
# Security Group
# Allows PostgreSQL traffic (5432) from any resource within the VPC.
################################################################################

resource "aws_security_group" "aurora" {
  name        = "${local.name}-aurora-sg"
  description = "Allow inbound PostgreSQL from within the VPC to Aurora"
  vpc_id      = local.vpc_id

  ingress {
    description = "PostgreSQL from VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.cluster.cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.name}-aurora-sg"
  })
}

################################################################################
# Aurora PostgreSQL Cluster
################################################################################

module "aurora" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 10.2"

  name                   = "${local.name}-postgres"
  engine                 = "aurora-postgresql"
  engine_version         = var.postgresql_version
  cluster_instance_class = var.instance_class

  instances = var.instances

  vpc_id                 = local.vpc_id
  subnets                = local.subnet_ids
  create_db_subnet_group = true

  # Disable the module's built-in SG; we supply our own via vpc_security_group_ids below.
  create_security_group = false

  # Always encrypt storage at rest
  storage_encrypted = true

  # false = changes apply during the next maintenance window (safer for production)
  apply_immediately = var.apply_immediately

  # Enhanced monitoring is disabled by default (requires an IAM role and costs extra).
  # Set monitoring_interval on individual instances to enable it.
  cluster_monitoring_interval = 0

  # Stream PostgreSQL logs to CloudWatch Logs for visibility. Terraform owns the log
  # group so retention is bounded — left to RDS, the group is auto-created with
  # "Never expire" and grows indefinitely.
  enabled_cloudwatch_logs_exports        = ["postgresql"]
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  master_username = var.administrator_login
  database_name   = var.database_name

  # The master password is self-managed via random_password, and NOTHING rotates it
  # automatically. Rotation only happens when an operator explicitly increments
  # master_password_wo_version (default 1) and re-applies — see ./README.md.
  #
  # manage_master_user_password = false keeps the password out of RDS-managed Secrets
  # Manager, which is what would otherwise put it on an AWS rotation schedule. The
  # module gates its aws_secretsmanager_secret_rotation resource on
  # (manage_master_user_password && manage_master_user_password_rotation), so that
  # resource is already never created here. The second flag is pinned to false anyway
  # so that neither an upstream default change nor a later switch to RDS-managed
  # passwords can silently turn scheduled rotation on.
  manage_master_user_password          = false
  manage_master_user_password_rotation = false
  master_password_wo                   = random_password.master.result
  master_password_wo_version           = var.master_password_wo_version

  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = coalesce(var.final_snapshot_identifier, "${local.name}-postgres-final-${random_id.final_snapshot.hex}")

  backup_retention_period = var.backup_retention_period
  preferred_backup_window = var.preferred_backup_window

  vpc_security_group_ids = [aws_security_group.aurora.id]

  deletion_protection = var.deletion_protection

  tags = local.tags
}
