## What is Qualytics?

Qualytics is a closed-source container-native platform for assessing, monitoring, and facilitating enterprise data quality. Learn more [about our product and capabilities here](https://qualytics.ai/product/).

## What is in this chart?

This chart will deploy a single-tenant instance of the qualytics platform to a [CNCF compliant](https://www.cncf.io/certification/software-conformance/) kubernetes control plane.

![Deployment Architecture](/deployment_arch_diagram.jpg)

## Prerequisites

Before deploying Qualytics, ensure you have:

- A Kubernetes cluster (recommended version 1.30+)
- `kubectl` configured to access your cluster
- `helm` CLI installed (recommended version 3.12+)
- Docker registry credentials from your Qualytics account manager
- Auth0 configuration details from your Qualytics account manager

## How should I use this chart?

Please work with your account manager at Qualytics to secure the right values for your licensed deployment. If you don't yet have an account manager, [please write us here](mailto://hello@qualytics.ai) to say hello!

### 1. Create a CNCF compliant cluster

Qualytics fully supports kubernetes clusters hosted in AWS, GCP, and Azure as well as any CNCF-compliant control plane.

> **Terraform Templates Available**: We provide ready-to-use Terraform templates for provisioning Kubernetes clusters on [AWS (EKS)](./terraform/aws), [GCP (GKE)](./terraform/gcp), and [Azure (AKS)](./terraform/azure). See the [`/terraform`](./terraform) directory for details.

#### Infrastructure Flexibility

Qualytics is designed to be flexible and can run on virtually any Kubernetes infrastructure. The platform automatically adapts to available resources, making it compatible with a wide range of cluster configurations. The infrastructure requirements scale based on the volume of data to be processed—smaller datasets can run on minimal resources, while larger data volumes benefit from more powerful configurations.

#### Node Configuration

For optimal performance and autoscaling, we recommend using dedicated node groups with the following labels:
- `appNodes=true` — For application components (API, frontend, databases)
- `driverNodes=true` — For Spark driver
- `executorNodes=true` — For Spark executors

However, this setup is flexible:
- **Combined Spark nodes**: Merge driver and executor labels into a single `sparkNodes=true` label if your node group has sufficient resources for both.
- **No node selectors**: Run on any available cluster nodes without targeting specific groups (disable node selectors in values.yaml).
- **Single node**: For development or small workloads, the entire platform can run on a single appropriately-sized node.

For production workloads with large data volumes, we recommend separate node groups with autoscaling enabled to ensure optimal performance and cost efficiency.

#### Suggested Instance Types

The table below shows **suggested** instance types for a standard **Medium-tier** production deployment, suitable for most workloads up to 10 TB of data under management.

|          |          Application Nodes          |               Spark Driver Nodes                |               Spark Executor Nodes               |
|----------|:-----------------------------------:|:-----------------------------------------------:|:------------------------------------------------:|
| Label    | appNodes=true                       | driverNodes=true                                | executorNodes=true                               |
| Scaling  | Autoscaling (1 node on-demand)      | Autoscaling (1 node on-demand)                  | Autoscaling (1 - 12 nodes spot)                  |
| EKS      | m8g.2xlarge (8 vCPUs, 32 GB)        | r8g.2xlarge (8 vCPUs, 64 GB)                    | r8gd.2xlarge (8 vCPUs, 64 GB, 474 GB SSD)        |
| GKE      | n4-standard-8 (8 vCPUs, 32 GB)      | n4-highmem-8 (8 vCPUs, 64 GB)                   | n2-highmem-8 + Local SSD (8 vCPUs, 64 GB)        |
| AKS      | Standard_D8s_v6 (8 vCPUs, 32 GB)    | Standard_E8s_v6 (8 vCPUs, 64 GB)                | Standard_E8ds_v5 (8 vCPUs, 64 GB, 300 GB SSD)    |

For deployments with different data volumes, the [Cluster Sizing Guide](./docs/cluster-sizing.md) covers all six tiers (Small through 4X-Large), on-premises bare-metal specifications, cloud instance types for EKS/GKE/AKS, and Helm configurations. Contact your [Qualytics account manager](mailto://hello@qualytics.ai) for sizing guidance.


#### Docker Registry Secrets

Execute the command below using the credentials supplied by your account manager as a replacement for "&lt;token&gt;". The secret created will provide access to Qualytics private registry on dockerhub and the required images that are available there.

```bash
kubectl create namespace qualytics
kubectl create secret docker-registry regcred -n qualytics --docker-username=qualyticsai --docker-password=<token>
```

> [!IMPORTANT]
> The above configuration will connect your cluster directly to our private dockerhub repositories for pulling our images. If you are unable to directly connect your cluster to our image repository for technical or compliance reasons, then you can instead import our images into your preferred registry using these same credentials (`docker login -u qualyticsai -p <token>`). You'll need to update the image URLs in the values.yaml file in the next step to point to your repository instead of ours.


### 2. Create your configuration file

For a quick start, copy the simplified template configuration:

```bash
cp template.values.yaml values.yaml
```

The `template.values.yaml` file contains essential configurations with sensible defaults. You'll need to update these required settings:

1. **DNS Record** (provided by Qualytics or managed by customer):
   ```yaml
   global:
     dnsRecord: "your-company.qualytics.io"  # or your custom domain
   ```

2. **Auth0 Settings** (provided by your Qualytics account manager):
   ```yaml
   secrets:
     auth0:
       auth0_audience: your-api-audience
       auth0_organization: org_your-org-id
       auth0_spa_client_id: your-spa-client-id
   ```

3. **Security Secrets** (generate secure random values):
   ```yaml
   secrets:
     auth:
       jwt_signing_secret: your-secure-jwt-secret
     postgres:
       secrets_passphrase: your-secure-passphrase
     rabbitmq:
       rabbitmq_password: your-secure-password
   ```

**Optional configurations:**
- Enable `nginx` if you need an ingress controller
- Enable `certmanager` for automatic SSL certificates
- Configure `controlplane.smtp` settings for email notifications
- Node selectors are now enabled by default for dedicated node groups

For advanced configuration, refer to the full `charts/qualytics/values.yaml` file which contains all available options.

Contact your [Qualytics account manager](mailto://hello@qualytics.ai) for assistance.

### 3. Deploy Qualytics to your cluster

Add the Qualytics Helm repository and deploy the platform:

```bash
# Add the Qualytics Helm repository
helm repo add qualytics https://qualytics.github.io/qualytics-self-hosted
helm repo update

# Deploy Qualytics
helm upgrade --install qualytics qualytics/qualytics \
  --namespace qualytics \
  --create-namespace \
  -f values.yaml \
  --timeout=20m
```

**Monitor the deployment:**
```bash
# Check deployment status
kubectl get pods -n qualytics
```

**Get the ingress IP address:**
```bash
# If using nginx ingress
kubectl get svc -n qualytics qualytics-nginx-controller

# Or check ingress resources
kubectl get ingress -n qualytics
```

Note this IP address as it's needed for the next step!

### 4. Configure DNS for your deployment

You have two options for DNS configuration:

**Option A: Qualytics-managed DNS (Recommended)**
Send your [account manager](mailto://hello@qualytics.ai) the IP address from step 3. Qualytics will assign a DNS record under `*.qualytics.io` (e.g., `https://acme.qualytics.io`) and handle SSL certificate management.

**Option B: Custom Domain**
If using your own domain:
1. Create an A record pointing your domain to the ingress IP address
2. Ensure your `global.dnsRecord` in values.yaml matches your custom domain
3. Configure SSL certificates (enable `certmanager` or provide your own)
4. Update any firewall rules to allow traffic to your domain

Contact your [account manager](mailto://hello@qualytics.ai) for assistance with either option.

## Can I run a fully "air-gapped" deployment?

Yes. The only egress requirement for a standard self-hosted Qualytics deployment is to https://auth.qualytics.io which provides Auth0-powered federated authentication. This is recommended for ease of installation and support, but not a strict requirement. If you require a fully private deployment with no access to the public internet, you can instead configure an OpenID Connect (OIDC) integration with your enterprise identity provider (IdP). Simply contact your Qualytics account manager for more details.

## Troubleshooting

### Common Issues

**Pods stuck in Pending state:**
- Check node resources: `kubectl describe nodes`
- Verify node selectors match your cluster labels
- Ensure storage classes are available

**Image pull errors:**
- Verify Docker registry secret: `kubectl get secret regcred -n qualytics -o yaml`
- Check if images are accessible from your cluster

**Ingress not working:**
- Ensure an ingress controller is installed and running
- Check ingress resources: `kubectl describe ingress -n qualytics`

### Useful Commands

```bash
# Check all resources
kubectl get all -n qualytics

# Restart a deployment
kubectl rollout restart deployment/qualytics-api -n qualytics
kubectl rollout restart deployment/qualytics-cmd -n qualytics

# View detailed pod information
kubectl describe pod <pod-name> -n qualytics

# Get spark application logs
kubectl logs -f pod qualytics-spark-driver -n qualytics
```

## Additional Documentation

- [Cluster Sizing Guide](./docs/cluster-sizing.md) — Choose the right cluster size based on your data volume
- [Qualytics UserGuide](https://userguide.qualytics.io/upgrades/qualytics-single-tenant-instance/)
