<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |
| aws | ~> 6.2 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.46.0 |
| terraform | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_db_parameter_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_parameter_group) | resource |
| [aws_db_subnet_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_rds_cluster.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster) | resource |
| [aws_rds_cluster_instance.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_instance) | resource |
| [aws_rds_cluster_parameter_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_parameter_group) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.consumer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [terraform_remote_state.vpc](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| allowed\_consumer\_sg\_ids | Security group IDs whose members may reach the cluster on the engine's default port. Empty list (default) leaves the cluster reachable from nowhere — operators add ingress deliberately. | `list(string)` | `[]` | no |
| apply\_immediately | When true, modifications apply immediately instead of waiting for the maintenance window. Default false (AWS-recommended posture; prevents accidental cluster reboots from benign tag/parameter changes). | `bool` | `false` | no |
| auto\_minor\_version\_upgrade | When true (default), AWS applies engine-minor upgrades automatically during the maintenance window. Engine-major upgrades remain explicit operator PRs (bumping var.engine\_version). | `bool` | `true` | no |
| backup\_retention\_period | Days to retain automated backups. Range: 1 - 35. Default 7 (matches AWS RDS default). | `number` | `7` | no |
| database\_name | Optional initial database created on cluster startup. Null (default) leaves the cluster without an initial database; consumers create their schemas via Flyway/Liquibase/Atlas (per DESIGN-0007 Non-Goals — module manages infrastructure, not schema). | `string` | `null` | no |
| deletion\_protection | When true (default), the cluster cannot be destroyed via the AWS API until this flag is flipped to false in a deliberate operator plan. Matches the org-registry module's safety posture. | `bool` | `true` | no |
| engine | Aurora engine: 'aurora-postgresql' or 'aurora-mysql'. The module rejects non-Aurora engines (those belong to the future modules/rds/instance module). | `string` | n/a | yes |
| engine\_version | Optional engine version pin (e.g. '16', '16.4', '8.0'). When null, AWS picks the engine's default at apply time and the parameter family lookup falls back to the default major map in locals.tf (per IMPL-0007 Q3). | `string` | `null` | no |
| enhanced\_monitoring\_interval | Seconds between Enhanced Monitoring data points (1, 5, 10, 15, 30, 60). Default 0 (disabled, per IMPL-0007 Q6). Setting > 0 requires var.enhanced\_monitoring\_role\_arn. | `number` | `0` | no |
| enhanced\_monitoring\_role\_arn | IAM role ARN granting RDS permission to send Enhanced Monitoring metrics to CloudWatch. Caller-supplied — the module does NOT provision this role (per IMPL-0007 Q6 / module-boundary policy). Required when enhanced\_monitoring\_interval > 0. | `string` | `null` | no |
| final\_snapshot\_identifier | Snapshot identifier captured at cluster destroy time. Required (non-null) when skip\_final\_snapshot = false — enforced via a precondition on the cluster resource (per IMPL-0007 Q9). Supply at destroy time via `-var 'final_snapshot_identifier=...'`. | `string` | `null` | no |
| iam\_database\_authentication\_enabled | Opt-in IAM database authentication. When true, consumers obtain a connection token via `aws rds generate-db-auth-token` (composable with the SG ingress gate — limits authentication, not reachability). | `bool` | `false` | no |
| identifier\_prefix | Stable cluster identifier (also used for the subnet group, security group, KMS alias, and parameter group name prefixes). Must satisfy AWS RDS identifier shape: lowercase, 1-63 chars, starts with a letter, ends with letter or digit, hyphens permitted internally. | `string` | n/a | yes |
| kms\_key\_arn | Optional caller-supplied KMS key ARN for cluster storage encryption + master user secret encryption. When null (default), the module creates a dedicated key + alias internally. Same key is used for both encryptions (per IMPL-0007 Q12). | `string` | `null` | no |
| manage\_master\_user\_password | When true (default), AWS provisions and rotates the master user password in Secrets Manager. The secret ARN is emitted via the master\_user\_secret\_arn output. Opt-out is documented as an escape hatch for operators migrating from a pre-existing secret. | `bool` | `true` | no |
| master\_username | Master user name created on the cluster. Default 'admin' for both engines (per IMPL-0007 Q4 — single default, not per-engine; override per cluster if you prefer 'postgres' or another value). | `string` | `"admin"` | no |
| max\_acu | Maximum Aurora Capacity Units (ACUs) for the Serverless v2 scaling configuration. Range: 0.5 - 256. Suggested starting points: dev = 4; production starter = 16. Tune to your workload's peak load shape. min\_acu <= max\_acu is enforced via a precondition on the cluster resource. | `number` | n/a | yes |
| min\_acu | Minimum Aurora Capacity Units (ACUs) for the Serverless v2 scaling configuration. Range: 0.5 - 256. Suggested starting points: dev = 0.5; production starter = 0.5. Tune to your workload's load shape (load below this floor still costs min\_acu * $0.12/hour for Postgres in us-east-1). | `number` | n/a | yes |
| parameter\_family | Optional parameter group family override (e.g. 'aurora-postgresql16'). When null (default), resolved from var.engine + var.engine\_version via the static parameter\_family\_map in locals.tf (per DESIGN-0007 Q3 / IMPL-0007 Q3). | `string` | `null` | no |
| performance\_insights\_enabled | Opt-in Performance Insights on the cluster instance. Default false (per IMPL-0007 Q6 — conservative on cost; caller opts in). When true, PI uses local.kms\_key\_arn for encryption. | `bool` | `false` | no |
| preferred\_backup\_window | Daily UTC window during which automated backups occur. Format: HH:MM-HH:MM. Default 02:00-03:00 (off-peak in most US timezones). | `string` | `"02:00-03:00"` | no |
| preferred\_maintenance\_window | Weekly UTC window during which AWS applies maintenance + engine-minor upgrades. Format: ddd:HH:MM-ddd:HH:MM. Default sun:04:00-sun:05:00. | `string` | `"sun:04:00-sun:05:00"` | no |
| publicly\_accessible | When true, the cluster instance gets a public DNS endpoint. Default false (private-subnet-only). | `bool` | `false` | no |
| region | AWS region for the cluster + the S3 backend hosting the VPC remote state. | `string` | n/a | yes |
| remote\_state\_bucket | S3 bucket holding the VPC stack's terraform state. The module reads <region>/vpc/<vpc\_name>/terraform.tfstate for vpc\_id + private\_subnet\_ids (per IMPL-0007 Q1). | `string` | n/a | yes |
| skip\_final\_snapshot | When true, skips the final snapshot at cluster destroy. Default false — operators MUST supply var.final\_snapshot\_identifier at destroy time unless they flip this to true. | `bool` | `false` | no |
| tags | AWS resource tags applied to every taggable resource in the module (cluster, instance, subnet group, security group, parameter groups, KMS key). | `map(string)` | `{}` | no |
| vpc\_name | VPC name used to compose the remote-state key. Must match the VPC stack's identifier. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| cluster\_endpoint | Writer endpoint hostname for the cluster. Applications connect here for read+write workloads. |
| cluster\_identifier | The cluster's identifier (var.identifier\_prefix). Used by downstream modules to compose the remote-state key when consuming this cluster via data.terraform\_remote\_state. |
| cluster\_instance\_identifier | Identifier of the single Serverless v2 cluster instance. Useful for AWS CLI / SDK operations targeting the instance directly (e.g., reboot-db-instance). |
| cluster\_resource\_id | The cluster's immutable AWS-internal resource ID (cluster\_resource\_id). Used by IAM database authentication policies (the resource segment of the iam:dbuser ARN is keyed by this value, not cluster\_identifier). |
| db\_cluster\_parameter\_group\_name | Name of the cluster parameter group created for this cluster. The future read-replica module consumes this through remote state so replicas share the cluster's parameter family. |
| db\_parameter\_group\_name | Name of the instance parameter group attached to the Serverless v2 instance. |
| db\_subnet\_group\_name | Name of the DB subnet group created for this cluster. Read by sibling RDS modules that share the same subnet topology (the future read-replica module consumes this through remote state). |
| engine | Cluster engine (aurora-postgresql or aurora-mysql) — passthrough so downstream modules don't need to refer back to their own var.engine. |
| engine\_version\_actual | The engine version AWS actually applied. Important when var.engine\_version was null — this output exposes the AWS-default version chosen at apply time. |
| kms\_key\_arn | KMS key ARN encrypting cluster storage at rest + the master user secret. BYO ARN (when var.kms\_key\_arn was non-null) or module-managed key's ARN — resolved transparently via local.kms\_key\_arn. |
| master\_user\_secret\_arn | ARN of the AWS-managed Secrets Manager secret holding the master user password. Null when var.manage\_master\_user\_password = false (operators wire their own secret in that opt-out path). |
| port | TCP port the cluster accepts connections on (5432 for aurora-postgresql, 3306 for aurora-mysql). |
| reader\_endpoint | Reader endpoint hostname for the cluster. Aurora distributes read traffic across cluster instances; with a single instance, this resolves to the same endpoint as cluster\_endpoint. |
| security\_group\_id | Security group ID of the cluster's DB-tier SG. Consumers reference this when they add their own peering ingress rules outside the module's allowed\_consumer\_sg\_ids contract. |
<!-- END_TF_DOCS -->