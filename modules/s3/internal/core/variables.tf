#--------------------------------------------------------------
# Naming inputs (DESIGN-0019 / INV-0009 OQ 7)
#--------------------------------------------------------------

variable "name" {
  description = "Logical bucket name. Composed into the real bucket name as <name>-<account_id>-<region> (plus the optional shard prefix). Lowercase alphanumeric + hyphens, 3-37 chars, must start/end alphanumeric — the length cap leaves room for the composed suffix within S3's 63-char limit."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,35}[a-z0-9]$", var.name))
    error_message = "name must be lowercase alphanumeric + hyphens, 3-37 characters, starting and ending alphanumeric."
  }

  nullable = false
}

variable "name_override" {
  description = "Escape hatch: use this exact bucket name verbatim, skipping <name>-<account_id>-<region> composition (externally-dictated names). The composed-name length/charset precondition still applies to the override."
  type        = string
  default     = null
}

variable "shard_prefix_enabled" {
  description = "Opt-in: prepend a stable 5-character random lowercase-alphanumeric prefix to the composed bucket name (<shard>-<name>-<account_id>-<region>) for key-distribution/sharding. Toggling this after creation renames and therefore REPLACES the bucket."
  type        = bool
  default     = false
  nullable    = false
}

variable "account_id" {
  description = "12-digit AWS account ID, composed into the bucket name for global uniqueness + provenance. Terragrunt-injected in production; from the shared var-file in tests."
  type        = string
  nullable    = false
}

variable "region" {
  description = "AWS region, composed into the bucket name for global uniqueness + provenance. Terragrunt-injected in production; from the shared var-file in tests."
  type        = string
  nullable    = false
}

#--------------------------------------------------------------
# Security baseline knobs (DESIGN-0019 F2 — fixed controls have no
# variable at all: PAB, BucketOwnerEnforced, the TLS policy denies)
#--------------------------------------------------------------

variable "encryption" {
  description = "Server-side encryption. mode \"kms\" (default) = SSE-KMS with the AWS-managed aws/s3 key + bucket key, or a CMK via kms_key_arn (required for cross-account consumers — the aws/s3 key cannot be policy-edited). mode \"s3\" = SSE-S3/AES256 (the access-logs sink only — log delivery does not write to KMS targets). kms_key_arn with mode \"s3\" fails at plan."
  type = object({
    mode        = optional(string, "kms")
    kms_key_arn = optional(string)
  })
  default = {}

  validation {
    condition     = contains(["kms", "s3"], var.encryption.mode)
    error_message = "encryption.mode must be \"kms\" or \"s3\"."
  }

  nullable = false
}

variable "versioning_enabled" {
  description = "Enable bucket versioning. Off by default — an explicit operator decision (INV-0009 F2; cost + per-stack opt-in durability, noted against the CIS default-on nudge)."
  type        = bool
  default     = false
  nullable    = false
}

variable "force_destroy" {
  description = "Allow destroy to delete a non-empty bucket. Off by default — the baseline treats data loss as opt-in; test fixtures set it true for teardown."
  type        = bool
  default     = false
  nullable    = false
}

variable "abort_incomplete_multipart_days" {
  description = "Days after initiation before an incomplete multipart upload is aborted (baseline hygiene rule — abandoned MPUs accrue invisible storage cost)."
  type        = number
  default     = 7

  validation {
    condition     = var.abort_incomplete_multipart_days >= 1
    error_message = "abort_incomplete_multipart_days must be at least 1."
  }

  nullable = false
}

variable "extra_lifecycle_rules" {
  description = "Additional lifecycle rules appended after the baseline MPU-abort rule (e.g. the access-logs sink's retention expiration; a staging-prefix expiry). prefix null = whole bucket."
  type = list(object({
    id                                 = string
    enabled                            = optional(bool, true)
    prefix                             = optional(string)
    expiration_days                    = optional(number)
    noncurrent_version_expiration_days = optional(number)
  }))
  default  = []
  nullable = false
}

variable "tags" {
  description = "Tags applied to every taggable resource in the module."
  type        = map(string)
  default     = {}
  nullable    = false
}

#--------------------------------------------------------------
# Bucket policy inputs (DESIGN-0019 F2 + OQ 4b)
#--------------------------------------------------------------

variable "allowed_vpc_endpoint_ids" {
  description = "Opt-in VPCE-only restriction (INV-0009 OQ 6): non-empty adds a deny-unless-aws:SourceVpce-in-list statement (reserved sid DenyOutsideVpce). CAUTION: locks out console and any non-VPCE access path — including the deployer role unless the deploy path rides a listed endpoint. Default [] = no restriction."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "internal_policy_statements" {
  description = "Purpose-module statement injection (DESIGN-0019 OQ 4b — additive-only; carries any operator additional_policy_statements the purpose module passes through). Statements append after the baseline denies and can never shadow them: the reserved sids (DenyInsecureTransport, DenyOldTls, DenyOutsideVpce) are rejected at plan. resource_suffixes are relative to the bucket ARN (\"\" = the bucket, \"/*\" = objects) — an input cannot reference this module's own bucket_arn output."
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

  validation {
    condition = alltrue([
      for s in var.internal_policy_statements :
      !contains(["DenyInsecureTransport", "DenyOldTls", "DenyOutsideVpce"], s.sid)
    ])
    error_message = "internal_policy_statements must not reuse the reserved baseline sids (DenyInsecureTransport, DenyOldTls, DenyOutsideVpce) — the merge is additive-only; injected statements can never shadow or replace the baseline."
  }

  validation {
    condition = alltrue([
      for s in var.internal_policy_statements : can(regex("^[A-Za-z0-9]+$", s.sid))
    ])
    error_message = "Every injected statement needs an alphanumeric Sid (the IAM policy Sid charset) — the sid is how plan suites and the reserved-sid guard identify statements."
  }

  nullable = false
}
