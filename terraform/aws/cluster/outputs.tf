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

    2. Verify cluster nodes:
       kubectl get nodes

    3. Deploy Qualytics using Helm:
       helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
       helm repo update
       helm upgrade --install qualytics qualytics/qualytics \
         --namespace qualytics \
         -f values.yaml \
         --wait \
         --timeout=10m

    For more information, visit:
    https://github.com/qualytics/qualytics-self-hosted

  EOT
}
