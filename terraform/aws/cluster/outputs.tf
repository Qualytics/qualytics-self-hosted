################################################################################
# Qualytics EKS Outputs
################################################################################

#-------------------------------------------------------------------------------
# Cluster Information
#-------------------------------------------------------------------------------

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS cluster API server"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "The Kubernetes version of the cluster"
  value       = module.eks.cluster_version
}

output "cluster_arn" {
  description = "The ARN of the EKS cluster"
  value       = module.eks.cluster_arn
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for cluster authentication"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

#-------------------------------------------------------------------------------
# Networking
#-------------------------------------------------------------------------------

output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "List of private subnet IDs"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "List of public subnet IDs"
  value       = module.vpc.public_subnets
}

#-------------------------------------------------------------------------------
# Authentication
#-------------------------------------------------------------------------------

output "cluster_oidc_provider_arn" {
  description = "The ARN of the cluster's OIDC identity provider"
  value       = module.eks.oidc_provider_arn
}

#-------------------------------------------------------------------------------
# kubectl Configuration
#-------------------------------------------------------------------------------

output "configure_kubectl" {
  description = "Command to configure kubectl for the cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

#-------------------------------------------------------------------------------
# Next Steps
#-------------------------------------------------------------------------------

output "next_steps" {
  description = "Instructions for deploying Qualytics"
  value       = <<-EOT

    ============================================================
    EKS Cluster Successfully Created!
    ============================================================

    Next steps to deploy Qualytics:

    1. Configure kubectl:
       aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}

    2. Verify cluster access:
       kubectl get nodes
       (Auto Mode provisions nodes on demand, so this is empty until pods are scheduled.)

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

    6. Deploy Aurora PostgreSQL:
       See terraform/aws/postgres

    7. Deploy Qualytics using Helm:
       helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
       helm repo update
       CHART_VERSION="<version provided by Qualytics>"
       helm upgrade --install qualytics qualytics/qualytics \
         --namespace qualytics \
         --version "$CHART_VERSION" \
         -f values.yaml \
         --wait \
         --timeout=10m

    Full step-by-step guide: terraform/aws/README.md

    For more information, visit:
    https://github.com/qualytics/qualytics-self-hosted

  EOT
}
