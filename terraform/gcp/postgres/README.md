# AlloyDB for PostgreSQL — Reference

See [`../README.md`](../README.md) for the full deployment walkthrough.

## What This Creates

| Resource | Description |
|---|---|
| Required APIs | `alloydb`, `secretmanager`, `servicenetworking` (never disabled on destroy) |
| Global internal address | Range reserved on the cluster VPC for private services access (`/16` by default) |
| Service networking connection | Peers the VPC with Google's service producer network over that range |
| AlloyDB cluster | `POSTGRES_<version>`, daily automated backups, Terraform `deletion_protection` |
| AlloyDB primary instance | `REGIONAL` (HA standby in a second zone) by default; private IP only |
| Secret Manager secret | Stores database credentials as a structured JSON object, replicated in `region` only |

The project and VPC network are read from the `terraform/gcp/cluster` state. Pods reach the primary instance's private IP over the VPC peering; no firewall rule is needed.

## IAM Permissions

Covers the resources this module manages, granted on the Qualytics project. It is not a complete least-privilege policy — Terraform's GCS state backend and provider bootstrap calls are not included (see [`../README.md`](../README.md) Step 1).

| Role | Why |
|---|---|
| `roles/alloydb.admin` | Create, update, and delete the AlloyDB cluster and instance |
| `roles/compute.networkAdmin` | Reserve the global internal address on the VPC |
| `roles/servicenetworking.networksAdmin` | Create the private services access connection |
| `roles/secretmanager.admin` | Create the secret and its versions |
| `roles/serviceusage.serviceUsageAdmin` | Enable the required APIs |

On the state bucket, the identity needs `roles/storage.objectAdmin` for this module's own state and read access to the `gcp/cluster` prefix.

## Inputs

| Name | Description | Default |
|---|---|---|
| `region` | GCP region — must match `terraform/gcp/cluster` | `us-central1` |
| `cluster_name` | Name prefix — must match `terraform/gcp/cluster` | `qualytics` |
| `tfstate_bucket` | GCS bucket used as Terraform state backend — must match `terraform/gcp/cluster` | required |
| `tfstate_prefix` | GCS prefix of the cluster module's state | `gcp/cluster` |
| `database_name` | Database Qualytics connects to | `surveillance_hub` |
| `administrator_login` | Initial (administrator) username | `postgres` |
| `postgresql_version` | PostgreSQL major version (14–18) | `17` |
| `cpu_count` | vCPUs for the primary instance (8 GB memory per vCPU) | `2` |
| `machine_type` | Optional explicit machine type; vCPUs must equal `cpu_count` | `null` |
| `availability_type` | `REGIONAL` (HA) or `ZONAL` | `REGIONAL` |
| `psa_prefix_length` | Prefix length of the private services access range | `16` |
| `psa_address` | Optional first address of that range | `null` (Google picks) |
| `backup_retention_count` | Daily automated backups to retain | `7` |
| `backup_start_hour` | Hour (UTC) the daily backup starts | `3` |
| `deletion_protection` | Prevent Terraform from deleting the cluster | `true` |
| `password_wo_version` | Increment to rotate the password | `1` |
| `default_labels` | Labels applied to all resources | see variables.tf |

## Outputs

| Name | Description | Sensitive |
|---|---|---|
| `db_host` | Primary instance private IP | No |
| `db_port` | PostgreSQL port (5432) | No |
| `db_name` | Database name | No |
| `db_username` | Administrator username | Yes |
| `db_password` | Administrator password | Yes |
| `db_secret_id` | Secret Manager secret ID | No |
| `alloydb_cluster_id` | AlloyDB cluster ID | No |
| `alloydb_cluster_name` | AlloyDB cluster resource name | No |
| `alloydb_primary_instance_name` | Primary instance resource name | No |
| `psa_range` | Reserved private services access range (CIDR) | No |
| `helm_values` | Ready-to-paste Helm values block | Yes |

## The Qualytics Database

AlloyDB creates only the built-in `postgres` database, and Terraform cannot create additional databases on it (there is no AlloyDB database resource, and the instance has no IP reachable from where Terraform runs). If the Qualytics API logs `database "surveillance_hub" does not exist` on first boot, create it once — from AlloyDB Studio in the Google Cloud console, or any `psql` client that can reach the private IP — connected as `postgres`:

```sql
CREATE DATABASE surveillance_hub;
```

Then restart the API and CMD deployments.

## Private Services Access

Private services access allows one connection per VPC network. If something else in the VPC — Cloud SQL, Memorystore, another AlloyDB — already created a `servicenetworking.googleapis.com` connection, this module takes it over and replaces its reserved ranges with its own. In that case, import the existing connection and add the existing range names alongside this module's range before applying.

Pick `psa_address` deliberately when the VPC is peered with other networks or reached over VPN: the reserved range must not overlap anything routable from the VPC.

## Password Rotation (if required)

**Rotation is off by default and never automatic.** Nothing in this module rotates the password on a schedule, and routine `terraform apply` runs leave it unchanged.

Rotating is a deliberate act with an application-side follow-up: the new password must be copied into your Helm values and the release upgraded, or Qualytics can no longer authenticate. Do it only when you intend to.

To rotate, increment `password_wo_version` in `terraform.tfvars` and re-apply:

```hcl
password_wo_version = 2
```

> Do not force-replace `random_password.master` on its own (`terraform apply -replace`, `taint`) as a way to rotate. That regenerates the password in state and Secret Manager, but because `initial_user.password_wo` is write-only and the version is unchanged, AlloyDB never receives it — leaving Secret Manager holding a password the database rejects. Always rotate by incrementing the version.

```bash
terraform apply
terraform output -raw helm_values  # copy new password into values.yaml
helm upgrade qualytics qualytics/qualytics --namespace qualytics -f values.yaml
```

`password_wo_version` is a keeper on the generated password, so a single apply regenerates it, sends it to AlloyDB, and adds a new Secret Manager version.

## Retrieve Credentials from Secret Manager

```bash
gcloud secrets versions access latest \
  --secret=<cluster-name>-alloydb-password \
  --project=<project-id> | jq .
```

## Teardown

`deletion_protection` defaults to `true`. It is a Terraform-side guard read from state, so clear it with an apply before destroying:

```bash
# 1. Disable deletion protection
terraform apply -var="deletion_protection=false"

# 2. Destroy
terraform destroy
```

Deleting the AlloyDB cluster deletes its data. Export it first (`pg_dump`) if you need it afterwards.

If `terraform destroy` fails on the service networking connection with *"Producer services (e.g. CloudSQL, Cloud Memstore, etc.) are still using this connection"*, Google is still releasing the deleted instance. Wait a few minutes and run `terraform destroy` again.

The Secret Manager secret is deleted immediately on destroy — there is no recovery window, so redeploying under the same `cluster_name` does not collide.
