# Usage

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
| [aws_rds_cluster_instance.replica](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_instance) | resource |
| [terraform_remote_state.rds_cluster](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| apply\_immediately | When true, reader modifications apply immediately instead of waiting for the maintenance window. Default false (AWS-recommended posture; prevents accidental reader reboots from benign changes). | `bool` | `false` | no |
| cluster\_identifier | Identifier of the existing Aurora cluster the readers attach to (the cluster module's var.identifier\_prefix). Used both to compose the cluster remote-state key and to attach each reader via cluster\_identifier. | `string` | n/a | yes |
| identifier\_prefix | Stable prefix for each reader instance identifier. Each reader is named <identifier\_prefix>-replica-<key>. Must satisfy the AWS RDS identifier shape (lowercase, starts with a letter); keep it short enough that the composed identifier stays within 63 chars (guarded by a precondition). | `string` | n/a | yes |
| region | AWS region for the reader instances and for the S3 backend hosting the cluster module's remote state. | `string` | n/a | yes |
| remote\_state\_bucket | S3 bucket holding the cluster module's terraform state. This module reads <region>/rds/cluster/<cluster\_identifier>/terraform.tfstate for the cluster's outputs (DESIGN-0014 / ADR-0001 — remote-state composition). | `string` | n/a | yes |
| replicas | Map of reader instances to create, keyed by a short suffix that composes the reader identifier (<identifier\_prefix>-replica-<key>). Empty map = zero readers. Each value is a hybrid object: required instance\_class plus optional tuning attributes (availability\_zone, promotion\_tier [default 15 — below the writer's tier 0], performance\_insights\_enabled, monitoring\_interval + monitoring\_role\_arn, auto\_minor\_version\_upgrade, publicly\_accessible). Engine, engine version, subnet group, and parameter group are inherited from the cluster remote state — not settable per reader. | ```map(object({ instance_class = string availability_zone = optional(string) promotion_tier = optional(number, 15) performance_insights_enabled = optional(bool, false) monitoring_interval = optional(number, 0) monitoring_role_arn = optional(string) auto_minor_version_upgrade = optional(bool, true) publicly_accessible = optional(bool, false) }))``` | n/a | yes |
| tags | AWS resource tags applied to every reader instance in the module. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| replica\_endpoints | Map of per-reader endpoint hostnames keyed as var.replicas. Connect here to pin read traffic to a specific reader; use the cluster's reader\_endpoint for load-balanced reads across all readers. |
| replica\_identifiers | Map of reader instance identifiers keyed as var.replicas (key => <identifier\_prefix>-replica-<key>). Useful for AWS CLI / SDK operations targeting a specific reader (e.g., reboot-db-instance). |
<!-- END_TF_DOCS -->
