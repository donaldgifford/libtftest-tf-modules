#--------------------------------------------------------------
# Required inputs
#--------------------------------------------------------------

variable "region" {
  description = "AWS region for the filesystem + the S3 backend hosting the VPC + EKS remote states."
  type        = string
  nullable    = false
}

variable "remote_state_bucket" {
  description = "S3 bucket holding both the VPC stack's terraform state (read at <region>/vpc/<vpc_name>/terraform.tfstate for vpc_id + private_subnet_ids) and the EKS cluster stack's terraform state (read at <region>/eks/<cluster_name>/terraform.tfstate for node_security_group_id) — per DESIGN-0008 Q1."
  type        = string
  nullable    = false
}

variable "vpc_name" {
  description = "VPC name used to compose the VPC remote-state key. Must match the VPC stack's identifier."
  type        = string
  nullable    = false
}

variable "cluster_name" {
  description = "EKS cluster name used to compose the cluster remote-state key. Must match the EKS cluster stack's identifier (the module reads node_security_group_id from that state to gate NFS ingress to the mount targets)."
  type        = string
  nullable    = false
}

variable "identifier_prefix" {
  description = "Stable filesystem identifier used as the EFS creation_token, KMS alias suffix, security group name, and tag-Name. Must satisfy a lowercase identifier shape and stay within EFS's 64-char creation_token limit."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}[a-z0-9]$", var.identifier_prefix))
    error_message = "identifier_prefix must match ^[a-z][a-z0-9-]{0,62}[a-z0-9]$ (lowercase, 2-64 chars, starts with letter, ends with letter or digit, hyphens internal only)."
  }

  validation {
    condition     = length(var.identifier_prefix) <= 64
    error_message = "identifier_prefix must be 64 chars or fewer (EFS creation_token maximum)."
  }

  nullable = false
}

#--------------------------------------------------------------
# Optional inputs
#--------------------------------------------------------------

variable "kms_key_arn" {
  description = "Optional caller-supplied KMS key ARN for filesystem encryption at rest. When null (default), the module creates a dedicated key + alias internally and protects it with lifecycle { prevent_destroy = true } per IMPL-0008 Q6."
  type        = string
  default     = null
}

variable "performance_mode" {
  description = "EFS performance mode — 'generalPurpose' (default per DESIGN-0008 Q2; best latency for most workloads, 7000 ops/s ceiling) or 'maxIO' (higher aggregate throughput, higher per-op latency; only relevant for very-large parallel jobs). Cannot be changed after filesystem creation — switching modes requires a new filesystem."
  type        = string
  default     = "generalPurpose"

  validation {
    condition     = can(regex("^(generalPurpose|maxIO)$", var.performance_mode))
    error_message = "performance_mode must be 'generalPurpose' or 'maxIO'."
  }

  nullable = false
}

variable "throughput_mode" {
  description = "EFS throughput mode — 'elastic' (default per DESIGN-0008 Q3; AWS auto-scales throughput with workload, charge-per-use), 'bursting' (legacy; baseline scales with filesystem size + credit accrual), or 'provisioned' (fixed throughput floor; requires var.provisioned_throughput_in_mibps)."
  type        = string
  default     = "elastic"

  validation {
    condition     = can(regex("^(bursting|elastic|provisioned)$", var.throughput_mode))
    error_message = "throughput_mode must be 'bursting', 'elastic', or 'provisioned'."
  }

  nullable = false
}

variable "provisioned_throughput_in_mibps" {
  description = "Provisioned throughput floor in MiB/s when var.throughput_mode = 'provisioned'. Range: 1 - 4096. Null (default) for elastic/bursting modes. Cross-variable invariant — provisioned mode iff non-null — is enforced via lifecycle.precondition on the filesystem (terraform 1.1 variable.validation cannot reference other variables)."
  type        = number
  default     = null

  validation {
    condition     = var.provisioned_throughput_in_mibps == null || (try(var.provisioned_throughput_in_mibps >= 1 && var.provisioned_throughput_in_mibps <= 4096, false))
    error_message = "provisioned_throughput_in_mibps must be null or in the range [1, 4096] (EFS provisioned throughput bounds)."
  }
}

variable "lifecycle_policy" {
  description = "EFS lifecycle policy — controls IA + Archive + primary-storage transitions. Defaults to IA-after-30-days + Archive-after-90-days per DESIGN-0008 Q4. Set the whole variable to null to disable all transitions; pass a partial object to override individual transitions (optional() defaults fill the rest)."
  type = object({
    transition_to_ia                    = optional(string, "AFTER_30_DAYS")
    transition_to_archive               = optional(string, "AFTER_90_DAYS")
    transition_to_primary_storage_class = optional(string, null)
  })
  default = {}
}

variable "additional_allowed_consumer_sg_ids" {
  description = "Extra security group IDs whose members may reach the mount targets on NFS port 2049. The module's default ingress already allows the EKS node SG (resolved from the cluster remote state); use this for EC2 workloads, batch jobs, or peer-VPC consumers that share the same VPC."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for sg in var.additional_allowed_consumer_sg_ids : can(regex("^sg-[a-f0-9]+$", sg))])
    error_message = "Each additional_allowed_consumer_sg_ids entry must match ^sg-[a-f0-9]+$ (AWS security group ID shape)."
  }
}

variable "backup_policy_enabled" {
  description = "When true, the module enables the AWS-managed EFS backup policy (per DESIGN-0008 Q7). Default false — operators opt in deliberately because the default AWS Backup vault carries its own retention + lifecycle policy that may not match site policy."
  type        = bool
  default     = false
}

variable "access_points" {
  description = "Declarative map of EFS access points. Key is the access-point logical name (used as the Name tag); value carries the POSIX user + root-directory contract. Empty map (default) creates zero access points — the filesystem is reachable via the raw mount targets only. See IMPL-0008 Q3 / Q4 for the full shape contract and POSIX UID/GID bounds."
  type = map(object({
    posix_user = object({
      uid            = number
      gid            = number
      secondary_gids = optional(list(number), [])
    })
    root_directory = object({
      path = string
      creation_info = optional(object({
        owner_uid   = number
        owner_gid   = number
        permissions = string
      }))
    })
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.access_points : (
        v.posix_user.uid >= 0 && v.posix_user.uid <= 65535 &&
        v.posix_user.gid >= 0 && v.posix_user.gid <= 65535 &&
        alltrue([for g in v.posix_user.secondary_gids : g >= 0 && g <= 65535])
      )
    ])
    error_message = "Each access point's posix_user.uid, posix_user.gid, and every secondary_gids entry must be in the range [0, 65535] (POSIX UID/GID bounds; root is permitted)."
  }
}

variable "tags" {
  description = "AWS resource tags applied to every taggable resource in the module (filesystem, mount targets where supported, access points, security group, security group rules, KMS key)."
  type        = map(string)
  default     = {}
}
