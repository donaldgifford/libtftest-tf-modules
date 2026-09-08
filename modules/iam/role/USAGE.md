<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |
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
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.inline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.customer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_policy_document.trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| customer\_managed\_policy\_arns | Customer-managed policy ARNs to attach to this role. Separate from managed\_policy\_arns so the plan distinguishes AWS-owned from caller-owned policy ARNs at a glance. | `list(string)` | `[]` | no |
| description | Human-readable description of what this role is for and who assumes it. Updates in place (no replacement). | `string` | `null` | no |
| inline\_policies | Inline IAM policy documents to attach to this role, keyed by policy name. Values are JSON strings — compose them with data.aws\_iam\_policy\_document in the calling stack. These are AUTHORIZATION documents; no credential ever rides this channel. | `map(string)` | `{}` | no |
| managed\_policy\_arns | AWS-managed policy ARNs to attach to this role (e.g. arn:aws:iam::aws:policy/ReadOnlyAccess). | `list(string)` | `[]` | no |
| max\_session\_duration | Maximum session duration in seconds for sessions assumed into this role (AWS default 3600 = 1 hour, maximum 43200 = 12 hours). | `number` | `3600` | no |
| name | Exact IAM role name — no prefix, no suffixing. Consumers reference this role BY NAME (every ADR-0020 remote-state read composes arn:aws:iam::<account\_id>:role/<deploy\_role\_name> and assumes it), so the physical name IS the contract. Changing it replaces the role. | `string` | n/a | yes |
| path | IAM path for the role (default "/"). CAUTION: a non-default path gives the role TWO legitimate ARN spellings — path-bearing (arn:...:role/team/Name, what IAM returns) and path-stripped (arn:...:role/Name) — and spelling mismatches are exactly where guards and validations get evaded (IMPL-0020's collision guard normalizes for this reason). Keep "/" for roles destined for an eks/access-entries binding: how the EKS API canonicalizes path-bearing principal ARNs is unverified until IMPL-0020 task 5.4's live runs answer it. | `string` | `"/"` | no |
| permissions\_boundary | ARN of an IAM policy to attach as this role's permissions boundary. Null (default) attaches no boundary. | `string` | `null` | no |
| tags | Tags applied to the IAM role. | `map(string)` | `{}` | no |
| trusted\_role\_arns | Exact IAM principal ARNs (roles or users) granted sts:AssumeRole on this role. At least one is required — a role nobody can assume is dead weight. Wildcards are rejected: this typed surface exists to prevent the fail-open a JSON trust channel would allow. Entries must be the REAL, path-bearing ARNs — IAM validates principals when the policy is saved, and role names are account-unique regardless of path, so a path-stripped spelling of a path-bearing role fails the apply rather than matching anything else. Service principals belong to the resource-owning modules (see the README Non-Goals). | `list(string)` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| role\_arn | The role's ARN. Note this is the PATH-BEARING spelling IAM returns — consumers composing trust policies or access entries must use it verbatim (see the README's path note). |
| role\_name | The role's exact name — the by-name contract every ADR-0020 assume\_role block composes from (role\_arn = arn:aws:iam::<account\_id>:role/<this>). |
| role\_unique\_id | The role's stable unique ID (AROA...). Survives a rename; useful for audit correlation across CloudTrail. |
<!-- END_TF_DOCS -->
