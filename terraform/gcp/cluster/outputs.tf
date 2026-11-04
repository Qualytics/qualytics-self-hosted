################################################################################
# Qualytics GKE Outputs
################################################################################

#-------------------------------------------------------------------------------
# Project
#-------------------------------------------------------------------------------

output "project_id" {
  description = "The GCP project ID hosting the cluster (auto-generated when var.project_id is empty)"
  value       = local.project_id
}

output "region" {
  description = "The GCP region of the cluster"
  value       = var.region
}

#-------------------------------------------------------------------------------
# Cluster Information
#-------------------------------------------------------------------------------

output "cluster_name" {
  description = "The name of the GKE cluster"
  value       = module.gke.name
}

output "cluster_endpoint" {
  description = "Endpoint for the GKE cluster API server"
  value       = module.gke.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64 encoded certificate data for cluster authentication"
  value       = module.gke.ca_certificate
  sensitive   = true
}

output "cluster_location" {
  description = "The location (region) of the cluster"
  value       = module.gke.location
}

#-------------------------------------------------------------------------------
# Networking
#-------------------------------------------------------------------------------

output "network_name" {
  description = "The name of the VPC network"
  value       = module.vpc.network_name
}

output "network_id" {
  description = "The ID of the VPC network"
  value       = module.vpc.network_id
}

output "subnet_name" {
  description = "The name of the subnet"
  value       = module.vpc.subnets_names[0]
}

output "subnet_id" {
  description = "The ID of the subnet"
  value       = module.vpc.subnets_ids[0]
}

#-------------------------------------------------------------------------------
# Node Pools
#-------------------------------------------------------------------------------

output "node_pools" {
  description = "Information about the node pools"
  value = {
    app_nodes = {
      machine_type = var.app_node_machine_type
      min_size     = var.app_node_min_size
      max_size     = var.app_node_max_size
      labels       = { appNodes = "true" }
    }
    driver_nodes = {
      machine_type = var.driver_node_machine_type
      min_size     = var.driver_node_min_size
      max_size     = var.driver_node_max_size
      labels       = { driverNodes = "true" }
    }
    executor_nodes = {
      machine_type    = var.executor_node_machine_type
      min_size        = var.executor_node_min_size
      max_size        = var.executor_node_max_size
      spot            = var.executor_use_spot
      local_ssd_count = var.executor_local_ssd_count
      labels          = { executorNodes = "true" }
    }
  }
}

#-------------------------------------------------------------------------------
# kubectl Configuration
#-------------------------------------------------------------------------------

output "configure_kubectl" {
  description = "Command to configure kubectl for the cluster"
  value       = "gcloud container clusters get-credentials ${module.gke.name} --region ${var.region} --project ${local.project_id}"
}

#-------------------------------------------------------------------------------
# Next Steps
#-------------------------------------------------------------------------------

output "next_steps" {
  description = "Instructions for deploying Qualytics"
  value       = <<-EOT

    ============================================================
    GKE Cluster Successfully Created!
    ============================================================

    Next steps to deploy Qualytics:

    1. Configure kubectl:
       gcloud container clusters get-credentials ${module.gke.name} --region ${var.region} --project ${local.project_id}

    2. Verify cluster access:
       kubectl get nodes

    3. Prepare values.yaml using the repository template and set the unique
       secrets.deployment.identifier provided by Qualytics.

    4. If you haven't already, create the Docker registry secret:
       printf "Qualytics registry token: "
       IFS= read -rs QUALYTICS_REGISTRY_TOKEN
       echo
       kubectl create secret docker-registry regcred -n qualytics \
         --docker-username=qualyticsai \
         --docker-password="$QUALYTICS_REGISTRY_TOKEN"
       unset QUALYTICS_REGISTRY_TOKEN

    5. Create the TLS Secret for the ingress (see docs/ingress-tls.md):
       kubectl create secret tls qualytics-tls-cert -n qualytics \
         --cert=./fullchain.pem --key=./privkey.pem

    6. Deploy AlloyDB for PostgreSQL:
       See terraform/gcp/postgres

    7. Deploy Qualytics using Helm:
       helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
       helm repo update
       CHART_VERSION="<version provided by Qualytics>"
       helm upgrade --install qualytics qualytics/qualytics \
         --namespace qualytics \
         --version "$CHART_VERSION" \
         -f values.yaml \
         --wait \
         --timeout=5m

    Full step-by-step guide: terraform/gcp/README.md

    For more information, visit:
    https://github.com/qualytics/qualytics-self-hosted

  EOT
}
