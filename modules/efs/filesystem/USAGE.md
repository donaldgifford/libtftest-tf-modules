<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |
| aws | ~> 6.2 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.47.0 |
| terraform | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_efs_access_point.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_access_point) | resource |
| [aws_efs_backup_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_backup_policy) | resource |
| [aws_efs_file_system.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system) | resource |
| [aws_efs_mount_target.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target) | resource |
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_security_group_egress_rule.all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.from_extra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.from_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [terraform_remote_state.eks](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |
| [terraform_remote_state.vpc](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| access\_points | Declarative map of EFS access points. Key is the access-point logical name (used as the Name tag); value carries the POSIX user + root-directory contract. Empty map (default) creates zero access points — the filesystem is reachable via the raw mount targets only. See IMPL-0008 Q3 / Q4 for the full shape contract and POSIX UID/GID bounds. | ```map(object({ posix_user = object({ uid = number gid = number secondary_gids = optional(list(number), []) }) root_directory = object({ path = string creation_info = optional(object({ owner_uid = number owner_gid = number permissions = string })) }) }))``` | `{}` | no |
| additional\_allowed\_consumer\_sg\_ids | Extra security group IDs whose members may reach the mount targets on NFS port 2049. The module's default ingress already allows the EKS node SG (resolved from the cluster remote state); use this for EC2 workloads, batch jobs, or peer-VPC consumers that share the same VPC. | `list(string)` | `[]` | no |
| backup\_policy\_enabled | When true, the module enables the AWS-managed EFS backup policy (per DESIGN-0008 Q7). Default false — operators opt in deliberately because the default AWS Backup vault carries its own retention + lifecycle policy that may not match site policy. | `bool` | `false` | no |
| cluster\_name | EKS cluster name used to compose the cluster remote-state key. Must match the EKS cluster stack's identifier (the module reads node\_security\_group\_id from that state to gate NFS ingress to the mount targets). | `string` | n/a | yes |
| identifier\_prefix | Stable filesystem identifier used as the EFS creation\_token, KMS alias suffix, security group name, and tag-Name. Must satisfy a lowercase identifier shape and stay within EFS's 64-char creation\_token limit. | `string` | n/a | yes |
| kms\_key\_arn | Optional caller-supplied KMS key ARN for filesystem encryption at rest. When null (default), the module creates a dedicated key + alias internally and protects it with lifecycle { prevent\_destroy = true } per IMPL-0008 Q6. | `string` | `null` | no |
| lifecycle\_policy | EFS lifecycle policy — controls IA + Archive + primary-storage transitions. Defaults to IA-after-30-days + Archive-after-90-days per DESIGN-0008 Q4. Set the whole variable to null to disable all transitions; pass a partial object to override individual transitions (optional() defaults fill the rest). | ```object({ transition_to_ia = optional(string, "AFTER_30_DAYS") transition_to_archive = optional(string, "AFTER_90_DAYS") transition_to_primary_storage_class = optional(string, null) })``` | `{}` | no |
| performance\_mode | EFS performance mode — 'generalPurpose' (default per DESIGN-0008 Q2; best latency for most workloads, 7000 ops/s ceiling) or 'maxIO' (higher aggregate throughput, higher per-op latency; only relevant for very-large parallel jobs). Cannot be changed after filesystem creation — switching modes requires a new filesystem. | `string` | `"generalPurpose"` | no |
| provisioned\_throughput\_in\_mibps | Provisioned throughput floor in MiB/s when var.throughput\_mode = 'provisioned'. Range: 1 - 4096. Null (default) for elastic/bursting modes. Cross-variable invariant — provisioned mode iff non-null — is enforced via lifecycle.precondition on the filesystem (terraform 1.1 variable.validation cannot reference other variables). | `number` | `null` | no |
| region | AWS region for the filesystem + the S3 backend hosting the VPC + EKS remote states. | `string` | n/a | yes |
| remote\_state\_bucket | S3 bucket holding both the VPC stack's terraform state (read at <region>/vpc/<vpc\_name>/terraform.tfstate for vpc\_id + private\_subnet\_ids) and the EKS cluster stack's terraform state (read at <region>/eks/<cluster\_name>/terraform.tfstate for node\_security\_group\_id) — per DESIGN-0008 Q1. | `string` | n/a | yes |
| tags | AWS resource tags applied to every taggable resource in the module (filesystem, mount targets where supported, access points, security group, security group rules, KMS key). | `map(string)` | `{}` | no |
| throughput\_mode | EFS throughput mode — 'elastic' (default per DESIGN-0008 Q3; AWS auto-scales throughput with workload, charge-per-use), 'bursting' (legacy; baseline scales with filesystem size + credit accrual), or 'provisioned' (fixed throughput floor; requires var.provisioned\_throughput\_in\_mibps). | `string` | `"elastic"` | no |
| vpc\_name | VPC name used to compose the VPC remote-state key. Must match the VPC stack's identifier. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| access\_point\_arns | Map of access-point logical name → access point ARN. Consumed by IAM policies scoping elasticfilesystem:ClientMount permissions to a specific access point. |
| access\_point\_ids | Map of access-point logical name (var.access\_points map key) → access point ID. Plugs into the second segment of the <filesystem\_id>::<access\_point\_id> volumeHandle shape on PV manifests. |
| dns\_name | DNS hostname of the filesystem (<fs-id>.efs.<region>.amazonaws.com). Used by non-CSI NFS clients (EC2 instances, batch jobs) that mount the filesystem directly via /etc/fstab or mount(8). EFS CSI driver consumers use filesystem\_id instead. |
| filesystem\_arn | EFS filesystem ARN. Consumed by IAM policies scoped to this specific filesystem (elasticfilesystem:ClientMount / ClientWrite / ClientRootAccess resource segments). |
| filesystem\_id | EFS filesystem ID. Plugs into the volumeHandle field of a PV manifest — either as the bare ID (root-mount PVs) or as the <filesystem\_id>::<access\_point\_id> shape (access-point-scoped PVs). |
| kms\_key\_arn | KMS key ARN encrypting filesystem data at rest. BYO ARN (when var.kms\_key\_arn was non-null) or module-managed key's ARN — resolved transparently via local.kms\_key\_arn. |
| mount\_target\_dns\_names | Map of subnet ID → mount target DNS name. Useful for diagnosing per-AZ mount issues. |
| mount\_target\_ids | Map of subnet ID → mount target ID. Useful for operators inspecting mount-target state via the AWS CLI; not typically consumed by Terraform downstream. |
| security\_group\_id | Mount-target security group ID. Consumers can reference this when they add their own peering ingress rules outside the module's additional\_allowed\_consumer\_sg\_ids contract (e.g., for cross-VPC consumers reachable via a transit gateway). |
<!-- END_TF_DOCS -->
