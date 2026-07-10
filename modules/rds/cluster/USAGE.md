# Usage

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |
| aws | ~> 6.2 |

## Providers

No providers.

## Modules

No modules.

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| allowed\_consumer\_sg\_ids | Security group IDs whose members may reach the cluster on the engine's default port. Empty list (default) leaves the cluster reachable from nowhere — operators add ingress deliberately. | `list(string)` | `[]` | no |
| apply\_immediately | When true, modifications apply immediately instead of waiting for the maintenance window. Default false (AWS-recommended posture; prevents accidental cluster reboots from benign tag/parameter changes). | `bool` | `false` | no |
| auto\_minor\_version\_upgrade | When true (default), AWS applies engine-minor upgrades automatically during the maintenance window. Engine-major upgrades remain explicit operator PRs (bumping var.engine\_version). | `bool` | `true` | no |
| backtrack\_window | Aurora MySQL Backtrack target window in seconds (0 = disabled, default). Aurora-MySQL-only — a precondition on the cluster rejects non-zero values for aurora-postgresql (DESIGN-0013 Q4). Max 259200 (72h). | `number` | `0` | no |
| backup\_retention\_period | Days to retain automated backups. Range: 1 - 35. Default 7 (matches AWS RDS default). | `number` | `7` | no |
| database\_name | Optional initial database created on cluster startup. Null (default) leaves the cluster without an initial database; consumers create their schemas via Flyway/Liquibase/Atlas (per DESIGN-0007 Non-Goals — module manages infrastructure, not schema). | `string` | `null` | no |
| deletion\_protection | When true (default), the cluster cannot be destroyed via the AWS API until this flag is flipped to false in a deliberate operator plan. Matches the org-registry module's safety posture. | `bool` | `true` | no |
| enabled\_cloudwatch\_logs\_exports | List of log types to export to CloudWatch Logs. Default [] (off) — log exports cost CloudWatch ingestion and the right set is engine-specific (e.g. ["postgresql"] for aurora-postgresql; ["audit","error","general","slowquery"] for aurora-mysql). (DESIGN-0013 Q6.) | `list(string)` | `[]` | no |
| engine | Aurora engine: 'aurora-postgresql' or 'aurora-mysql'. The module rejects non-Aurora engines (single-instance postgres/mysql belong to modules/rds/instance). | `string` | n/a | yes |
| engine\_version | Optional engine version pin (e.g. '16', '16.4', '8.0'). When null, AWS picks the engine's default at apply time and the parameter family lookup falls back to the default major map in locals.tf (per IMPL-0007 Q3). | `string` | `null` | no |
| enhanced\_monitoring\_interval | Seconds between Enhanced Monitoring data points (1, 5, 10, 15, 30, 60). Default 0 (disabled, per IMPL-0007 Q6). Setting > 0 requires var.enhanced\_monitoring\_role\_arn. | `number` | `0` | no |
| enhanced\_monitoring\_role\_arn | IAM role ARN granting RDS permission to send Enhanced Monitoring metrics to CloudWatch. Caller-supplied — the module does NOT provision this role (per IMPL-0007 Q6 / module-boundary policy). Required when enhanced\_monitoring\_interval > 0. | `string` | `null` | no |
| final\_snapshot\_identifier | Snapshot identifier captured at cluster destroy time. Required (non-null) when skip\_final\_snapshot = false — enforced via a precondition on the cluster resource (per IMPL-0007 Q9). Supply at destroy time via `-var 'final_snapshot_identifier=...'`. | `string` | `null` | no |
| iam\_database\_authentication\_enabled | Opt-in IAM database authentication. When true, consumers obtain a connection token via `aws rds generate-db-auth-token` (composable with the SG ingress gate — limits authentication, not reachability). | `bool` | `false` | no |
| identifier\_prefix | Stable cluster identifier (also used for the subnet group, security group, KMS alias, and parameter group name prefixes). Must satisfy AWS RDS identifier shape: lowercase, 1-63 chars, starts with a letter, ends with letter or digit, hyphens permitted internally. | `string` | n/a | yes |
| instance\_class | Aurora instance class for the writer (e.g. 'db.r6g.large' for prod, 'db.t4g.medium' for dev). Required with no default — sizing is workload- and cost-specific (DESIGN-0013 Q2). NOT 'db.serverless' (that is the modules/rds/serverless module). | `string` | n/a | yes |
| kms\_key\_arn | Optional caller-supplied KMS key ARN for cluster storage encryption + master user secret encryption. When null (default), the module creates a dedicated key + alias internally. Same key is used for both encryptions (per IMPL-0007 Q12). | `string` | `null` | no |
| manage\_master\_user\_password | When true (default), AWS provisions and rotates the master user password in Secrets Manager. The secret ARN is emitted via the master\_user\_secret\_arn output. Opt-out is documented as an escape hatch for operators migrating from a pre-existing secret. | `bool` | `true` | no |
| master\_username | Master user name created on the cluster. Default 'admin' for both engines (per IMPL-0007 Q4 — single default, not per-engine; override per cluster if you prefer 'postgres' or another value). | `string` | `"admin"` | no |
| parameter\_family | Optional parameter group family override (e.g. 'aurora-postgresql16'). When null (default), resolved from var.engine + var.engine\_version via the static parameter\_family\_map in locals.tf (per DESIGN-0007 Q3 / IMPL-0007 Q3). | `string` | `null` | no |
| performance\_insights\_enabled | Opt-in Performance Insights on the writer instance. Default false (per IMPL-0007 Q6 — conservative on cost; caller opts in). When true, PI uses local.kms\_key\_arn for encryption. | `bool` | `false` | no |
| preferred\_backup\_window | Daily UTC window during which automated backups occur. Format: HH:MM-HH:MM. Default 02:00-03:00 (off-peak in most US timezones). | `string` | `"02:00-03:00"` | no |
| preferred\_maintenance\_window | Weekly UTC window during which AWS applies maintenance + engine-minor upgrades. Format: ddd:HH:MM-ddd:HH:MM. Default sun:04:00-sun:05:00. | `string` | `"sun:04:00-sun:05:00"` | no |
| promotion\_tier | Failover priority tier for the writer instance (0-15; lower = higher priority). Default 0 — the writer is the highest-priority failover target. The read-replica module's readers default to tier 15 so they never outrank the writer (DESIGN-0013 Q1 / DESIGN-0014 Q2). | `number` | `0` | no |
| publicly\_accessible | When true, the cluster instance gets a public DNS endpoint. Default false (private-subnet-only). | `bool` | `false` | no |
| region | AWS region for the cluster + the S3 backend hosting the VPC remote state. | `string` | n/a | yes |
| remote\_state\_bucket | S3 bucket holding the VPC stack's terraform state. The module reads <region>/vpc/<vpc\_name>/terraform.tfstate for vpc\_id + private\_subnet\_ids (per IMPL-0007 Q1). | `string` | n/a | yes |
| skip\_final\_snapshot | When true, skips the final snapshot at cluster destroy. Default false — operators MUST supply var.final\_snapshot\_identifier at destroy time unless they flip this to true. | `bool` | `false` | no |
| storage\_type | Optional Aurora storage type. Null (default) = Aurora Standard; 'aurora' is the explicit Standard value; 'aurora-iopt1' is I/O-Optimized (no per-request I/O charges, ~30% higher instance/storage rate — for cost-conscious high-I/O clusters). (DESIGN-0013 Q3.) | `string` | `null` | no |
| tags | AWS resource tags applied to every taggable resource in the module (cluster, instance, subnet group, security group, parameter groups, KMS key). | `map(string)` | `{}` | no |
| vpc\_name | VPC name used to compose the remote-state key. Must match the VPC stack's identifier. | `string` | n/a | yes |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
