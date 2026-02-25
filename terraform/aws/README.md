# Qualytics EKS Terraform Module

This Terraform configuration creates an Amazon EKS cluster configured for deploying Qualytics.

## What This Creates

- **VPC** with public and private subnets across 3 availability zones
- **EKS Cluster** (Kubernetes 1.33) with:
  - EBS CSI driver for persistent volumes
  - VPC CNI for pod networking
  - CoreDNS and kube-proxy
- **Node Groups**:
  - **Application nodes** (`appNodes=true`) - For API, Frontend, PostgreSQL, RabbitMQ
  - **Driver nodes** (`driverNodes=true`) - For Spark driver
  - **Executor nodes** (`executorNodes=true`) - For Spark executors with local NVMe SSDs
- **IAM Roles** for EBS CSI and Cluster Autoscaler
- **Qualytics namespace** (optional)

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.3.0
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials
- Docker registry credentials from your Qualytics account manager

## Quick Start

1. **Clone the repository and navigate to the AWS directory:**

   ```bash
   git clone https://github.com/qualytics/qualytics-self-hosted.git
   cd qualytics-self-hosted/terraform/aws
   ```

2. **Create your configuration file:**

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. **Edit `terraform.tfvars`** with your settings:

   ```hcl
   aws_region   = "us-east-1"
   cluster_name = "qualytics"

   # Optional: Automatically create the Docker registry secret
   # docker_registry_token = "your-token-from-qualytics"
   ```

4. **Initialize and apply Terraform:**

   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

5. **Configure kubectl:**

   ```bash
   aws eks update-kubeconfig --region us-east-1 --name qualytics
   ```

6. **Create Docker registry secret** (if not using `docker_registry_token` variable):

   ```bash
   kubectl create secret docker-registry regcred -n qualytics \
     --docker-username=qualyticsai \
     --docker-password=<token-from-qualytics>
   ```

7. **Deploy Qualytics using Helm:**

   ```bash
   helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
   helm repo update
   helm upgrade --install qualytics qualytics/qualytics \
     --namespace qualytics \
     -f values.yaml \
     --timeout=20m
   ```

## Instance Type Recommendations

| Node Group | Default Instance | vCPUs | Memory | Storage |
|------------|------------------|-------|--------|---------|
| Application | m8g.2xlarge | 8 | 32 GB | EBS |
| Driver | r8g.2xlarge | 8 | 64 GB | EBS |
| Executor | r8gd.2xlarge | 8 | 64 GB | 474 GB NVMe |

For x86 architecture, use equivalent `m7i`, `r7i`, and `r7id` instance types.

## Cost Optimization

- **Spot Instances**: Executor nodes use SPOT by default for cost savings
- **Single NAT Gateway**: Enabled by default (set `single_nat_gateway = false` for HA)
- **Autoscaling**: All node groups support cluster autoscaler

## Configuration Options

See `variables.tf` for all available configuration options, including:

- Node group sizing and instance types
- VPC CIDR configuration
- Kubernetes version
- Cluster authentication (IAM access entries)

## Helm Values Configuration

When deploying Qualytics, ensure your `values.yaml` includes the appropriate node selectors:

```yaml
global:
  platform: "aws"

appNodeSelector:
  appNodes: "true"

driverNodeSelector:
  driverNodes: "true"

executorNodeSelector:
  executorNodes: "true"
```

## Cleanup

To destroy the infrastructure:

```bash
# First, uninstall Qualytics
helm uninstall qualytics -n qualytics

# Then destroy Terraform resources
terraform destroy
```

## Support

Contact your [Qualytics account manager](mailto:hello@qualytics.ai) for assistance.
