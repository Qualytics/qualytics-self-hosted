################################################################################
# Qualytics AlloyDB for PostgreSQL Terraform Configuration
#
# Creates an AlloyDB cluster with a primary instance reachable only through
# private services access on the same VPC network as your GKE cluster. The
# project and network are read automatically from the cluster state — run
# terraform/gcp/cluster first, then run this directory.
#
# Prerequisites:
#   cd terraform/gcp/cluster && terraform apply   (creates GKE cluster + VPC)
#   cd terraform/gcp/postgres && terraform apply   (this file)
################################################################################

terraform {
  # Write-only arguments (initial_user.password_wo) require Terraform 1.11+.
  required_version = ">= 1.11.1"

  backend "gcs" {
    prefix = "gcp/postgres"
    # bucket is supplied at init time:
    # terraform init -backend-config="bucket=<your-tfstate-bucket>"
  }

  required_providers {
    google = {
      # 7.x is the first major version with deletion_protection and the
      # write-only password arguments on google_alloydb_cluster.
      source  = "hashicorp/google"
      version = "~> 7.46"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = local.project_id
  region  = var.region
}

################################################################################
# Remote State — reads the project and VPC network from the cluster apply
################################################################################

data "terraform_remote_state" "cluster" {
  backend = "gcs"
  config = {
    bucket = var.tfstate_bucket
    prefix = var.tfstate_prefix
  }
}

################################################################################
# Local Variables
################################################################################

locals {
  name       = var.cluster_name
  project_id = data.terraform_remote_state.cluster.outputs.project_id

  # projects/<project>/global/networks/<name> — the form AlloyDB and service
  # networking both expect.
  network_id = data.terraform_remote_state.cluster.outputs.network_id

  labels = merge(var.default_labels, {
    cluster = local.name
  })
}

################################################################################
# Required APIs
# servicenetworking is also enabled by the cluster module; declaring it here
# keeps this directory self-contained. disable_on_destroy = false so a destroy
# here never disables an API another workload in the project depends on.
################################################################################

resource "google_project_service" "required_apis" {
  for_each = toset([
    "alloydb.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
  ])

  project = local.project_id
  service = each.value

  disable_on_destroy = false
}

################################################################################
# Private Services Access
# AlloyDB has no public IP here: it is reached over a VPC peering to Google's
# service producer network. Reserve an internal range for it on the cluster VPC.
################################################################################

resource "google_compute_global_address" "alloydb" {
  name          = "${local.name}-alloydb-psa"
  project       = local.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = var.psa_address
  prefix_length = var.psa_prefix_length
  network       = local.network_id

  labels = local.labels

  depends_on = [google_project_service.required_apis]
}

# One connection exists per (network, service) pair. If something else in this
# VPC (Cloud SQL, Memorystore, ...) already created one, this resource takes
# over its reserved ranges — add those ranges to reserved_peering_ranges first.
resource "google_service_networking_connection" "alloydb" {
  network                 = local.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.alloydb.name]
}

################################################################################
# Database Password
# Stored in Secret Manager
################################################################################

resource "random_password" "master" {
  length  = 32
  special = false

  # initial_user.password_wo below is a write-only argument: AlloyDB only
  # receives a new value when password_wo_version changes. Keying the generated
  # password to the same variable keeps the two in lockstep, so one apply both
  # regenerates the password and triggers the send. Without this keeper,
  # bumping the version re-sends the identical password and "rotation" is a
  # no-op.
  #
  # The keeper is also what makes rotation opt-in: while password_wo_version
  # stays at its default, this value is stable in state and routine
  # `terraform apply` runs never change the password.
  #
  # Corollary: do not force-replace this resource on its own (`-replace`,
  # `taint`). That regenerates the password in state and Secret Manager while
  # the unchanged password_wo_version means AlloyDB never receives it — a
  # silent lockout. Bump password_wo_version instead.
  keepers = {
    version = tostring(var.password_wo_version)
  }
}

resource "google_secret_manager_secret" "master" {
  project   = local.project_id
  secret_id = "${local.name}-alloydb-password"

  # Pin the secret payload to the database region rather than letting Google
  # replicate it globally.
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  labels = local.labels

  depends_on = [google_project_service.required_apis]
}

resource "google_secret_manager_secret_version" "master" {
  secret = google_secret_manager_secret.master.id

  # Stores a structured JSON object so a single secret holds all connection fields.
  secret_data = jsonencode({
    username = var.administrator_login
    password = random_password.master.result
    host     = google_alloydb_instance.primary.ip_address
    port     = 5432
    dbname   = var.database_name
  })
}

################################################################################
# AlloyDB Cluster
################################################################################

resource "google_alloydb_cluster" "this" {
  project    = local.project_id
  cluster_id = "${local.name}-alloydb"
  location   = var.region

  database_version = "POSTGRES_${var.postgresql_version}"

  # Terraform-side guard only — GCP has no server-side equivalent. It is read
  # from state on delete, so tearing down means applying it as false first.
  deletion_protection = var.deletion_protection

  network_config {
    network            = local.network_id
    allocated_ip_range = google_compute_global_address.alloydb.name
  }

  # The password is self-managed via random_password, and NOTHING rotates it
  # automatically. Rotation only happens when an operator explicitly increments
  # password_wo_version (default 1) and re-applies — see ./README.md.
  initial_user {
    user                = var.administrator_login
    password_wo         = random_password.master.result
    password_wo_version = var.password_wo_version
  }

  automated_backup_policy {
    enabled       = true
    location      = var.region
    backup_window = "3600s"

    weekly_schedule {
      days_of_week = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]

      start_times {
        hours   = var.backup_start_hour
        minutes = 0
        seconds = 0
        nanos   = 0
      }
    }

    quantity_based_retention {
      count = var.backup_retention_count
    }

    labels = local.labels
  }

  labels = local.labels

  depends_on = [
    google_project_service.required_apis,
    google_service_networking_connection.alloydb,
  ]
}

################################################################################
# AlloyDB Primary Instance
################################################################################

resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.this.name
  instance_id   = "${local.name}-alloydb-primary"
  instance_type = "PRIMARY"

  # REGIONAL keeps a standby in a second zone with automatic failover;
  # ZONAL is a single node (cheaper, no HA).
  availability_type = var.availability_type

  machine_config {
    cpu_count    = var.cpu_count
    machine_type = var.machine_type
  }

  labels = local.labels
}
