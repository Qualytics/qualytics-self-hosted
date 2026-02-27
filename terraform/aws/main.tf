################################################################################
# Qualytics EKS Cluster Terraform Configuration
#
# This template creates an EKS cluster with the recommended node groups for
# deploying Qualytics. Customize the variables in terraform.tfvars to match
# your requirements.
################################################################################

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.default_tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

################################################################################
# Data Sources
################################################################################

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

################################################################################
# Local Variables
################################################################################

locals {
  name            = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = merge(var.default_tags, {
    Cluster = local.name
  })

  # Detect Graviton (ARM) instances - matches m8g, r8g, r8gd, c7g, c7gd, etc.
  # Pattern: letter(s) + number + 'g' indicates ARM/Graviton processor
  app_is_graviton = anytrue([
    for inst in var.app_node_instance_types : can(regex("^[a-z]+[0-9]+g", inst))
  ])
  driver_is_graviton = anytrue([
    for inst in var.driver_node_instance_types : can(regex("^[a-z]+[0-9]+g", inst))
  ])
  exec_is_graviton = anytrue([
    for inst in var.executor_node_instance_types : can(regex("^[a-z]+[0-9]+g", inst))
  ])

  # NVMe setup script for executor nodes
  nvme_setup_script = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    echo "Starting NVMe disk setup for executor nodes"

    IDX=1

    for DEV in $(lsblk -ndo NAME,TYPE | awk '$2 == "disk" {print "/dev/" $1}' | grep nvme); do
      ROOT_DEV=$(findmnt -n -o SOURCE /)
      if [[ "$DEV" == "$ROOT_DEV" ]]; then
        echo "Skipping root device $DEV"
        continue
      fi

      if blkid "$DEV" >/dev/null 2>&1; then
        echo "$DEV already has filesystem or partition, skipping"
        continue
      fi

      echo "Setting up NVMe disk $DEV as nvme$IDX"
      mkfs.xfs -f "$DEV"
      MOUNT_DIR="/mnt/disks/nvme$${IDX}n1"
      mkdir -p "$MOUNT_DIR"
      echo "$DEV $MOUNT_DIR xfs defaults,noatime 0 2" >> /etc/fstab
      mount "$MOUNT_DIR"
      chmod 755 "$MOUNT_DIR"
      echo "Successfully mounted $DEV to $MOUNT_DIR"
      IDX=$((IDX + 1))
    done

    echo "NVMe disk setup completed. Mounted disks:"
    df -h | grep nvme || echo "No NVMe disks were mounted"
  EOT
}

################################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name}-vpc"
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.name
  cluster_version = local.cluster_version

  cluster_endpoint_public_access  = var.cluster_endpoint_public_access
  cluster_endpoint_private_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Cluster access configuration
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    for idx, arn in var.cluster_admin_arns : "admin-${idx}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    # Application Nodes - for API, Frontend, PostgreSQL, RabbitMQ, and operators
    app = {
      name            = "${local.name}-app"
      use_name_prefix = false

      instance_types = var.app_node_instance_types
      capacity_type  = "ON_DEMAND"
      ami_type       = local.app_is_graviton ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"

      min_size     = var.app_node_min_size
      max_size     = var.app_node_max_size
      desired_size = var.app_node_desired_size

      labels = {
        appNodes = "true"
      }

      tags = merge(local.tags, {
        "k8s.io/cluster-autoscaler/enabled"         = "true"
        "k8s.io/cluster-autoscaler/${local.name}"   = "owned"
      })
    }

    # Spark Driver Nodes
    driver = {
      name            = "${local.name}-driver"
      use_name_prefix = false

      instance_types = var.driver_node_instance_types
      capacity_type  = "ON_DEMAND"
      ami_type       = local.driver_is_graviton ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"

      min_size     = var.driver_node_min_size
      max_size     = var.driver_node_max_size
      desired_size = var.driver_node_desired_size

      labels = {
        driverNodes = "true"
      }

      tags = merge(local.tags, {
        "k8s.io/cluster-autoscaler/enabled"         = "true"
        "k8s.io/cluster-autoscaler/${local.name}"   = "owned"
      })
    }

    # Spark Executor Nodes - with local NVMe SSDs for optimal Spark performance
    exec = {
      name            = "${local.name}-exec"
      use_name_prefix = false

      instance_types = var.executor_node_instance_types
      capacity_type  = var.executor_capacity_type
      ami_type       = local.exec_is_graviton ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"

      min_size     = var.executor_node_min_size
      max_size     = var.executor_node_max_size
      desired_size = var.executor_node_desired_size

      labels = {
        executorNodes = "true"
      }

      # Pre-bootstrap commands to format and mount NVMe drives
      pre_bootstrap_user_data = var.enable_nvme_setup ? local.nvme_setup_script : ""

      tags = merge(local.tags, {
        "k8s.io/cluster-autoscaler/enabled"         = "true"
        "k8s.io/cluster-autoscaler/${local.name}"   = "owned"
      })
    }
  }

  tags = local.tags
}

################################################################################
# EBS CSI Driver IRSA
################################################################################

module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${local.name}-ebs-csi-role"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

################################################################################
# Cluster Autoscaler IRSA (Optional)
################################################################################

module "cluster_autoscaler_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  count = var.enable_cluster_autoscaler ? 1 : 0

  role_name                        = "${local.name}-cluster-autoscaler-role"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }

  tags = local.tags
}

################################################################################
# Kubernetes Namespace and Docker Registry Secret
################################################################################

resource "kubernetes_namespace" "qualytics" {
  count = var.create_qualytics_namespace ? 1 : 0

  metadata {
    name = "qualytics"
  }

  depends_on = [module.eks]
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
