#--------------------------------------------------------------
# Naming
#--------------------------------------------------------------

variable "name" {
  description = "Logical bucket name. Composed into the real bucket name as <name>-<account_id>-<region> (plus the optional shard prefix). Lowercase alphanumeric + hyphens, 3-37 chars, must start/end alphanumeric."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,35}[a-z0-9]$", var.name))
    error_message = "name must be lowercase alphanumeric + hyphens, 3-37 characters, starting and ending alphanumeric."
  }

  nullable = false
}

variable "name_override" {
  description = "Escape hatch: use this exact bucket name verbatim, skipping <name>-<account_id>-<region> composition (externally-dictated names)."
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
# Terragrunt-provided globals (IMPL-0015) — injected via includes in
# production regardless of use; the shared
# test/fixtures/terragrunt-inputs.tfvars stands in for tests.
#--------------------------------------------------------------

variable "account_name" {
  description = "Terragrunt account name — the <account_name> prefix of the reserved access-logs remote-state key this module composes (<account_name>/<region>/s3/access-logs/terraform.tfstate)."
  type        = string
  nullable    = false
}

variable "account_id" {
  description = "12-digit AWS account ID — composed into the bucket name and into the remote-state assume_role role_arn."
  type        = string
  nullable    = false
}

variable "region" {
  description = "AWS region — composed into the bucket name and the reserved access-logs remote-state key."
  type        = string
  nullable    = false
}

variable "remote_state_bucket" {
  description = "S3 bucket holding the fleet's terraform state. The default access-logging path reads the reserved sink key from it (ADR-0020)."
  type        = string
  nullable    = false
}

variable "remote_state_bucket_region" {
  description = "Region of the remote-state bucket itself (may differ from var.region — the state bucket is fleet-central)."
  type        = string
  nullable    = false
}

variable "deploy_role_name" {
  description = "Name of the IAM role Terraform assumes to read the remote-state bucket cross-account. Composed into the assume_role role_arn with account_id."
  type        = string
  nullable    = false
}

#--------------------------------------------------------------
# Access logging (DESIGN-0019 F4 — the tri-state)
#--------------------------------------------------------------

variable "access_logging" {
  description = "Server-access-logging tri-state. Default {} = look the fleet sink up at the reserved ADR-0020 key and log to it. target_bucket set = log to that explicit sink (no remote-state read). enabled = false = no logging (a deliberately log-less stack). prefix null = \"<this bucket's composed name>/\"."
  type = object({
    enabled       = optional(bool, true)
    target_bucket = optional(string)
    prefix        = optional(string)
  })
  default = {}

  validation {
    condition     = var.access_logging.enabled || (var.access_logging.target_bucket == null && var.access_logging.prefix == null)
    error_message = "access_logging.target_bucket / prefix require enabled = true — a disabled tri-state with a target or prefix is contradictory, not silently ignorable."
  }

  nullable = false
}

#--------------------------------------------------------------
# Baseline pass-throughs (resolved in the internal core)
#--------------------------------------------------------------

variable "kms_key_arn" {
  description = "Customer-managed KMS key for SSE-KMS, or null (default) for the AWS-managed aws/s3 key. A CMK is required when cross-account consumers must decrypt — the aws/s3 key cannot be policy-edited."
  type        = string
  default     = null
}

variable "versioning_enabled" {
  description = "Enable bucket versioning. Off by default — an explicit operator decision (INV-0009 F2)."
  type        = bool
  default     = false
  nullable    = false
}

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

variable "allowed_vpc_endpoint_ids" {
  description = "Opt-in VPCE-only restriction (INV-0009 OQ 6): non-empty adds the DenyOutsideVpce statement. CAUTION: locks out console and any non-VPCE access path. Default [] = no restriction."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "additional_policy_statements" {
  description = "Operator bucket-policy statements, appended additively after the baseline denies (DESIGN-0019 OQ 4b — these ADD grants/denies; they can never shadow or remove the baseline, and the reserved sids are rejected at plan by the core). resource_suffixes are relative to the bucket ARN (\"\" = the bucket, \"/*\" = objects)."
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
      !contains(["DenyInsecureTransport", "DenyOldTls", "DenyOutsideVpce"], s.sid)
    ])
    error_message = "additional_policy_statements must not reuse the reserved baseline sids (DenyInsecureTransport, DenyOldTls, DenyOutsideVpce) — the merge is additive-only; statements can never shadow or replace the baseline."
  }

  nullable = false
}

variable "tags" {
  description = "Tags applied to every taggable resource in the module."
  type        = map(string)
  default     = {}
  nullable    = false
}

#--------------------------------------------------------------
# Notification destinations (DESIGN-0019 OQ 5a — typed per-destination
# lists rather than one untyped map: each destination kind has its own
# ARN attribute on the singleton resource, and the types document the
# filter surface). At least one destination is required (precondition
# in notification.tf).
#
# The destination's OWN resource policy (SQS queue policy / SNS topic
# policy allowing s3.amazonaws.com from this bucket's ARN) belongs to
# the destination stack — this module only registers the wiring.
#--------------------------------------------------------------

variable "sqs_queues" {
  description = "SQS destinations for bucket notifications. id is the notification-configuration entry name (unique per bucket). events are S3 event types (e.g. [\"s3:ObjectCreated:*\"]). filter_prefix / filter_suffix scope the trigger; null = no filter."
  type = list(object({
    id            = string
    arn           = string
    events        = list(string)
    filter_prefix = optional(string)
    filter_suffix = optional(string)
  }))
  default = []

  validation {
    condition     = length(distinct([for q in var.sqs_queues : q.id])) == length(var.sqs_queues)
    error_message = "sqs_queues ids must be unique — the notification configuration is a per-bucket singleton and duplicate ids collide."
  }

  validation {
    condition     = alltrue([for q in var.sqs_queues : length(q.events) > 0])
    error_message = "Every sqs_queues entry needs at least one S3 event type."
  }

  nullable = false
}

variable "sns_topics" {
  description = "SNS destinations for bucket notifications. Same shape as sqs_queues; the topic's access policy must allow s3.amazonaws.com to publish from this bucket's ARN (owned by the topic's stack)."
  type = list(object({
    id            = string
    arn           = string
    events        = list(string)
    filter_prefix = optional(string)
    filter_suffix = optional(string)
  }))
  default = []

  validation {
    condition     = length(distinct([for t in var.sns_topics : t.id])) == length(var.sns_topics)
    error_message = "sns_topics ids must be unique — the notification configuration is a per-bucket singleton and duplicate ids collide."
  }

  validation {
    condition     = alltrue([for t in var.sns_topics : length(t.events) > 0])
    error_message = "Every sns_topics entry needs at least one S3 event type."
  }

  nullable = false
}

variable "eventbridge_enabled" {
  description = "Send all bucket events to EventBridge (no event-type or filter surface — EventBridge rules do the filtering downstream). Counts as a destination for the at-least-one requirement."
  type        = bool
  default     = false
  nullable    = false
}
