<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |
| aws | ~> 6.2 |

## Providers

| Name | Version |
| ---- | ------- |
| terraform | n/a |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| core | ../internal/core | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [terraform_remote_state.access_logs](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| abort\_incomplete\_multipart\_days | Days after initiation before an incomplete multipart upload is aborted (baseline hygiene rule). | `number` | `7` | no |
| access\_logging | Server-access-logging tri-state. Default {} = look the fleet sink up at the reserved ADR-0020 key and log to it. target\_bucket set = log to that explicit sink (no remote-state read). enabled = false = no logging (a deliberately log-less stack). prefix null = "<this bucket's composed name>/". | ```object({ enabled = optional(bool, true) target_bucket = optional(string) prefix = optional(string) })``` | `{}` | no |
| account\_id | 12-digit AWS account ID — composed into the bucket name and into the remote-state assume\_role role\_arn. | `string` | n/a | yes |
| account\_name | Terragrunt account name — the <account\_name> prefix of the reserved access-logs remote-state key this module composes (<account\_name>/<region>/s3/access-logs/terraform.tfstate). | `string` | n/a | yes |
| additional\_policy\_statements | Operator bucket-policy statements, appended additively after the baseline denies (DESIGN-0019 OQ 4b — these ADD grants/denies; they can never shadow or remove the baseline, and the reserved sids are rejected at plan by the core). resource\_suffixes are relative to the bucket ARN ("" = the bucket, "/*" = objects). | ```list(object({ sid = string effect = optional(string, "Allow") principals = optional(map(list(string)), {}) actions = list(string) resource_suffixes = optional(list(string), ["", "/*"]) conditions = optional(list(object({ test = string variable = string values = list(string) })), []) }))``` | `[]` | no |
| allowed\_vpc\_endpoint\_ids | Opt-in VPCE-only restriction (INV-0009 OQ 6): non-empty adds the DenyOutsideVpce statement. CAUTION: locks out console and any non-VPCE access path. Default [] = no restriction. | `list(string)` | `[]` | no |
| deploy\_role\_name | Name of the IAM role Terraform assumes to read the remote-state bucket cross-account. Composed into the assume\_role role\_arn with account\_id. | `string` | n/a | yes |
| force\_destroy | Allow destroy to delete a non-empty bucket. Off by default — data loss is opt-in; test fixtures set it true for teardown. | `bool` | `false` | no |
| kms\_key\_arn | Customer-managed KMS key for SSE-KMS, or null (default) for the AWS-managed aws/s3 key. A CMK is required when cross-account consumers must decrypt — the aws/s3 key cannot be policy-edited. | `string` | `null` | no |
| name | Logical bucket name. Composed into the real bucket name as <name>-<account\_id>-<region> (plus the optional shard prefix). Lowercase alphanumeric + hyphens, 3-37 chars, must start/end alphanumeric. | `string` | n/a | yes |
| name\_override | Escape hatch: use this exact bucket name verbatim, skipping <name>-<account\_id>-<region> composition (externally-dictated names). | `string` | `null` | no |
| region | AWS region — composed into the bucket name and the reserved access-logs remote-state key. | `string` | n/a | yes |
| remote\_state\_bucket | S3 bucket holding the fleet's terraform state. The default access-logging path reads the reserved sink key from it (ADR-0020). | `string` | n/a | yes |
| remote\_state\_bucket\_region | Region of the remote-state bucket itself (may differ from var.region — the state bucket is fleet-central). | `string` | n/a | yes |
| shard\_prefix\_enabled | Opt-in: prepend a stable 5-character random lowercase-alphanumeric prefix to the composed bucket name for key-distribution/sharding. Toggling this after creation renames and therefore REPLACES the bucket. | `bool` | `false` | no |
| tags | Tags applied to every taggable resource in the module. | `map(string)` | `{}` | no |
| versioning\_enabled | Enable bucket versioning. Off by default — an explicit operator decision (INV-0009 F2). | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| bucket\_arn | The bucket's ARN. |
| bucket\_id | The bucket's ID (its name, as the provider returns it). |
| bucket\_name | The bucket's final composed name. |
| bucket\_policy\_json | The composed bucket policy (baseline denies + opt-in VPCE + additional\_policy\_statements) — re-exported so plan suites can assert the additive merge. |
| logging\_prefix | Resolved server-access-logging prefix, or null when logging is off. |
| logging\_target | Resolved server-access-logging target bucket (the looked-up fleet sink, the explicit override, or null when disabled) — the plan suites' window on the tri-state resolution. |
| security\_baseline | The composed security baseline, re-exported verbatim from the internal core — pinned by this module's security\_baseline.tftest.hcl (the family's byte-identical copy, Phase-5 diff guard). |
<!-- END_TF_DOCS -->