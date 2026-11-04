# Azure Database for PostgreSQL — Reference

See [`../README.md`](../README.md) for the full deployment walkthrough.

## What This Creates

| Resource | Description |
|---|---|
| Delegated subnet | `10.0.16.0/24` by default, in the cluster VNet, delegated to `Microsoft.DBforPostgreSQL/flexibleServers` |
| Network security group | Allows TCP 5432 from the VNet address space, associated with that subnet |
| Private DNS zone + VNet link | `<cluster_name>.private.postgres.database.azure.com`, so the server FQDN resolves to its private IP from the cluster |
| Flexible Server | PostgreSQL `17`, `GP_Standard_D2ds_v5`, 32 GB with auto-grow, `ZoneRedundant` HA, primary in the AKS node zone, no public network access |
| Database | `surveillance_hub` (UTF8), created by Terraform |
| Server parameters | `log_connections` and `log_checkpoints` on |
| Key Vault + secret | Stores database credentials as a structured JSON object |
| Deletion guard | `terraform_data` resource that stops `terraform destroy` and server replacement while `deletion_protection = true` |

The subscription, resource group, VNet and zone are read from the `terraform/azure/cluster` state. Pods reach the server over the VNet; there is no public endpoint.

The server and Key Vault names must be unique across all of Azure, so both default to `cluster_name` plus a random six-character suffix (for example `qualytics-pg-a1b2c3` and `qualyticspga1b2c3`). Set `server_name` / `key_vault_name` to choose them yourself.

## Permissions

| Role | Scope | Why |
|---|---|---|
| `Contributor` | Subscription | Create the subnet, NSG, private DNS zone, Flexible Server and Key Vault, and let the azurerm provider register `Microsoft.DBforPostgreSQL` / `Microsoft.KeyVault` if they are not registered yet |

`Contributor` on the cluster resource group alone is enough once those resource providers are registered in the subscription. The module grants no roles and creates no locks, so `Owner` / `User Access Administrator` is not needed. Secret access on the Key Vault comes from an access policy that the module grants to the identity running it. Add any other identity that will run the module later (for example a CI service principal) to `key_vault_admin_object_ids`, or it cannot read the secret on refresh.

On the state storage account, the identity needs to read the storage account keys (`Contributor` on the storage account covers this) — the `azurerm` backend authenticates with them by default.

## Inputs

| Name | Description | Default |
|---|---|---|
| `cluster_name` | Name prefix — must match `terraform/azure/cluster` | `qualytics` |
| `tfstate_resource_group_name` | Resource group of the state storage account | required |
| `tfstate_storage_account_name` | State storage account — must match `terraform/azure/cluster` | required |
| `tfstate_container_name` | State container | `tfstate` |
| `tfstate_key` | Blob name of the cluster module's state | `azure/cluster/terraform.tfstate` |
| `server_name` | Optional explicit server name | `null` (`<cluster_name>-pg-<suffix>`) |
| `key_vault_name` | Optional explicit Key Vault name | `null` (derived + suffix) |
| `key_vault_admin_object_ids` | Extra Entra object IDs granted secret access | `[]` |
| `database_name` | Database Qualytics connects to | `surveillance_hub` |
| `administrator_login` | Administrator username | `postgres` |
| `postgresql_version` | PostgreSQL major version (14–18) | `17` |
| `sku_name` | Flexible Server SKU | `GP_Standard_D2ds_v5` |
| `storage_mb` | Storage size in MB | `32768` |
| `storage_tier` | Optional storage performance tier | `null` |
| `auto_grow_enabled` | Grow storage automatically | `true` |
| `high_availability_mode` | `ZoneRedundant`, `SameZone` or `Disabled` | `ZoneRedundant` |
| `postgres_subnet_cidr` | Delegated subnet CIDR (inside the cluster VNet) | `10.0.16.0/24` |
| `backup_retention_days` | Backup retention (7–35 days) | `7` |
| `geo_redundant_backup_enabled` | Geo-redundant backups (set at creation only) | `false` |
| `maintenance_window` | Preferred maintenance window (UTC) | Sunday 03:00 |
| `deletion_protection` | Stop Terraform from deleting or replacing the server | `true` |
| `password_wo_version` | Increment to rotate the password | `1` |
| `default_tags` | Tags applied to all resources | see variables.tf |

## Outputs

| Name | Description | Sensitive |
|---|---|---|
| `db_host` | Server FQDN (resolves to the private IP inside the VNet) | No |
| `db_port` | PostgreSQL port (5432) | No |
| `db_name` | Database name | No |
| `db_username` | Administrator username | Yes |
| `db_password` | Administrator password | Yes |
| `key_vault_name` | Key Vault holding the credentials | No |
| `key_vault_secret_name` | Key Vault secret name | No |
| `key_vault_secret_id` | Versionless Key Vault secret ID | No |
| `server_name` / `server_id` | Flexible Server name and resource ID | No |
| `postgres_subnet_id` | Delegated subnet ID | No |
| `private_dns_zone_name` | Private DNS zone name | No |
| `helm_values` | Ready-to-paste Helm values block | Yes |

## Networking Notes

- `postgres_subnet_cidr` must be inside the cluster VNet (`vnet_cidr`, `10.0.0.0/16` by default) and must not overlap the AKS subnet. If you changed `vnet_cidr` or `aks_subnet_cidr` in the cluster module, change this too.
- The subnet is delegated to Flexible Server, so nothing else can be placed in it. One subnet can hold several Flexible Servers.
- The server uses TLS by default (`require_secure_transport = on`). The chart connects with `sslmode=prefer`, which negotiates TLS, so no chart change is needed.

## Password Rotation (if required)

**Rotation is off by default and never automatic.** Nothing in this module rotates the password on a schedule, and routine `terraform apply` runs leave it unchanged.

Rotating is a deliberate act with an application-side follow-up: the new password must be copied into your Helm values and the release upgraded, or Qualytics can no longer authenticate. Do it only when you intend to.

To rotate, increment `password_wo_version` in `terraform.tfvars` and re-apply:

```hcl
password_wo_version = 2
```

> Do not force-replace `random_password.master` on its own (`terraform apply -replace`, `taint`) as a way to rotate. That regenerates the password in state and Key Vault, but because `administrator_password_wo` is write-only and the version is unchanged, the server never receives it — leaving Key Vault holding a password the database rejects. Always rotate by incrementing the version.

```bash
terraform apply
terraform output -raw helm_values  # copy new password into values.yaml
helm upgrade qualytics qualytics/qualytics --namespace qualytics -f values.yaml
```

`password_wo_version` is a keeper on the generated password, so a single apply regenerates it, sends it to the server, and writes a new Key Vault secret version.

## Retrieve Credentials from Key Vault

```bash
az keyvault secret show \
  --vault-name "$(terraform output -raw key_vault_name)" \
  --name "$(terraform output -raw key_vault_secret_name)" \
  --query value -o tsv | jq .
```

## Teardown

`deletion_protection` defaults to `true`. Azure has no deletion-protection setting for Flexible Server, so the module enforces it in Terraform: a guard resource that Terraform always destroys first fails while protection is on, which stops `terraform destroy` — and any change that would replace the server — before anything is deleted. The guard reads the value stored at the last apply, so clear it with an apply before destroying:

```bash
# 1. Disable deletion protection
terraform apply -var="deletion_protection=false"

# 2. Destroy
terraform destroy
```

A blocked run fails with `deletion_protection is true - apply with deletion_protection=false before destroying or replacing the server`. Nothing has been deleted at that point.

The guard runs a one-line `local-exec` command (`echo … && exit 1`), which works in both `sh` and Windows `cmd`. It protects only against Terraform; deleting the server in the portal or with `az` is not blocked.

Deleting the server deletes its data. Export it first (`pg_dump`) if you need it afterwards.

Destroy this module before `terraform/azure/cluster`: the delegated subnet lives in the cluster VNet, and the VNet cannot be deleted while it has subnets.

The Key Vault and its secret are purged on destroy rather than left soft-deleted, so redeploying with the same names does not collide.
