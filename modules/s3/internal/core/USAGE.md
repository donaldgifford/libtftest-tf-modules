<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |
| aws | ~> 6.2 |
| random | ~> 3.7 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.2 |
| random | ~> 3.7 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_object_lock_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_object_lock_configuration) | resource |
| [aws_s3_bucket_ownership_controls.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [random_string.shard_prefix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [aws_iam_policy_document.bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| abort\_incomplete\_multipart\_days | Days after initiation before an incomplete multipart upload is aborted (baseline hygiene rule — abandoned MPUs accrue invisible storage cost). | `number` | `7` | no |
| account\_id | 12-digit AWS account ID, composed into the bucket name for global uniqueness + provenance. Terragrunt-injected in production; from the shared var-file in tests. | `string` | n/a | yes |
| allowed\_vpc\_endpoint\_ids | Opt-in VPCE-only restriction (INV-0009 OQ 6): non-empty adds a deny-unless-aws:SourceVpce-in-list statement (reserved sid DenyOutsideVpce). CAUTION: locks out console and any non-VPCE access path — including the deployer role unless the deploy path rides a listed endpoint. Default [] = no restriction. | `list(string)` | `[]` | no |
| encryption | Server-side encryption. mode "kms" (default) = SSE-KMS with the AWS-managed aws/s3 key + bucket key, or a CMK via kms\_key\_arn (required for cross-account consumers — the aws/s3 key cannot be policy-edited). mode "s3" = SSE-S3/AES256 (the access-logs sink only — log delivery does not write to KMS targets). kms\_key\_arn with mode "s3" fails at plan. | ```object({ mode = optional(string, "kms") kms_key_arn = optional(string) })``` | `{}` | no |
| extra\_lifecycle\_rules | Additional lifecycle rules appended after the baseline MPU-abort rule (e.g. the access-logs sink's retention expiration; a staging-prefix expiry). prefix null = whole bucket. transitions/noncurrent\_version\_transitions tier objects across storage classes (DESIGN-0022); per-rule day ordering (transitions before expiration) is left to the S3 API. | ```list(object({ id = string enabled = optional(bool, true) prefix = optional(string) expiration_days = optional(number) noncurrent_version_expiration_days = optional(number) transitions = optional(list(object({ days = number storage_class = string })), []) noncurrent_version_transitions = optional(list(object({ noncurrent_days = number storage_class = string })), []) }))``` | `[]` | no |
| force\_destroy | Allow destroy to delete a non-empty bucket. Off by default — the baseline treats data loss as opt-in; test fixtures set it true for teardown. | `bool` | `false` | no |
| internal\_policy\_statements | Purpose-module statement injection (DESIGN-0019 OQ 4b — additive-only; carries any operator additional\_policy\_statements the purpose module passes through). Statements append after the baseline denies and can never shadow them: the reserved sids (DenyInsecureTransport, DenyOldTls, DenyOutsideVpce) are rejected at plan. resource\_suffixes are relative to the bucket ARN ("" = the bucket, "/*" = objects) — an input cannot reference this module's own bucket\_arn output. | ```list(object({ sid = string effect = optional(string, "Allow") principals = optional(map(list(string)), {}) actions = list(string) resource_suffixes = optional(list(string), ["", "/*"]) conditions = optional(list(object({ test = string variable = string values = list(string) })), []) }))``` | `[]` | no |
| logging | Pre-resolved server-access-logging wiring, or null for no logging. The tri-state (lookup / override / disabled) lives in the purpose modules — they pass the resolved target here. prefix null defaults to "<this bucket's final composed name>/" (resolved in the core; the shard prefix is unknown until apply). | ```object({ target_bucket = string prefix = optional(string) })``` | `null` | no |
| name | Logical bucket name. Composed into the real bucket name as <name>-<account\_id>-<region> (plus the optional shard prefix). Lowercase alphanumeric + hyphens, 3-37 chars, must start/end alphanumeric — the length cap leaves room for the composed suffix within S3's 63-char limit. | `string` | n/a | yes |
| name\_override | Escape hatch: use this exact bucket name verbatim, skipping <name>-<account\_id>-<region> composition (externally-dictated names). The composed-name length/charset precondition still applies to the override. | `string` | `null` | no |
| object\_lock | Purpose-module-only Object Lock wiring (DESIGN-0022 — never exposed on bucket/events-bucket). enabled is CREATE-TIME: toggling it on an existing bucket REPLACES the bucket. Requires versioning\_enabled = true. days xor years sets the default retention; both null = lock enabled with per-object-only retention. | ```object({ enabled = optional(bool, false) mode = optional(string, "COMPLIANCE") days = optional(number) years = optional(number) })``` | `{}` | no |
| region | AWS region, composed into the bucket name for global uniqueness + provenance. Terragrunt-injected in production; from the shared var-file in tests. | `string` | n/a | yes |
| shard\_prefix\_enabled | Opt-in: prepend a stable 5-character random lowercase-alphanumeric prefix to the composed bucket name (<shard>-<name>-<account\_id>-<region>) for key-distribution/sharding. Toggling this after creation renames and therefore REPLACES the bucket. | `bool` | `false` | no |
| tags | Tags applied to every taggable resource in the module. | `map(string)` | `{}` | no |
| versioning\_enabled | Enable bucket versioning. Off by default — an explicit operator decision (INV-0009 F2; cost + per-stack opt-in durability, noted against the CIS default-on nudge). | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| bucket\_arn | The bucket's ARN. |
| bucket\_id | The bucket's ID (its name, as the provider returns it). |
| bucket\_name | The bucket's final name — composed <shard->-<name>-<account\_id>-<region> or the name\_override verbatim. |
| bucket\_policy\_json | The composed bucket policy document (baseline denies + opt-in VPCE + injected statements) — assertable via jsondecode in plan suites. |
| lifecycle\_rule\_ids | Ids of every lifecycle rule on the bucket, in order (the baseline MPU-abort rule first, then extra\_lifecycle\_rules) — lets purpose-module plan suites pin their rule wiring without reaching into child resources. |
| logging\_prefix | Resolved server-access-logging prefix (caller value or the '<composed-name>/' default), or null when logging is off. |
| logging\_target | Resolved server-access-logging target bucket, or null when logging is off. |
| object\_lock | Default-retention facts derived from the object-lock configuration resource attributes (DESIGN-0022 OQ 7a — rides its own output so the shared security\_baseline shape is untouched), or null when no default retention is configured. The evidence purpose module re-exports this verbatim; like security\_baseline, it exists because purpose-module suites cannot address the core's resources. |
| security\_baseline | The composed security baseline, derived from actual resource attributes — re-exported verbatim by every purpose module and pinned by the shared security\_baseline.tftest.hcl (DESIGN-0019). |
<!-- END_TF_DOCS -->