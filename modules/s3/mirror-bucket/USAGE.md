<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |
| aws | ~> 6.2 |

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
| abort\_incomplete\_multipart\_days | Days after initiation before an incomplete multipart upload is aborted (baseline hygiene rule). | `number` | `7` | no |
| access\_log\_bucket | Server-access-logging target bucket name (the existing access-logs-bucket stack), or null (default) for no logging. Named explicitly — no fleet lookup, no bootstrapping order beyond applying the sink first. | `string` | `null` | no |
| access\_log\_prefix | Server-access-logging prefix, or null (default) for the core's "<composed-name>/" default (only the core knows the final name — the shard prefix is unknown until apply). | `string` | `null` | no |
| account\_id | 12-digit AWS account ID — composed into the bucket name. | `string` | n/a | yes |
| additional\_policy\_statements | Operator bucket-policy statements, appended additively after the baseline denies AND the mirror statements (DESIGN-0019 OQ 4b — these ADD grants/denies; they can never shadow the baseline or the mirror posture, and the reserved sids are rejected at plan by the core). resource\_suffixes are relative to the bucket ARN ("" = the bucket, "/*" = objects). | ```list(object({ sid = string effect = optional(string, "Allow") principals = optional(map(list(string)), {}) actions = list(string) resource_suffixes = optional(list(string), ["", "/*"]) conditions = optional(list(object({ test = string variable = string values = list(string) })), []) }))``` | `[]` | no |
| break\_glass\_principal\_arns | Break-glass exception to DenyObjectDeletion. Default [] = absolute deny (content mistakes fix forward with new versions; a true purge is a reviewed PR that adds a principal, applies, deletes, and reverts). | `list(string)` | `[]` | no |
| cross\_account\_publisher\_principal\_arns | Cross-account publisher principals (the out-of-band GitHub OIDC role). Default [] = no statement rendered — same-account publishing needs no bucket-policy grant. Non-empty injects AllowCrossAccountPublisherWrite (PutObject + GetObject + ListBucket on this bucket, no deletes — sluice DESIGN-0002's write-only-no-delete publisher permissions). | `list(string)` | `[]` | no |
| enable\_object\_lock | Opt-in Object Lock (CREATE-TIME: toggling it on an existing bucket REPLACES the bucket). Default false. | `bool` | `false` | no |
| enable\_policy\_mutation\_guard | Render DenyPolicyMutation (default true). The off-switch is the reviewed-PR escape hatch for a mis-scoped admin list, which with an always-on deny would strand the stack permanently (OQ 6a). | `bool` | `true` | no |
| force\_destroy | Allow destroy to delete a non-empty bucket. Off by default — data loss is opt-in; test fixtures set it true for teardown. | `bool` | `false` | no |
| name | Logical bucket name. Composed into the real bucket name as <name>-<account\_id>-<region> (plus the optional shard prefix). Lowercase alphanumeric + hyphens, 3-37 chars, must start/end alphanumeric. The sluice-dictated mirror name arrives via name\_override instead. | `string` | n/a | yes |
| name\_override | Escape hatch: use this exact bucket name verbatim, skipping <name>-<account\_id>-<region> composition. The sluice-dictated mirror name arrives here (externally-dictated names are exactly this hatch's use case). | `string` | `null` | no |
| noncurrent\_version\_ia\_days | Days after becoming noncurrent before an object version transitions to STANDARD\_IA (the access-logs-bucket log\_retention\_days precedent: one number maps to one fixed-id core rule). Null (default) disables — no rule rendered. There is deliberately no expiration variable: expiry destroys the forensics record and breaks pinned installs. | `number` | `null` | no |
| object\_lock\_retention\_days | Object Lock default retention in days, mapped onto the core's object\_lock.days with mode pinned COMPLIANCE (the mirror's threat is quiet content mutation; GOVERNANCE's bypass is for lower-stakes tiers). Null (default) = no default retention. The core's retention-set-but-disabled coherence guard fails the plan if days are set without enable\_object\_lock = true. | `number` | `null` | no |
| policy\_admin\_principal\_arns | Admin exception to DenyPolicyMutation (required, non-empty — an empty admin list would strand the stack: nobody could ever amend the policy). Disable the guard itself via enable\_policy\_mutation\_guard. | `list(string)` | n/a | yes |
| region | AWS region — composed into the bucket name and the mirror\_url output. | `string` | n/a | yes |
| shard\_prefix\_enabled | Opt-in: prepend a stable 5-character random lowercase-alphanumeric prefix to the composed bucket name for key-distribution/sharding. Toggling this after creation renames and therefore REPLACES the bucket. | `bool` | `false` | no |
| tags | Tags applied to every taggable resource in the module. | `map(string)` | `{}` | no |
| vpc\_endpoint\_ids | VPC endpoint ids the mirror is served through (required, non-empty). Drives BOTH AllowMirrorReadFromVPCE (StringEquals aws:SourceVpce) and the core's DenyOutsideVpce — one list, so the two can never contradict (OQ 1a). | `list(string)` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| bucket\_arn | The bucket's ARN. |
| bucket\_id | The bucket's ID (its name, as the provider returns it). |
| bucket\_name | The bucket's final composed name. |
| bucket\_policy\_json | The composed bucket policy (baseline denies + DenyOutsideVpce + the four mirror statements + additional\_policy\_statements) — re-exported so plan suites can assert the additive merge statement-by-statement. |
| lifecycle\_rule\_ids | Ids of every lifecycle rule on the bucket, in order (the baseline MPU-abort rule first, then the IA rule when enabled) — the plan suites' window on rule wiring (child-module resources aren't assertable). |
| logging\_prefix | Resolved server-access-logging prefix, or null when logging is off. |
| logging\_target | Resolved server-access-logging target bucket (the explicit access\_log\_bucket, or null when disabled) — the plan suites' window on the logging wiring. |
| mirror\_url | The S3 REST endpoint with trailing slash, ready to paste into provider\_installation (standard partition). |
| security\_baseline | The composed security baseline, re-exported verbatim from the internal core — pinned by this module's security\_baseline.tftest.hcl (the family's third documented variant: SSE-S3 + versioning Enabled). |
<!-- END_TF_DOCS -->
