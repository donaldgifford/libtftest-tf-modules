#--------------------------------------------------------------
# Naming (DESIGN-0028 OQ 3a — family standard)
#--------------------------------------------------------------

variable "name" {
  description = "Logical bucket name. Composed into the real bucket name as <name>-<account_id>-<region> (plus the optional shard prefix). Lowercase alphanumeric + hyphens, 3-37 chars, must start/end alphanumeric. The sluice-dictated mirror name arrives via name_override instead."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,35}[a-z0-9]$", var.name))
    error_message = "name must be lowercase alphanumeric + hyphens, 3-37 characters, starting and ending alphanumeric."
  }

  nullable = false
}

variable "name_override" {
  description = "Escape hatch: use this exact bucket name verbatim, skipping <name>-<account_id>-<region> composition. The sluice-dictated mirror name arrives here (externally-dictated names are exactly this hatch's use case)."
  type        = string
  default     = null
}

variable "shard_prefix_enabled" {
  description = "Opt-in: prepend a stable 5-character random lowercase-alphanumeric prefix to the composed bucket name for key-distribution/sharding. Toggling this after creation renames and therefore REPLACES the bucket."
  type        = bool
  default     = false
  nullable    = false
}

#--------------------------------------------------------------
# Terragrunt-provided globals (DESIGN-0028 OQ 4a — account_id +
# region only). No remote-state read exists in this module, so the
# remote-state globals are not declared; Terragrunt injects its
# uniform input set regardless and undeclared inputs are ignored
# (IMPL-0015 Q6a).
#--------------------------------------------------------------

variable "account_id" {
  description = "12-digit AWS account ID — composed into the bucket name."
  type        = string
  nullable    = false
}

variable "region" {
  description = "AWS region — composed into the bucket name and the mirror_url output."
  type        = string
  nullable    = false
}

#--------------------------------------------------------------
# Mirror policy inputs (DESIGN-0028)
#--------------------------------------------------------------

variable "vpc_endpoint_ids" {
  description = "VPC endpoint ids the mirror is served through (required, non-empty). Drives BOTH AllowMirrorReadFromVPCE (StringEquals aws:SourceVpce) and the core's DenyOutsideVpce — one list, so the two can never contradict (OQ 1a)."
  type        = list(string)

  validation {
    condition     = length(var.vpc_endpoint_ids) > 0
    error_message = "vpc_endpoint_ids must not be empty — an unserved mirror is a misconfiguration, not a default."
  }

  validation {
    condition     = alltrue([for id in var.vpc_endpoint_ids : can(regex("^vpce-[0-9a-f]{8,17}$", id))])
    error_message = "every vpc_endpoint_ids entry must be a VPC endpoint id (vpce- followed by 8-17 lowercase hex characters)."
  }

  nullable = false
}

variable "break_glass_principal_arns" {
  description = "Break-glass exception to DenyObjectDeletion. Default [] = absolute deny (content mistakes fix forward with new versions; a true purge is a reviewed PR that adds a principal, applies, deletes, and reverts)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.break_glass_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/[\\w+=,.@-]+$", arn))])
    error_message = "every break_glass_principal_arns entry must be an exact IAM role or user ARN (arn:aws:iam::<12-digit-account>:(role|user)/<name>) — wildcards are rejected."
  }

  validation {
    condition     = alltrue([for arn in var.break_glass_principal_arns : !can(regex("[*?]", arn))])
    error_message = "break_glass_principal_arns must not contain wildcards — break-glass names exact principals."
  }

  validation {
    condition     = length(var.break_glass_principal_arns) == length(distinct(var.break_glass_principal_arns))
    error_message = "break_glass_principal_arns must not contain duplicates."
  }

  nullable = false
}

variable "policy_admin_principal_arns" {
  description = "Admin exception to DenyPolicyMutation (required, non-empty — an empty admin list would strand the stack: nobody could ever amend the policy). Disable the guard itself via enable_policy_mutation_guard."
  type        = list(string)

  validation {
    condition     = length(var.policy_admin_principal_arns) > 0
    error_message = "policy_admin_principal_arns must not be empty — with no admin the policy can never be amended. Disable the guard via enable_policy_mutation_guard instead."
  }

  validation {
    condition     = alltrue([for arn in var.policy_admin_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/[\\w+=,.@-]+$", arn))])
    error_message = "every policy_admin_principal_arns entry must be an exact IAM role or user ARN (arn:aws:iam::<12-digit-account>:(role|user)/<name>) — wildcards are rejected."
  }

  validation {
    condition     = alltrue([for arn in var.policy_admin_principal_arns : !can(regex("[*?]", arn))])
    error_message = "policy_admin_principal_arns must not contain wildcards — policy admins are exact principals."
  }

  validation {
    condition     = length(var.policy_admin_principal_arns) == length(distinct(var.policy_admin_principal_arns))
    error_message = "policy_admin_principal_arns must not contain duplicates."
  }

  nullable = false
}

variable "enable_policy_mutation_guard" {
  description = "Render DenyPolicyMutation (default true). The off-switch is the reviewed-PR escape hatch for a mis-scoped admin list, which with an always-on deny would strand the stack permanently (OQ 6a)."
  type        = bool
  default     = true
  nullable    = false
}

variable "cross_account_publisher_principal_arns" {
  description = "Cross-account publisher principals (the out-of-band GitHub OIDC role). Default [] = no statement rendered — same-account publishing needs no bucket-policy grant. Non-empty injects AllowCrossAccountPublisherWrite (PutObject + GetObject + ListBucket on this bucket, no deletes — sluice DESIGN-0002's write-only-no-delete publisher permissions)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.cross_account_publisher_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/[\\w+=,.@-]+$", arn))])
    error_message = "every cross_account_publisher_principal_arns entry must be an exact IAM role or user ARN (arn:aws:iam::<12-digit-account>:(role|user)/<name>) — wildcards are rejected."
  }

  validation {
    condition     = alltrue([for arn in var.cross_account_publisher_principal_arns : !can(regex("[*?]", arn))])
    error_message = "cross_account_publisher_principal_arns must not contain wildcards — publishers are exact principals."
  }

  validation {
    condition     = length(var.cross_account_publisher_principal_arns) == length(distinct(var.cross_account_publisher_principal_arns))
    error_message = "cross_account_publisher_principal_arns must not contain duplicates."
  }

  nullable = false
}

#--------------------------------------------------------------
# Logging (DESIGN-0028 — explicit target, no remote-state read)
#--------------------------------------------------------------

variable "access_log_bucket" {
  description = "Server-access-logging target bucket name (the existing access-logs-bucket stack), or null (default) for no logging. Named explicitly — no fleet lookup, no bootstrapping order beyond applying the sink first."
  type        = string
  default     = null
}

variable "access_log_prefix" {
  description = "Server-access-logging prefix, or null (default) for the core's \"<composed-name>/\" default (only the core knows the final name — the shard prefix is unknown until apply)."
  type        = string
  default     = null
}

#--------------------------------------------------------------
# Lifecycle + Object Lock (DESIGN-0028 OQ 5a)
#--------------------------------------------------------------

variable "noncurrent_version_ia_days" {
  description = "Days after becoming noncurrent before an object version transitions to STANDARD_IA (the access-logs-bucket log_retention_days precedent: one number maps to one fixed-id core rule). Null (default) disables — no rule rendered. There is deliberately no expiration variable: expiry destroys the forensics record and breaks pinned installs."
  type        = number
  default     = null

  validation {
    condition     = var.noncurrent_version_ia_days == null || var.noncurrent_version_ia_days >= 1
    error_message = "noncurrent_version_ia_days must be at least 1 (or null to disable)."
  }
}

variable "enable_object_lock" {
  description = "Opt-in Object Lock (CREATE-TIME: toggling it on an existing bucket REPLACES the bucket). Default false."
  type        = bool
  default     = false
  nullable    = false
}

variable "object_lock_retention_days" {
  description = "Object Lock default retention in days, mapped onto the core's object_lock.days with mode pinned COMPLIANCE (the mirror's threat is quiet content mutation; GOVERNANCE's bypass is for lower-stakes tiers). Null (default) = no default retention. The core's retention-set-but-disabled coherence guard fails the plan if days are set without enable_object_lock = true."
  type        = number
  default     = null

  validation {
    condition     = var.object_lock_retention_days == null || var.object_lock_retention_days >= 1
    error_message = "object_lock_retention_days must be at least 1 (or null for no default retention)."
  }
}

#--------------------------------------------------------------
# Baseline pass-throughs (resolved in the internal core)
#--------------------------------------------------------------

variable "force_destroy" {
  description = "Allow destroy to delete a non-empty bucket. Off by default — data loss is opt-in; test fixtures set it true for teardown."
  type        = bool
  default     = false
  nullable    = false
}

variable "abort_incomplete_multipart_days" {
  description = "Days after initiation before an incomplete multipart upload is aborted (baseline hygiene rule)."
  type        = number
  default     = 7

  validation {
    condition     = var.abort_incomplete_multipart_days >= 1
    error_message = "abort_incomplete_multipart_days must be at least 1."
  }

  nullable = false
}

variable "additional_policy_statements" {
  description = "Operator bucket-policy statements, appended additively after the baseline denies AND the mirror statements (DESIGN-0019 OQ 4b — these ADD grants/denies; they can never shadow the baseline or the mirror posture, and the reserved sids are rejected at plan by the core). resource_suffixes are relative to the bucket ARN (\"\" = the bucket, \"/*\" = objects)."
  type = list(object({
    sid               = string
    effect            = optional(string, "Allow")
    principals        = optional(map(list(string)), {})
    actions           = list(string)
    resource_suffixes = optional(list(string), ["", "/*"])
    conditions = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
  }))
  default = []

  # Mirrors the core's guard so the failure is root-addressable:
  # terraform test expect_failures cannot target a child module's
  # variable validation, and the operator-facing error should name
  # THIS variable, not the core's internal one.
  validation {
    condition = alltrue([
      for s in var.additional_policy_statements :
      !contains(["DenyInsecureTransport", "DenyOldTls", "DenyOutsideVpce", "AllowMirrorReadFromVPCE", "DenyObjectDeletion", "DenyPolicyMutation", "AllowCrossAccountPublisherWrite"], s.sid)
    ])
    error_message = "additional_policy_statements must not reuse a reserved sid (the three baseline denies plus the four mirror-composed sids) — the merge is additive-only; statements can never shadow the baseline or the mirror posture."
  }

  nullable = false
}

variable "tags" {
  description = "Tags applied to every taggable resource in the module."
  type        = map(string)
  default     = {}
  nullable    = false
}
