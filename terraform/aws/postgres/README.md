# Aurora PostgreSQL — Reference

See [`../README.md`](../README.md) for the full deployment walkthrough.

## What This Creates

| Resource | Description |
|---|---|
| Security group | Allows inbound PostgreSQL (5432) from within the VPC |
| Secrets Manager secret | Stores database credentials as a structured JSON object |
| Aurora PostgreSQL cluster | `aurora-postgresql` engine, encrypted storage, CloudWatch log export |
| Aurora instance(s) | One writer by default; set `instances = { 1 = {}, 2 = {} }` for a read replica |

## Required IAM Permissions

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
    "secretsmanager:TagResource"
  ],
  "Resource": "*"
}
```

## Inputs

| Name | Description | Default |
|---|---|---|
| `aws_region` | AWS region — must match `terraform/aws/cluster` | `us-east-1` |
| `cluster_name` | Name prefix — must match `terraform/aws/cluster` | `qualytics` |
| `tfstate_bucket` | S3 bucket used as Terraform state backend — must match `terraform/aws/cluster` | required |
| `database_name` | Initial database name | `surveillance_hub` |
| `administrator_login` | Master username | `postgres` |
| `postgresql_version` | Aurora PostgreSQL engine version | `17.4` |
| `instance_class` | Aurora instance type | `db.r8g.large` |
| `instances` | Map of instance configurations | `{ 1 = {} }` |
| `backup_retention_period` | Days to retain backups | `7` |
| `preferred_backup_window` | Daily backup window (UTC) | `03:00-04:00` |
| `apply_immediately` | Apply changes immediately vs maintenance window | `false` |
| `deletion_protection` | Prevent accidental deletion | `true` |
| `skip_final_snapshot` | Skip final snapshot on destroy | `false` |
| `master_password_wo_version` | Increment to rotate the password | `1` |
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
