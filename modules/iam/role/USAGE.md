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
| customer\_managed\_policy\_arns | Customer-managed policy ARNs to attach to this role. Separate from managed\_policy\_arns so the plan distinguishes AWS-owned from caller-owned policy ARNs at a glance, and so the same ARN cannot be listed in both channels. | `list(string)` | `[]` | no |
| description | Human-readable description of what this role is for and who assumes it. Updates in place (no replacement). | `string` | `null` | no |
| external\_id | Value the caller must present as sts:ExternalId to assume this role — the classic confused-deputy control for a trust granted to a third party. Null (default) adds no condition. It is a unique, unpredictable identifier and NOT a secret: AWS documents it as such, and it appears in CloudTrail requestParameters.externalId on both sides of the AssumeRole as well as in plan output and state. Singular by design: it keys one relationship, so a list of accepted values would mean "any of these will do". DO NOT set this on a role the fleet's data.terraform\_remote\_state blocks assume (the deploy role) unless you add a matching external\_id to every one of those blocks in the same change — otherwise every consumer plan fleet-wide fails AccessDenied on the NEXT plan, not on the apply that caused it. | `string` | `null` | no |
| inline\_policies | Inline IAM policy documents to attach to this role, keyed by policy name. Values are JSON strings — compose them with data.aws\_iam\_policy\_document in the calling stack. These are AUTHORIZATION documents; no credential ever rides this channel. | `map(string)` | `{}` | no |
| managed\_policy\_arns | AWS-managed policy ARNs to attach to this role (e.g. arn:aws:iam::aws:policy/ReadOnlyAccess). Only the aws-owned pseudo-account spelling is accepted — caller-owned ARNs belong in customer\_managed\_policy\_arns. | `list(string)` | `[]` | no |
| max\_session\_duration | Maximum session duration in seconds for sessions assumed into this role (AWS default 3600 = 1 hour, maximum 43200 = 12 hours). | `number` | `3600` | no |
| name | Exact IAM role name — no prefix, no suffixing. Consumers reference this role BY NAME (every ADR-0020 remote-state read composes arn:aws:iam::<account\_id>:role/<deploy\_role\_name> and assumes it), so the physical name IS the contract. Changing it replaces the role. | `string` | n/a | yes |
| path | IAM path for the role (default "/"). CAUTION: a non-default path gives the role TWO legitimate ARN spellings — path-bearing (arn:...:role/team/Name, what IAM returns) and path-stripped (arn:...:role/Name) — and spelling mismatches are exactly where guards and validations get evaded (IMPL-0020's collision guard normalizes for this reason). Keep "/" for roles destined for an eks/access-entries binding: how the EKS API canonicalizes path-bearing principal ARNs is unverified until IMPL-0020 task 5.4's live runs answer it. | `string` | `"/"` | no |
| permissions\_boundary | ARN of an IAM policy to attach as this role's permissions boundary. Null (default) attaches no boundary. An EMPTY STRING is rejected rather than treated as null: the provider omits the argument on create and takes the DeleteRolePermissionsBoundary branch on update, so "" reads as "bounded" in a plan and applies as NO boundary — including silently stripping the boundary off an existing role. Pass null explicitly, never a defaulted-to-empty lookup. | `string` | `null` | no |
| require\_org\_ids | AWS Organization ids (o-...) whose principals may assume this role, ANDed onto the trust statement as StringEquals on aws:PrincipalOrgID. Empty (default) adds no condition. SCOPE, stated honestly: this mitigates the cross-account dangling-principal hazard — IAM stores a cross-account principal ARN unvalidated, so a typo grants nobody but leaves the name claimable, and an org condition means whoever claims it must ALSO be in one of these organizations. It does NOTHING for a typo naming a nonexistent role INSIDE the org. Correct ARNs remain the primary control. | `list(string)` | `[]` | no |
| tags | Tags applied to the IAM role. | `map(string)` | `{}` | no |
| trusted\_role\_arns | Exact IAM principal ARNs (roles or users) granted sts:AssumeRole on this role. At least one is required — a role nobody can assume is dead weight. Wildcards are rejected: this typed surface exists to prevent the fail-open a JSON trust channel would allow. Entries must be the REAL, path-bearing ARNs. CAUTION — the apply-time backstop is SAME-ACCOUNT ONLY: IAM resolves a same-account principal to its unique id when the policy is saved, so a wrong spelling there fails the apply; a CROSS-ACCOUNT ARN is stored as an unvalidated literal string, so a typo applies green, grants nobody, and leaves a dangling principal that whoever later creates a role by that name inherits. Both worked examples in the README are cross-account, so treat these ARNs as unverified input and pair the cross-account instances with a trust condition (DESIGN-0025 Follow-up 1). Service principals belong to the resource-owning modules (see the README Non-Goals). | `list(string)` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| role\_arn | The role's ARN. Note this is the PATH-BEARING spelling IAM returns — consumers composing trust policies or access entries must use it verbatim (see the README's path note). |
| role\_name | The role's exact name — the by-name contract every ADR-0020 assume\_role block composes from (role\_arn = arn:aws:iam::<account\_id>:role/<this>). |
| role\_unique\_id | The role's stable unique ID (AROA...). Survives a rename; useful for audit correlation across CloudTrail. |
<!-- END_TF_DOCS -->
