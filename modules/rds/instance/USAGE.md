<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |
| aws | ~> 6.2 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.54.0 |
| terraform | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_db_subnet_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.consumer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [terraform_remote_state.vpc](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| allocated\_storage | Allocated storage in GiB for the instance. Required with no default — the right floor is workload-specific. Minimum 20 GiB (AWS RDS floor for the supported engines). | `number` | n/a | yes |
| allowed\_consumer\_sg\_ids | Security group IDs whose members may reach the instance on the resolved port. Empty list (default) leaves the instance reachable from nowhere — operators add ingress deliberately. | `list(string)` | `[]` | no |
| apply\_immediately | When true, modifications apply immediately instead of waiting for the maintenance window. Default false (AWS-recommended posture; prevents accidental instance reboots from benign tag/parameter changes). | `bool` | `false` | no |
| auto\_minor\_version\_upgrade | When true (default), AWS applies engine-minor upgrades automatically during the maintenance window. Engine-major upgrades remain explicit operator PRs (bumping var.engine\_version). | `bool` | `true` | no |
| backup\_retention\_period | Days to retain automated backups. Range: 1 - 35. Default 7 (matches AWS RDS default). | `number` | `7` | no |
| ca\_cert\_identifier | Optional RDS CA certificate identifier for the instance's server certificate (e.g. 'rds-ca-rsa2048-g1'). Null (default) uses the AWS-account default CA (DESIGN-0012 Q6). | `string` | `null` | no |
| database\_name | Optional initial database created on instance startup. Null (default) leaves the instance without an initial database; consumers create their schemas via Flyway/Liquibase/Atlas (per DESIGN-0007 Non-Goals — module manages infrastructure, not schema). | `string` | `null` | no |
| db\_port | Optional TCP port override. Null (default) uses the engine's default port (5432 postgres, 3306 mysql) resolved in locals.tf. The SG ingress rules follow the resolved port. | `number` | `null` | no |
| deletion\_protection | When true (default), the instance cannot be destroyed via the AWS API until this flag is flipped to false in a deliberate operator plan. Matches the org-registry module's safety posture. | `bool` | `true` | no |
| engine | Non-Aurora RDS engine: 'postgres' or 'mysql'. The module rejects Aurora engines (those belong to the modules/rds/serverless and modules/rds/cluster modules). | `string` | n/a | yes |
| engine\_version | Optional engine version pin (e.g. '18', '16.4', '8.0'). When null, AWS picks the engine's default at apply time and the parameter family lookup falls back to the default major map in locals.tf (per DESIGN-0012 Q8). | `string` | `null` | no |
| enhanced\_monitoring\_interval | Seconds between Enhanced Monitoring data points (1, 5, 10, 15, 30, 60). Default 0 (disabled, per IMPL-0007 Q6). Setting > 0 requires var.enhanced\_monitoring\_role\_arn. | `number` | `0` | no |
| enhanced\_monitoring\_role\_arn | IAM role ARN granting RDS permission to send Enhanced Monitoring metrics to CloudWatch. Caller-supplied — the module does NOT provision this role (per IMPL-0007 Q6 / module-boundary policy). Required when enhanced\_monitoring\_interval > 0. | `string` | `null` | no |
| final\_snapshot\_identifier | Snapshot identifier captured at instance destroy time. Required (non-null) when skip\_final\_snapshot = false — enforced via a precondition on the instance (per IMPL-0007 Q9). Supply at destroy time via `-var 'final_snapshot_identifier=...'`. | `string` | `null` | no |
| iam\_database\_authentication\_enabled | Opt-in IAM database authentication. When true, consumers obtain a connection token via `aws rds generate-db-auth-token` (composable with the SG ingress gate — limits authentication, not reachability). | `bool` | `false` | no |
| identifier\_prefix | Stable instance identifier (also used for the subnet group, security group, KMS alias, and parameter group name prefixes). Must satisfy AWS RDS identifier shape: lowercase, 1-63 chars, starts with a letter, ends with letter or digit, hyphens permitted internally. | `string` | n/a | yes |
| instance\_class | RDS instance class (e.g. 'db.t4g.medium' for dev, 'db.r6g.large' for prod). Required with no default — sizing is workload- and cost-specific (DESIGN-0012 §Input surface). | `string` | n/a | yes |
| iops | Provisioned IOPS for the storage volume. Null (default) uses the storage type's baseline. Required (non-null) when storage\_type = 'io2' (enforced via a precondition); also valid for gp3 above the free-IOPS baseline. | `number` | `null` | no |
| kms\_key\_arn | Optional caller-supplied KMS key ARN for instance storage encryption + master user secret encryption. When null (default), the module creates a dedicated key + alias internally. Same key is used for both encryptions (per IMPL-0007 Q12). | `string` | `null` | no |
| manage\_master\_user\_password | When true (default), AWS provisions and rotates the master user password in Secrets Manager. The secret ARN is emitted via the master\_user\_secret\_arn output. Opt-out is documented as an escape hatch for operators migrating from a pre-existing secret. | `bool` | `true` | no |
| master\_username | Master user name created on the instance. Default 'admin' for both engines (per IMPL-0007 Q4 — single default, not per-engine; override per instance if you prefer 'postgres' or another value). | `string` | `"admin"` | no |
| max\_allocated\_storage | Optional upper bound (GiB) for RDS storage autoscaling. Null (default) disables autoscaling — storage stays at allocated\_storage. When set, must be >= allocated\_storage (enforced via a precondition on the instance). The AWS provider suppresses the allocated\_storage diff once autoscaling grows the volume, so no ignore\_changes is needed (DESIGN-0012 Q3 / IMPL-0011 Phase 6). | `number` | `null` | no |
| multi\_az | When true, RDS provisions a synchronous standby in a second AZ for HA. Default false (single-AZ; matches DESIGN-0007's cost posture — operators opt into HA per instance, DESIGN-0012 Q4). | `bool` | `false` | no |
| parameter\_family | Optional parameter group family override (e.g. 'postgres18'). When null (default), resolved from var.engine + var.engine\_version via the static parameter\_family\_map in locals.tf (per DESIGN-0012 §Parameter family). | `string` | `null` | no |
| performance\_insights\_enabled | Opt-in Performance Insights on the instance. Default false (per IMPL-0007 Q6 — conservative on cost; caller opts in). When true, PI uses local.kms\_key\_arn for encryption. | `bool` | `false` | no |
| preferred\_backup\_window | Daily UTC window during which automated backups occur. Format: HH:MM-HH:MM. Default 02:00-03:00 (off-peak in most US timezones). | `string` | `"02:00-03:00"` | no |
| preferred\_maintenance\_window | Weekly UTC window during which AWS applies maintenance + engine-minor upgrades. Format: ddd:HH:MM-ddd:HH:MM. Default sun:04:00-sun:05:00. | `string` | `"sun:04:00-sun:05:00"` | no |
| publicly\_accessible | When true, the instance gets a public DNS endpoint. Default false (private-subnet-only). | `bool` | `false` | no |
| region | AWS region for the instance + the S3 backend hosting the VPC remote state. | `string` | n/a | yes |
| remote\_state\_bucket | S3 bucket holding the VPC stack's terraform state. The module reads <region>/vpc/<vpc\_name>/terraform.tfstate for vpc\_id + private\_subnet\_ids (per IMPL-0007 Q1). | `string` | n/a | yes |
| skip\_final\_snapshot | When true, skips the final snapshot at instance destroy. Default false — operators MUST supply var.final\_snapshot\_identifier at destroy time unless they flip this to true. | `bool` | `false` | no |
| storage\_throughput | Storage throughput in MiB/s (gp3 only). Null (default) uses the gp3 baseline. AWS rejects this attribute for gp2/io2 — set it only alongside storage\_type = 'gp3'. | `number` | `null` | no |
| storage\_type | EBS storage type for the instance. Default 'gp3' (current-generation general-purpose SSD). 'gp2' is the previous generation; 'io2' is provisioned-IOPS (requires var.iops, enforced via a precondition). | `string` | `"gp3"` | no |
| tags | AWS resource tags applied to every taggable resource in the module (instance, subnet group, security group, parameter group, KMS key). | `map(string)` | `{}` | no |
| vpc\_name | VPC name used to compose the remote-state key. Must match the VPC stack's identifier. | `string` | n/a | yes |

## Outputs

No outputs.
<!-- END_TF_DOCS -->