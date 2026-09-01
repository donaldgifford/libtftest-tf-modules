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
| terraform | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eks_access_entry.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_policy_association.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [terraform_remote_state.eks](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| access\_entries | Generic EKS access entries: logical name -> entry. Direct principal ARNs — no resolution. policy\_associations (map keyed by logical association name) grant EKS access policies with cluster or namespace scope; kubernetes\_groups binds RBAC groups instead of (or alongside) policies. | ```map(object({ principal_arn = string type = optional(string, "STANDARD") kubernetes_groups = optional(list(string), []) user_name = optional(string) policy_associations = optional(map(object({ policy_arn = string access_scope = optional(object({ type = optional(string, "cluster") namespaces = optional(list(string), []) }), {}) })), {}) }))``` | `{}` | no |
| account\_id | 12-digit AWS account ID that owns the remote-state bucket. Composed into the assume\_role role\_arn (arn:aws:iam::<account\_id>:role/<deploy\_role\_name>) for the cross-account state read. | `string` | n/a | yes |
| account\_name | Terragrunt account name — the <account\_name> prefix of the account-scoped remote-state key this module reads (<account\_name>/<region>/eks/<cluster\_name>/terraform.tfstate). | `string` | n/a | yes |
| cluster\_name | EKS cluster name. Used as the remote-state key fragment and as each access entry's cluster\_name (read from the cluster's remote state output at the use site, ADR-0001). | `string` | n/a | yes |
| deploy\_role\_name | Name of the IAM role Terraform assumes to read the remote-state bucket cross-account. Composed into the assume\_role role\_arn with account\_id. | `string` | n/a | yes |
| region | AWS region. Also feeds the remote-state key convention <account\_name>/<region>/eks/<cluster\_name>/terraform.tfstate. | `string` | n/a | yes |
| remote\_state\_bucket | S3 bucket holding the cluster module's remote state. Used by data.terraform\_remote\_state.eks per ADR-0001. | `string` | n/a | yes |
| remote\_state\_bucket\_region | Region of the remote-state S3 bucket — distinct from var.region (the deployment region) in production Terragrunt. The terraform\_remote\_state backend reads from this region. | `string` | n/a | yes |
| tags | AWS resource tags applied to every access entry in the module. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| access\_entry\_arns | Map of logical entry name -> EKS access entry ARN. |
| policy\_association\_ids | Map of "<entry>:<association>" -> the policy association's ID. The flattened key shape is the module's stable addressing contract. |
| principal\_arns | Map of logical entry name -> the IAM principal ARN it binds. Echoes the input for audit and for consumers that hold only this module's state. |
<!-- END_TF_DOCS -->
