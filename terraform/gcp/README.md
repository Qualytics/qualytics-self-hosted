# Qualytics GKE Terraform Module

This Terraform configuration creates a Google Kubernetes Engine (GKE) cluster configured for deploying Qualytics.

## What This Creates

- **VPC Network** with a private subnet and secondary ranges for pods/services
- **Cloud NAT** for outbound internet access from private nodes
- **GKE Cluster** with:
  - GCE Persistent Disk CSI driver
  - HTTP(S) Load Balancing
  - Horizontal Pod Autoscaling
- **Node Pools**:
  - **Application nodes** (`appNodes=true`) - For API, Frontend, PostgreSQL, RabbitMQ
  - **Driver nodes** (`driverNodes=true`) - For Spark driver
  - **Executor nodes** (`executorNodes=true`) - For Spark executors with local SSDs
- **Qualytics namespace** (optional)

## Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.3.0
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) configured with appropriate credentials
- A GCP project with billing enabled
- Docker registry credentials from your Qualytics account manager

## Quick Start

1. **Clone the repository and navigate to the GCP directory:**

   ```bash
   git clone https://github.com/qualytics/qualytics-self-hosted.git
   cd qualytics-self-hosted/terraform/gcp
   ```

2. **Authenticate with GCP:**

   ```bash
   gcloud auth application-default login
   ```

3. **Create your configuration file:**

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

4. **Edit `terraform.tfvars`** with your settings:

   ```hcl
   project_id   = "your-gcp-project-id"
   region       = "us-central1"
   cluster_name = "qualytics"

   # Optional: Automatically create the Docker registry secret
   # docker_registry_token = "your-token-from-qualytics"
   ```

5. **Initialize and apply Terraform:**

   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

6. **Configure kubectl:**

   ```bash
   gcloud container clusters get-credentials qualytics --region us-central1 --project your-gcp-project-id
   ```

7. **Create Docker registry secret** (if not using `docker_registry_token` variable):

   ```bash
   kubectl create secret docker-registry regcred -n qualytics \
     --docker-username=qualyticsai \
     --docker-password=<token-from-qualytics>
   ```

8. **Deploy Qualytics using Helm:**

   ```bash
   helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
   helm repo update
   helm upgrade --install qualytics qualytics/qualytics \
     --namespace qualytics \
     -f values.yaml \
     --wait \
     --timeout=5m
   ```

## Machine Type Recommendations

| Node Pool | Default Machine | vCPUs | Memory | Storage |
|-----------|-----------------|-------|--------|---------|
| Application | n4-standard-8 | 8 | 32 GB | PD |
| Driver | n4-highmem-8 | 8 | 64 GB | PD |
| Executor | n2-highmem-8 | 8 | 64 GB | 750 GB Local SSD |

Note: N4 series does not support local SSD attachments. N2 series is recommended for executor nodes.

## Cost Optimization

- **Spot VMs**: Executor nodes use Spot by default for cost savings
- **Autoscaling**: All node pools support cluster autoscaler
- **Local SSDs**: Attached to executor nodes for optimal Spark performance

## Configuration Options

See `variables.tf` for all available configuration options, including:

- Node pool sizing and machine types
- Network CIDR configuration
- Local SSD configuration
- Node taints and labels

## Helm Values Configuration

When deploying Qualytics, ensure your `values.yaml` includes the appropriate node selectors:

```yaml
global:
  platform: "gcp"

appNodeSelector:
  appNodes: "true"

driverNodeSelector:
  driverNodes: "true"

executorNodeSelector:
  executorNodes: "true"

tolerations:
  appNodeTolerations:
    - key: appNodes
      operator: Equal
      value: "true"
      effect: NoSchedule
  driverNodeTolerations:
    - key: driverNodes
      operator: Equal
      value: "true"
      effect: NoSchedule
  executorNodeTolerations:
    - key: executorNodes
      operator: Equal
      value: "true"
      effect: NoSchedule
```

## Local SSD Configuration

Executor nodes are configured with local SSDs for optimal Spark performance. The default configuration attaches 2 local SSDs (750GB total). Each local SSD provides 375GB of high-performance storage.

To disable local SSDs:
```hcl
executor_local_ssd_count = 0
```

## Cleanup

To destroy the infrastructure:

```bash
# First, uninstall Qualytics
helm uninstall qualytics -n qualytics

# Disable deletion protection (if enabled)
gcloud container clusters update qualytics --region us-central1 --no-deletion-protection

# Then destroy Terraform resources
terraform destroy
```

## Support

Contact your [Qualytics account manager](mailto:hello@qualytics.ai) for assistance.
