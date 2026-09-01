################################################################################
# Qualytics EKS Cluster — Auto Mode
################################################################################

terraform {
  required_version = ">= 1.11.1"

  backend "s3" {
    key          = "aws/cluster/terraform.tfstate"
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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.1"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
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

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  # The endpoint and CA are unknown until module.eks applies, so defer
  # kubeconfig resolution to apply time rather than provider configuration.
  lazy_load = true

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

}

################################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

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

data "aws_nat_gateway" "egress" {
  count = var.single_nat_gateway ? 1 : 3

  id = module.vpc.natgw_ids[count.index]
}

################################################################################
# EKS Module — Auto Mode
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = local.cluster_version

  endpoint_public_access       = var.cluster_endpoint_public_access
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  endpoint_private_access      = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  # Keyed by ARN, not list index: the map key is the Terraform resource address for
  # the underlying access entry, so index keys would churn unrelated principals
  # whenever an entry is inserted or removed from the middle of the list.
  access_entries = {
    for arn in var.cluster_admin_arns : arn => {
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

  # Enables Auto Mode. The module attaches the Auto Mode cluster-role policies
  # (Compute, BlockStorage, LoadBalancing, Networking) automatically whenever this
  # is set, using a partition-aware ARN prefix — do not re-declare them via
  # iam_role_additional_policies.
  compute_config = {
    enabled    = true
    node_pools = ["system"]
  }

  tags = local.tags
}

################################################################################
# NodeClass — Application Nodes
################################################################################

resource "kubectl_manifest" "ec2nodeclass_app" {
  yaml_body = yamlencode({
    apiVersion = "eks.amazonaws.com/v1"
    kind       = "NodeClass"
    metadata = {
      name = "qualytics-app"
    }
    spec = {
      role                = module.eks.node_iam_role_name
      subnetSelectorTerms = [for s in module.vpc.private_subnets : { id = s }]
      securityGroupSelectorTerms = [{
        tags = { "aws:eks:cluster-name" = local.name }
      }]
      tags = local.tags
    }
  })

  depends_on = [module.eks]
}

################################################################################
# NodeClass — Spark Driver Nodes
################################################################################

resource "kubectl_manifest" "ec2nodeclass_driver" {
  yaml_body = yamlencode({
    apiVersion = "eks.amazonaws.com/v1"
    kind       = "NodeClass"
    metadata = {
      name = "qualytics-driver"
    }
    spec = {
      role                = module.eks.node_iam_role_name
      subnetSelectorTerms = [for s in module.vpc.private_subnets : { id = s }]
      securityGroupSelectorTerms = [{
        tags = { "aws:eks:cluster-name" = local.name }
      }]
      tags = local.tags
    }
  })

  depends_on = [module.eks]
}

################################################################################
# NodeClass — Spark Executor Nodes (NVMe instance store)
################################################################################

resource "kubectl_manifest" "ec2nodeclass_exec" {
  # ephemeralStorage is deliberately left unset. While the Auto Mode default (80Gi)
  # stays below the instance's local NVMe capacity, Auto Mode formats the NVMe
  # (RAID 0 across multiple drives) and uses it as node ephemeral storage — which is
  # where Spark's emptyDir scratch lands. Setting a size at or above the NVMe capacity
  # has the inverse effect: the NVMe is exposed as a raw device and ephemeral storage
  # moves to a large EBS volume. Keep the chart's dataplane.numVolumes at -1 to match;
  # a value > 0 makes the chart mount hostPath /mnt/disks/nvme<n>n1, which nothing
  # here creates.
  yaml_body = yamlencode({
    apiVersion = "eks.amazonaws.com/v1"
    kind       = "NodeClass"
    metadata = {
      name = "qualytics-exec"
    }
    spec = {
      role                = module.eks.node_iam_role_name
      subnetSelectorTerms = [for s in module.vpc.private_subnets : { id = s }]
      securityGroupSelectorTerms = [{
        tags = { "aws:eks:cluster-name" = local.name }
      }]
      tags = local.tags
    }
  })

  depends_on = [module.eks]
}

################################################################################
# NodePool — Application Nodes
################################################################################

resource "kubectl_manifest" "nodepool_app" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "qualytics-app"
    }
    spec = {
      template = {
        metadata = {
          labels = { appNodes = "true" }
        }
        spec = {
          nodeClassRef = {
            group = "eks.amazonaws.com"
            kind  = "NodeClass"
            name  = "qualytics-app"
          }
          requirements = [
            { key = "node.kubernetes.io/instance-type", operator = "In", values = var.app_node_instance_types },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
          ]
        }
      }
      # Highest weight so pods that carry no node selector — notably the
      # ingress-nginx admission-webhook pre-install Jobs — land on this on-demand
      # pool instead of a spot executor node. Karpenter's tie-break between
      # equal-weight pools is not a documented guarantee; this is.
      weight = 100
      # limits is a cost ceiling for the pool, never a provisioning target. Setting
      # it too low leaves pods Pending with no direct error on the pod itself.
      limits = { cpu = "1000", memory = "4000Gi" }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass_app]
}

################################################################################
# NodePool — Spark Driver Nodes
################################################################################

resource "kubectl_manifest" "nodepool_driver" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "qualytics-driver"
    }
    spec = {
      template = {
        metadata = {
          labels = { driverNodes = "true" }
        }
        spec = {
          nodeClassRef = {
            group = "eks.amazonaws.com"
            kind  = "NodeClass"
            name  = "qualytics-driver"
          }
          requirements = [
            { key = "node.kubernetes.io/instance-type", operator = "In", values = var.driver_node_instance_types },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
          ]
        }
      }
      weight = 10
      # Hosts a single replicas:1 driver Deployment, so the ceiling is deliberately
      # far smaller than the app/exec pools. A cost ceiling, not a target.
      limits = { cpu = "100", memory = "400Gi" }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass_driver]
}

################################################################################
# NodePool — Spark Executor Nodes
################################################################################

resource "kubectl_manifest" "nodepool_exec" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "qualytics-exec"
    }
    spec = {
      template = {
        metadata = {
          labels = { executorNodes = "true" }
        }
        spec = {
          nodeClassRef = {
            group = "eks.amazonaws.com"
            kind  = "NodeClass"
            name  = "qualytics-exec"
          }
          requirements = [
            { key = "node.kubernetes.io/instance-type", operator = "In", values = var.executor_node_instance_types },
            { key = "karpenter.sh/capacity-type", operator = "In", values = [var.executor_capacity_type] },
          ]
        }
      }
      # Left unweighted (lowest preference) so only pods that explicitly select
      # executorNodes=true land here. A cost ceiling for the executor fleet, not a
      # provisioning target — raise it if dataplane.dynamicAllocation.maxExecutors
      # is increased well beyond the chart default.
      limits = { cpu = "1000", memory = "4000Gi" }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "5m"
      }
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass_exec]
}

################################################################################
# Kubernetes Namespace and Docker Registry Secret
################################################################################

resource "kubernetes_namespace_v1" "qualytics" {
  count = var.create_qualytics_namespace ? 1 : 0

  metadata {
    name = "qualytics"
  }

  depends_on = [module.eks]
}

resource "kubernetes_config_map_v1" "qualytics_egress_info" {
  metadata {
    name      = "qualytics-egress-info"
    namespace = "qualytics"
  }

  data = {
    "egress.json" = jsonencode({
      public_egress = {
        addresses = sort(module.vpc.nat_public_ips)
        estimated = false
      }
      private_egress = {
        addresses = sort(distinct(concat(
          [for nat_gateway in data.aws_nat_gateway.egress : nat_gateway.private_ip],
          module.vpc.private_subnets_cidr_blocks
        )))
        estimated = false
      }
    })
  }

  depends_on = [module.eks, kubernetes_namespace_v1.qualytics]
}

resource "kubernetes_secret_v1" "docker_registry" {
  count = var.create_qualytics_namespace && var.docker_registry_token != "" ? 1 : 0

  metadata {
    name      = "regcred"
    namespace = kubernetes_namespace_v1.qualytics[0].metadata[0].name
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

  depends_on = [kubernetes_namespace_v1.qualytics]
}
