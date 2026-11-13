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
| [aws_ecr_account_setting.registry_policy_scope](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_account_setting) | resource |
| [aws_ecr_registry_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_registry_policy) | resource |
| [aws_ecr_registry_scanning_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_registry_scanning_configuration) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| additional\_policy\_statements | Extra registry-policy statements, appended unchanged after the module's own. sids must be alphanumeric, unique, and must not start with the reserved 'Consumer' prefix. principals[].type is AWS or Service; actions must be ecr: actions. Conditions sharing a test operator merge into one operator object. These are not checked for widening: a statement granting a consumer repository/* still cannot reach a protected prefix, because the module's explicit Deny wins. | ```list(object({ sid = string effect = string principals = list(object({ type = string identifiers = list(string) })) actions = list(string) resources = list(string) conditions = optional(list(object({ test = string variable = string values = list(string) })), []) }))``` | `[]` | no |
| consumer\_accounts | Accounts allowed to PULL from pull\_repository\_prefixes, keyed by 12-digit account ID. Each account is granted as arn:aws:iam::<id>:root, meaning that account's own IAM decides which of its principals may pull (not the root user). principal\_arn\_patterns optionally narrows an account to ArnLike patterns on aws:PrincipalArn (for example arn:aws:iam::<id>:role/*-node-*); patterns must name the same account. Every listed account is also explicitly DENIED all ECR actions on protected\_prefixes. A typo in an account ID grants to a stranger's account, so review this map like a trust policy. | ```map(object({ principal_arn_patterns = optional(list(string), []) }))``` | `{}` | no |
| manage\_registry\_policy\_scope | Pin the account's REGISTRY\_POLICY\_SCOPE to V2, which pull grants in a registry policy require (V1 covers only replication and pull-through-cache actions, and a V1 registry is expected to reject the pull grant outright). Set false only when the scope is managed elsewhere AND the registry is already on V2. | `bool` | `true` | no |
| protected\_prefixes | Repository prefixes no consumer account may ever touch (default ["quarantine"], where unvetted images wait for intake). Enforced twice: a plan-time overlap check against pull\_repository\_prefixes, and an explicit ConsumerDenyProtected statement denying every listed account all ECR actions on these prefixes. Set [] only if the registry has no such prefix. | `list(string)` | ```[ "quarantine" ]``` | no |
| pull\_repository\_prefixes | Repository prefixes the consumer accounts may pull, without a trailing slash (for example ["mirror", "apps"]). Each renders as arn:aws:ecr:<region>:<account>:repository/<prefix>/*. Must follow the ECR repository-name grammar (lowercase; no '*', no leading or trailing '/'), so a registry-wide repository/* grant is unrepresentable. Must not equal, contain, or sit inside a protected prefix. | `list(string)` | `[]` | no |
| scanning | Registry scanning configuration. null (default) manages nothing and leaves the registry's existing scanning setup alone; it does not disable scanning. A non-null value TAKES OWNERSHIP: it replaces the registry's whole scanning configuration. BASIC allows SCAN\_ON\_PUSH and MANUAL; ENHANCED allows SCAN\_ON\_PUSH and CONTINUOUS\_SCAN, and enables Amazon Inspector billing for the account. filters are WILDCARD repository filters (for example "quarantine/*"). | ```object({ scan_type = string rules = list(object({ scan_frequency = string filters = list(string) })) })``` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| consumer\_account\_ids | The allow-listed account IDs, sorted. |
| consumer\_identity\_policy\_json | The minimal identity policy a consumer principal needs (ecr:GetAuthorizationToken on *, plus the pull actions on pull\_repository\_arns), or null with no prefixes. The AWS-managed AmazonEC2ContainerRegistryReadOnly / PullOnly policies already cover it; this is for hand-scoped roles. |
| pull\_repository\_arns | The repository ARN patterns the pull grant covers. |
| pull\_repository\_prefixes | The prefixes consumer accounts may pull, sorted. |
| registry\_id | The registry's account ID. |
| registry\_policy\_json | The composed registry policy document, or null when none renders (no consumer accounts and no additional statements). |
| registry\_policy\_scope | "V2" when this module manages the REGISTRY\_POLICY\_SCOPE setting, otherwise null. |
| registry\_url | The registry hostname consumers put in image references: <registry\_url>/<prefix>/<path>@sha256:<digest>. |
<!-- END_TF_DOCS -->
