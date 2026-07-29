# Aurora PostgreSQL — Reference

See [`../README.md`](../README.md) for the full deployment walkthrough.

## What This Creates

| Resource | Description |
|---|---|
| Security group | Allows inbound PostgreSQL (5432) from within the VPC |
| Secrets Manager secret | Stores database credentials as a structured JSON object |
| Aurora PostgreSQL cluster | `aurora-postgresql` engine, encrypted storage, CloudWatch log export |
| Aurora instance(s) | One writer by default; set `instances = { 1 = {}, 2 = {} }` for a read replica |

## IAM Permissions

Covers the resources this module manages. It is not a complete least-privilege policy —
Terraform's S3 state backend and provider bootstrap calls are not included (see
[`../README.md`](../README.md) Step 1).

```json
{
  "Effect": "Allow",
  "Action": [
    "rds:CreateDBCluster",
    "rds:CreateDBInstance",
    "rds:CreateDBSubnetGroup",
    "rds:DeleteDBCluster",
    "rds:DeleteDBInstance",
    "rds:DeleteDBSubnetGroup",
    "rds:DescribeDBClusters",
    "rds:DescribeDBInstances",
    "rds:DescribeDBSubnetGroups",
    "rds:ModifyDBCluster",
    "rds:ModifyDBInstance",
    "rds:AddTagsToResource",
    "rds:ListTagsForResource",
    "ec2:CreateSecurityGroup",
    "ec2:DeleteSecurityGroup",
    "ec2:AuthorizeSecurityGroupIngress",
    "ec2:AuthorizeSecurityGroupEgress",
    "ec2:RevokeSecurityGroupIngress",
    "ec2:RevokeSecurityGroupEgress",
    "ec2:DescribeSecurityGroups",
    "ec2:DescribeVpcs",
    "ec2:DescribeSubnets",
    "ec2:CreateTags",
    "secretsmanager:CreateSecret",
    "secretsmanager:DeleteSecret",
    "secretsmanager:DescribeSecret",
    "secretsmanager:GetSecretValue",
    "secretsmanager:PutSecretValue",
    "secretsmanager:GetResourcePolicy",
    "secretsmanager:TagResource",
    "secretsmanager:UntagResource",
    "rds:RemoveTagsFromResource",
    "logs:CreateLogGroup",
    "logs:DeleteLogGroup",
    "logs:DescribeLogGroups",
    "logs:PutRetentionPolicy",
    "logs:TagResource",
    "logs:ListTagsForResource",
    "logs:UntagResource"
  ],
  "Resource": "*"
}
```

Aurora also needs its service-linked role, which requires a separate statement:

```json
{
  "Effect": "Allow",
  "Action": "iam:CreateServiceLinkedRole",
  "Resource": "arn:aws:iam::*:role/aws-service-role/rds.amazonaws.com/AWSServiceRoleForRDS",
  "Condition": {
    "StringLike": { "iam:AWSServiceName": "rds.amazonaws.com" }
  }
}
```

`rds:CreateDBClusterSnapshot` is additionally required when destroying with
`skip_final_snapshot = false`. The `logs:*` actions are required because this module
creates and tags the CloudWatch log group itself rather than letting RDS create it.

## Inputs

| Name | Description | Default |
|---|---|---|
| `aws_region` | AWS region — must match `terraform/aws/cluster` | `us-east-1` |
| `cluster_name` | Name prefix — must match `terraform/aws/cluster` | `qualytics` |
| `tfstate_bucket` | S3 bucket used as Terraform state backend — must match `terraform/aws/cluster` | required |
| `tfstate_key` | S3 key of the cluster module's state file | `aws/cluster/terraform.tfstate` |
| `tfstate_region` | Region of the state bucket, when it differs from `aws_region` | `null` |
| `database_name` | Initial database name | `surveillance_hub` |
| `administrator_login` | Master username | `postgres` |
| `postgresql_version` | Aurora PostgreSQL engine version | `17.9` |
| `instance_class` | Aurora instance type | `db.r8g.large` |
| `instances` | Map of instance configurations | `{ 1 = {} }` |
| `backup_retention_period` | Days to retain backups | `7` |
| `preferred_backup_window` | Daily backup window (UTC) | `03:00-04:00` |
| `apply_immediately` | Apply changes immediately vs maintenance window | `false` |
| `deletion_protection` | Prevent accidental deletion | `true` |
| `skip_final_snapshot` | Skip final snapshot on destroy | `false` |
| `master_password_wo_version` | Increment to rotate the password | `1` |
| `log_retention_days` | CloudWatch Logs retention for the postgresql log group (0 = never expire) | `30` |
| `final_snapshot_identifier` | Override the generated final snapshot name | `null` |
| `default_tags` | Tags applied to all resources | see variables.tf |

## Outputs

| Name | Description | Sensitive |
|---|---|---|
| `db_host` | Aurora writer endpoint | No |
| `db_reader_endpoint` | Aurora reader endpoint | No |
| `db_port` | PostgreSQL port (5432) | No |
| `db_name` | Database name | No |
| `db_username` | Master username | Yes |
| `db_password` | Master password | Yes |
| `db_secret_arn` | Secrets Manager ARN | No |
| `cluster_id` | Aurora cluster identifier | No |
| `cluster_arn` | Aurora cluster ARN | No |
| `security_group_id` | Aurora security group ID | No |
| `helm_values` | Ready-to-paste Helm values block | Yes |

## Password Rotation (if required)

Increment `master_password_wo_version` in `terraform.tfvars` and re-apply:

```hcl
master_password_wo_version = 2
```

```bash
terraform apply
terraform output -raw helm_values  # copy new password into values.yaml
helm upgrade qualytics qualytics/qualytics --namespace qualytics -f values.yaml
```

`master_password_wo_version` is a keeper on the generated password, so a single apply
regenerates it, sends it to Aurora, and updates the Secrets Manager entry.

**Mind the timing.** `apply_immediately` defaults to `false`, so the password change may
be deferred to the next maintenance window — during which the old password still works
and the new one does not. Either run the rotation with
`-var="apply_immediately=true"`, or wait until the cluster leaves
`PendingModifiedValues` before running `helm upgrade`:

```bash
aws rds describe-db-clusters --db-cluster-identifier <cluster-name>-postgres \
  --query 'DBClusters[0].PendingModifiedValues'
```

## Retrieve Credentials from Secrets Manager

```bash
aws secretsmanager get-secret-value \
  --secret-id <cluster-name>-postgres-password \
  --query SecretString \
  --output text | jq .
```


## Teardown

Aurora clusters have deletion protection enabled by default (`deletion_protection = true`). To destroy:

```bash
# 1. Disable deletion protection
terraform apply -var="deletion_protection=false" -var="skip_final_snapshot=true"

# 2. Destroy
terraform destroy
```

Two things outlive the cluster:

- **Final snapshot.** With `skip_final_snapshot = false` a snapshot is retained after the
  cluster is gone and billed as storage. Delete it with
  `aws rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier <name>`, or leave
  it and rely on the generated unique suffix so the next teardown does not collide.
- **CloudWatch log group.** Terraform owns it, so `terraform destroy` removes it and its
  logs. Set `cloudwatch_log_group_skip_destroy = true` if the logs must be kept. Note
  that a pre-existing RDS-created log group causes `ResourceAlreadyExistsException` on
  apply — import or delete it first.

Aurora enables automatic minor version upgrades by default, so after AWS applies one a
later `terraform plan` may propose an `engine_version` downgrade. RDS rejects downgrades —
update `postgresql_version` to match the running version instead of applying the diff.
