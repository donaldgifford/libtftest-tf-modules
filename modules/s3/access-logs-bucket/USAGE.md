<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |

## Providers

No providers.

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| core | ../internal/core | n/a |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | 12-digit AWS account ID — composed into the bucket name AND the aws:SourceAccount condition of the log-delivery grant. Terragrunt-injected in production. | `string` | n/a | yes |
| force\_destroy | Allow destroy to delete the sink with logs still in it. Off by default; test fixtures set it true for teardown. | `bool` | `false` | no |
| log\_retention\_days | Days before delivered log objects expire (OQ 1a: default 90 — access logs are operational exhaust; unbounded growth is the real foot-gun). null disables expiration entirely (retain forever). | `number` | `90` | no |
| name | Logical bucket name, defaulting to "access-logs" (OQ 3a) so the per-region singleton is literally zero-configuration: bucket access-logs-<account\_id>-<region> at live stack path s3/access-logs. Override only for a non-default sink deployed at its own stack path. | `string` | `"access-logs"` | no |
| name\_override | Escape hatch: use this exact bucket name verbatim, skipping composition (externally-dictated names). | `string` | `null` | no |
| region | AWS region, composed into the bucket name. Terragrunt-injected in production. | `string` | n/a | yes |
| shard\_prefix\_enabled | Opt-in: prepend a stable 5-character random prefix to the composed bucket name (destructive to toggle after creation — the bucket is replaced). | `bool` | `false` | no |
| tags | Tags applied to every taggable resource. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| bucket\_arn | The sink's ARN (additive contract output). |
| bucket\_id | The sink's bucket ID (additive contract output). |
| bucket\_name | The sink's bucket name — THE contract output every family bucket's default access-logging lookup consumes (ADR-0020 key <account\_name>/<region>/s3/access-logs/terraform.tfstate). |
| bucket\_policy\_json | The composed bucket policy (baseline denies + the log-delivery grant) — re-exported so the plan suites can assert the grant's shape. |
| security\_baseline | The composed security baseline, re-exported verbatim from the internal core — pinned by this module's security\_baseline.tftest.hcl (F3 variant: AES256). |
<!-- END_TF_DOCS -->