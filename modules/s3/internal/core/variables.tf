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
