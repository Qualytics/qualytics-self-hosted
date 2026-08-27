################################################################################
# Qualytics GKE Cluster Terraform Configuration
#
# This template creates a GKE cluster with the recommended node pools for
# deploying Qualytics. Customize the variables in terraform.tfvars to match
# your requirements.
################################################################################

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  region = var.region
}

provider "google-beta" {
  region = var.region
}

provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  token                  = data.google_client_config.default.access_token
}

################################################################################
# Project Creation
################################################################################

resource "random_id" "project_suffix" {
  count       = var.project_id == "" ? 1 : 0
  byte_length = 4
}

resource "google_project" "project" {
  count           = var.project_id == "" ? 1 : 0
  name            = var.tenant_name
  project_id      = "qualytics-${var.tenant_name}-${random_id.project_suffix[0].dec}"
  folder_id       = var.folder_id
  billing_account = var.billing_account
  deletion_policy = "DELETE"
}

################################################################################
# Data Sources
################################################################################

data "google_client_config" "default" {}

data "google_compute_zones" "available" {
  project = local.project_id
  region  = var.region

  depends_on = [google_project_service.required_apis]
}

################################################################################
# Local Variables
################################################################################

locals {
  name       = var.cluster_name
  zone       = data.google_compute_zones.available.names[0]
  project_id = var.project_id != "" ? var.project_id : google_project.project[0].project_id

  tags = merge(var.default_labels, {
    cluster = local.name
  })
}

################################################################################
# Enable Required APIs
################################################################################

resource "google_project_service" "required_apis" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "servicenetworking.googleapis.com"
  ])

  project = local.project_id
  service = each.value

  disable_on_destroy = false

  depends_on = [google_project.project]
}

################################################################################
# VPC Network Module
################################################################################

module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 12.0"

  project_id   = local.project_id
  network_name = "${local.name}-vpc"
  routing_mode = "GLOBAL"
  description  = "VPC network for Qualytics GKE cluster"

  auto_create_subnetworks = false

  subnets = [
    {
      subnet_name           = "${local.name}-subnet"
      subnet_ip             = var.subnet_cidr
      subnet_region         = var.region
      subnet_private_access = "true"
      description           = "Private subnet for GKE nodes"
    }
  ]

  secondary_ranges = {
    "${local.name}-subnet" = [
      {
        range_name    = "gke-pods"
        ip_cidr_range = var.pods_cidr
      },
      {
        range_name    = "gke-services"
        ip_cidr_range = var.services_cidr
      }
    ]
  }

  depends_on = [google_project_service.required_apis]
}

################################################################################
# Cloud NAT for Outbound Internet Access
################################################################################

resource "google_compute_address" "nat" {
  count = var.nat_ip_count

  name         = "${local.name}-nat-${count.index + 1}"
  project      = local.project_id
  region       = var.region
  address_type = "EXTERNAL"

  depends_on = [google_project_service.required_apis]
}

module "cloud_nat" {
  source  = "terraform-google-modules/cloud-nat/google"
  version = "~> 5.3.0"

  project_id = local.project_id
  region     = var.region
  router     = "${local.name}-router"
  name       = "${local.name}-nat"

  create_router = true
  network       = module.vpc.network_name
  nat_ips       = google_compute_address.nat[*].self_link

  depends_on = [module.vpc]
}

################################################################################
# GKE Cluster Module
################################################################################

module "gke" {
  source  = "terraform-google-modules/kubernetes-engine/google"
  version = "~> 38.1.0"

  project_id        = local.project_id
  name              = local.name
  region            = var.region
  network           = module.vpc.network_name
  subnetwork        = module.vpc.subnets_names[0]
  ip_range_pods     = "gke-pods"
  ip_range_services = "gke-services"

  http_load_balancing  = true
  dns_cache            = false
  filestore_csi_driver = false

  # Master authorized networks - customize for your security requirements
  master_authorized_networks = var.master_authorized_networks

  service_external_ips    = false
  enable_identity_service = false

  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.deletion_protection

  node_pools = [
    # Application Nodes - for API, Frontend, PostgreSQL, RabbitMQ, and operators
    {
      name                 = "app-nodes"
      machine_type         = var.app_node_machine_type
      node_locations       = local.zone
      min_count            = var.app_node_min_size
      max_count            = var.app_node_max_size
      local_ssd_count      = 0
      spot                 = false
      disk_size_gb         = 100
      disk_type            = "pd-balanced"
      image_type           = "COS_CONTAINERD"
      auto_repair          = true
      auto_upgrade         = true
      preemptible          = false
      initial_node_count   = var.app_node_min_size
      enable_private_nodes = true
    },
    # Spark Driver Nodes
    {
      name                 = "driver-nodes"
      machine_type         = var.driver_node_machine_type
      node_locations       = local.zone
      min_count            = var.driver_node_min_size
      max_count            = var.driver_node_max_size
      local_ssd_count      = 0
      spot                 = false
      disk_size_gb         = 100
      disk_type            = "pd-ssd"
      image_type           = "COS_CONTAINERD"
      auto_repair          = true
      auto_upgrade         = true
      preemptible          = false
      initial_node_count   = var.driver_node_min_size
      enable_private_nodes = true
    },
    # Spark Executor Nodes - with local SSDs for optimal Spark performance
    {
      name                 = "executor-nodes"
      machine_type         = var.executor_node_machine_type
      node_locations       = local.zone
      min_count            = var.executor_node_min_size
      max_count            = var.executor_node_max_size
      local_ssd_count      = var.executor_local_ssd_count
      spot                 = var.executor_use_spot
      disk_size_gb         = 100
      disk_type            = "pd-ssd"
      image_type           = "COS_CONTAINERD"
      auto_repair          = true
      auto_upgrade         = true
      preemptible          = false
      initial_node_count   = var.executor_node_min_size
      enable_private_nodes = true
    }
  ]

  node_pools_oauth_scopes = {
    all = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  node_pools_labels = {
    all = local.tags
    app-nodes = {
      appNodes = "true"
    }
    driver-nodes = {
      driverNodes = "true"
    }
    executor-nodes = {
      executorNodes = "true"
    }
  }

  node_pools_metadata = {
    all = {
      disable-legacy-endpoints = "true"
    }
  }

  node_pools_taints = var.enable_node_taints ? {
    all = []
    app-nodes = [
      {
        key    = "appNodes"
        value  = "true"
        effect = "NO_SCHEDULE"
      }
    ]
    driver-nodes = [
      {
        key    = "driverNodes"
        value  = "true"
        effect = "NO_SCHEDULE"
      }
    ]
    executor-nodes = [
      {
        key    = "executorNodes"
        value  = "true"
        effect = "NO_SCHEDULE"
      }
    ]
    } : {
    all            = []
    app-nodes      = []
    driver-nodes   = []
    executor-nodes = []
  }

  node_pools_tags = {
    all            = ["gke-node", "${local.name}"]
    app-nodes      = []
    driver-nodes   = []
    executor-nodes = []
  }

  depends_on = [
    google_project_service.required_apis,
    module.vpc,
    module.cloud_nat
  ]
}

################################################################################
# Kubernetes Namespace and Docker Registry Secret
################################################################################

resource "kubernetes_namespace" "qualytics" {
  count = var.create_qualytics_namespace ? 1 : 0

  metadata {
    name = "qualytics"
  }

  depends_on = [module.gke]
}

resource "kubernetes_config_map" "qualytics_egress_info" {
  metadata {
    name      = "qualytics-egress-info"
    namespace = "qualytics"
  }

  data = {
    "egress.json" = jsonencode({
      public_egress = {
        addresses = sort(google_compute_address.nat[*].address)
        estimated = false
      }
      private_egress = {
        addresses = sort(distinct([var.pods_cidr, var.subnet_cidr]))
        estimated = false
      }
    })
  }

  depends_on = [module.gke, kubernetes_namespace.qualytics]
}

resource "kubernetes_secret" "docker_registry" {
  count = var.create_qualytics_namespace && var.docker_registry_token != "" ? 1 : 0

  metadata {
    name      = "regcred"
    namespace = kubernetes_namespace.qualytics[0].metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "https://index.docker.io/v1/" = {
          username = "qualyticsai"
          password = var.docker_registry_token
          auth     = base64encode("qualyticsai:${var.docker_registry_token}")
        }
      }
    })
  }

  depends_on = [kubernetes_namespace.qualytics]
}
