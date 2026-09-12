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
| terraform | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [terraform_remote_state.vpc](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| account\_id | 12-digit AWS account ID that owns the remote-state bucket. Composed into the assume\_role role\_arn (arn:aws:iam::<account\_id>:role/<deploy\_role\_name>) for the cross-account state read. | `string` | n/a | yes |
| account\_name | Terragrunt account name — the <account\_name> prefix of the account-scoped VPC remote-state key this module reads. | `string` | n/a | yes |
| allow\_all\_egress | Emit one explicit all-protocols egress rule to 0.0.0.0/0 (default true). This is NOT redundant with AWS's default: the provider REVOKES the default allow-all egress when it creates a security group, so a module with no egress surface would ship SGs that silently fail ALB health checks and target traffic. The rule is emitted as a real resource so the posture is visible in every plan rather than implied. Set false to make egress\_rules the whole posture — required, not optional, whenever egress\_rules is non-empty. | `bool` | `true` | no |
| allow\_world\_open\_ingress | Permit ingress rules whose literal source CIDR is a /0 — 0.0.0.0/0, ::/0, and every other legal spelling of them, since the guard tests the /0 suffix rather than comparing strings (IPv6 spells the world several ways). Default false, fail-closed. A deliberately public frontend sets this to true, which is one explicit line a reviewer can see. SCOPE, stated honestly — this is a guard against the accident, not a proof of non-exposure. It inspects literal CIDR fields only, so it does NOT look inside a prefix list (a prefix\_list\_id whose list contains 0.0.0.0/0 admits the world with this left false — the reference is live, and plan-time expansion would be false assurance; list contents are the list owner's audit surface), and it does not catch a /1 split: 0.0.0.0/1 plus 128.0.0.0/1 is the whole internet in two rules that are not /0s. | `bool` | `false` | no |
| deploy\_role\_name | Name of the IAM role Terraform assumes to read the remote-state bucket cross-account. Composed into the assume\_role role\_arn with account\_id. | `string` | n/a | yes |
| description | Security group description. Defaults to a line composed from var.name. NOTE: description is create-time on AWS (ForceNew) — editing it REPLACES the security group. The module's name\_prefix + create\_before\_destroy make that replacement survivable, but it still mints a new security group id, so any chart-side or cross-stack consumer of the id needs updating in the same change. AWS restricts this field to ASCII: a-z A-Z 0-9 spaces and .\_-:/()#,@[]+=&;{}!$* — a typographic dash or quote pasted from a doc or a chat window fails at APPLY, not at plan. | `string` | `null` | no |
| egress\_rules | Egress rules, keyed by logical rule name. Same object shape as ingress\_rules. Setting this REQUIRES allow\_all\_egress = false: the two together are rejected at plan, because the all-egress rule is wider than anything written here and shows up in the plan only as an unchanged resource. The logical key "all-egress" is reserved (the module's own default rule already claims that Name tag). | ```map(object({ description = string from_port = optional(number) to_port = optional(number) ip_protocol = optional(string, "tcp") cidr_ipv4 = optional(string) cidr_ipv6 = optional(string) prefix_list_id = optional(string) referenced_security_group_id = optional(string) }))``` | `{}` | no |
| ingress\_rules | Ingress allowlist, keyed by logical rule name (stable addresses). Each rule names exactly ONE source: cidr\_ipv4 \| cidr\_ipv6 \| prefix\_list\_id \| referenced\_security\_group\_id. prefix\_list\_id rules are LIVE references — edits to the list propagate without a Terraform apply, unlike the eks/cluster endpoint fence's plan-time expansion. description is required: every allowlist entry says why it exists, and AWS constrains its charset (ASCII only) server-side, so it is validated here. Ports depend on the protocol: tcp/udp require from\_port and to\_port collapses to it (the single-port rule); icmp/icmpv6 require BOTH, because there from\_port is the ICMP TYPE and to\_port is the CODE, not a range end — letting it collapse would silently set code = type; ip\_protocol = "-1" and numeric protocols must omit both ports, since AWS ignores them there. | ```map(object({ description = string from_port = optional(number) to_port = optional(number) ip_protocol = optional(string, "tcp") cidr_ipv4 = optional(string) cidr_ipv6 = optional(string) prefix_list_id = optional(string) referenced_security_group_id = optional(string) }))``` | `{}` | no |
| name | Logical name for this security group. Becomes the name\_prefix ("<name>-", so the physical name carries a provider-generated suffix), the friendly Name tag, the default description, and the <name> segment of this stack's ADR-0020 remote-state key — which makes it triple-coupled: producer identifier == live-repo folder == future consumer input. Renaming is a deliberate SG replacement, not a refactor. | `string` | n/a | yes |
| region | AWS region the security group is created in. | `string` | n/a | yes |
| remote\_state\_bucket | S3 bucket holding the VPC stack's terraform state, read at <account\_name>/<region>/vpc/<vpc\_name>/terraform.tfstate for vpc\_id. | `string` | n/a | yes |
| remote\_state\_bucket\_region | Region of the remote-state S3 bucket — distinct from var.region (the deployment region) in production Terragrunt. | `string` | n/a | yes |
| tags | Tags applied to the security group and to every rule resource. The Name tag is set by the module from var.name and must not be supplied here. | `map(string)` | `{}` | no |
| vpc\_name | VPC name used to compose the VPC remote-state key (<account\_name>/<region>/vpc/<vpc\_name>/terraform.tfstate). Must match the VPC stack's identifier. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| all\_egress\_rule\_id | Security-group-rule id of the module's all-protocols egress rule, or null when allow\_all\_egress = false. |
| egress\_rule\_ids | Map of logical egress rule name to its security-group-rule id (sgr-...). Covers the typed egress\_rules map ONLY — the allow\_all\_egress rule has no logical name and rides all\_egress\_rule\_id instead. |
| ingress\_rule\_ids | Map of logical ingress rule name to its security-group-rule id (sgr-...). Empty when ingress\_rules is empty. |
| security\_group\_arn | Security group ARN. |
| security\_group\_id | Security group id (sg-...). The module's primary output: the value the Load Balancer Controller's frontend-SG annotation carries, and the value a sibling stack takes as referenced\_security\_group\_id. |
| security\_group\_name | PHYSICAL security group name — var.name plus the provider-generated name\_prefix suffix, not var.name itself. Use this when matching what the console or the EC2 API shows; use var.name for the friendly Name tag. |
<!-- END_TF_DOCS -->
