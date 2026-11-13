<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9 |
| aws | ~> 6.2 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.2 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_event_rule.quarantine_push](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.intake](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_ecr_repository_creation_template.promoted](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository_creation_template) | resource |
| [aws_ecr_repository_creation_template.quarantine](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository_creation_template) | resource |
| [aws_iam_role.template](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.template](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_default_tags.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/default_tags) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_principal\_arns | Principals exempt from every Deny: they alone may change a promoted repository's policy, mutability or lifecycle, or delete it. Required, because with no admin the policy-mutation Deny would lock every principal out. Include the deploy role. | `list(string)` | n/a | yes |
| intake\_event\_target | Optional EventBridge target for quarantine pushes (a queue, topic, event bus or state machine). null (default) creates no rule; the pattern is always exported as intake\_event\_pattern\_json. The destination's resource policy belongs to the destination stack. role\_arn is required for event-bus and state-machine targets. | ```object({ arn = string role_arn = optional(string) })``` | `null` | no |
| intake\_principal\_arns | Principals that read quarantine and promote into the promoted prefixes (the intake workflow's role). Grant them intake\_policy\_json. Must not overlap writer\_principal\_arns. | `list(string)` | n/a | yes |
| kms\_key\_arn | Optional customer-managed KMS key ARN for repository encryption. null (default) = AES256 (DESIGN-0031 OQ 8a). A CMK adds a cross-account question: consumers pulling from another account may also need kms:Decrypt on the key, so read the README before setting it. | `string` | `null` | no |
| name | Instance name, used for the template IAM role (<name>-ecr-templates) and the intake event rule (<name>-quarantine-push). Use a placeholder-style name (for example example-intake). Renaming replaces both. | `string` | n/a | yes |
| promoted\_prefixes | Promoted prefixes, one creation template each: IMMUTABLE\_WITH\_EXCLUSION tags, no lifecycle policy, writes by intake and admins only, policy changes by admins only. Keys are prefixes; feed the promoted\_prefixes output to ecr/registry's pull\_repository\_prefixes to share them. The default exclusion sha256-* keeps cosign's legacy .sig/.att tags appendable. | ```map(object({ description = optional(string) tag_mutability_exclusions = optional(list(string), ["sha256-*"]) }))``` | ```{ "mirror": {} }``` | no |
| quarantine\_prefix | Prefix of the quarantine template. Writers push here; images expire after quarantine\_retention\_days; only writers, intake and admins can read or write it. Never list it in ecr/registry's pull\_repository\_prefixes (that module's protected\_prefixes default already denies it). | `string` | `"quarantine"` | no |
| quarantine\_retention\_days | Days after push at which EVERY quarantined image expires (sinceImagePushed). Quarantine is a staging area, not a store: intake promotes by digest well inside the window. | `number` | `7` | no |
| writer\_principal\_arns | Principals that push to quarantine (the sync job's role). Same account as the registry only (DESIGN-0031 OQ 14a, enforced by a precondition). Grant them writer\_policy\_json. | `list(string)` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| intake\_event\_pattern\_json | EventBridge pattern matching successful pushes to the quarantine prefix. Always exported, for callers who wire their own rule. |
| intake\_event\_rule\_arn | ARN of the intake event rule, or null when intake\_event\_target is null. |
| intake\_policy\_json | Identity policy for intake roles: read and scan findings on quarantine; pull, push and create-on-push on the promoted prefixes. Signing comes from the signing key's own key policy, not this document. |
| promoted\_prefixes | Promoted prefixes, sorted: shaped to feed ecr/registry's pull\_repository\_prefixes directly. |
| quarantine\_prefix | The quarantine prefix. Keep it in ecr/registry's protected\_prefixes, never in pull\_repository\_prefixes. |
| template\_role\_arn | ARN of the role ECR assumes when it creates repositories from these templates. |
| writer\_policy\_json | Identity policy for writer roles: the ECR auth token plus push and create-on-push on the quarantine prefix only. Compose into iam/role or eks/pod-identity-access inline\_policies. |
<!-- END_TF_DOCS -->