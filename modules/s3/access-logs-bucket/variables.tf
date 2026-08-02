#--------------------------------------------------------------
# Inputs — deliberately tiny (the zero-configuration singleton).
# The security baseline has no knobs here: SSE-S3, versioning off,
# and the delivery grant are pinned in main.tf (F3).
#--------------------------------------------------------------

variable "name" {
  description = "Logical bucket name, defaulting to \"access-logs\" (OQ 3a) so the per-region singleton is literally zero-configuration: bucket access-logs-<account_id>-<region> at live stack path s3/access-logs. Override only for a non-default sink deployed at its own stack path."
  type        = string
  default     = "access-logs"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,35}[a-z0-9]$", var.name))
    error_message = "name must be lowercase alphanumeric + hyphens, 3-37 characters, starting and ending alphanumeric."
  }

  nullable = false
}

variable "name_override" {
  description = "Escape hatch: use this exact bucket name verbatim, skipping composition (externally-dictated names)."
  type        = string
  default     = null
}

variable "shard_prefix_enabled" {
  description = "Opt-in: prepend a stable 5-character random prefix to the composed bucket name (destructive to toggle after creation — the bucket is replaced)."
  type        = bool
  default     = false
  nullable    = false
}

variable "account_id" {
  description = "12-digit AWS account ID — composed into the bucket name AND the aws:SourceAccount condition of the log-delivery grant. Terragrunt-injected in production."
  type        = string
  nullable    = false
}

variable "region" {
  description = "AWS region, composed into the bucket name. Terragrunt-injected in production."
  type        = string
  nullable    = false
}

variable "log_retention_days" {
  description = "Days before delivered log objects expire (OQ 1a: default 90 — access logs are operational exhaust; unbounded growth is the real foot-gun). null disables expiration entirely (retain forever)."
  type        = number
  default     = 90

  validation {
    condition     = var.log_retention_days == null || try(var.log_retention_days >= 1, false)
    error_message = "log_retention_days must be null (retain forever) or at least 1."
  }
}

variable "force_destroy" {
  description = "Allow destroy to delete the sink with logs still in it. Off by default; test fixtures set it true for teardown."
  type        = bool
  default     = false
  nullable    = false
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
  nullable    = false
}
