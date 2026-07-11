#--------------------------------------------------------------
# Required inputs — pointers + the replicas map
#
# Under remote-state composition (DESIGN-0014 / ADR-0001) the
# DB-derived values (engine, engine version, subnet group, parameter
# group, security group, KMS) are NOT inputs — they are the cluster's,
# read from its remote state in main.tf/locals.tf (Phase 2). The
# required inputs below are just the pointers needed to locate that
# state plus the typed replicas map that drives the reader for_each.
#--------------------------------------------------------------

variable "region" {
  description = "AWS region for the reader instances and for the S3 backend hosting the cluster module's remote state."
  type        = string
  nullable    = false
}

variable "remote_state_bucket" {
  description = "S3 bucket holding the cluster module's terraform state. This module reads <region>/rds/cluster/<cluster_identifier>/terraform.tfstate for the cluster's outputs (DESIGN-0014 / ADR-0001 — remote-state composition)."
  type        = string
  nullable    = false
}

variable "cluster_identifier" {
  description = "Identifier of the existing Aurora cluster the readers attach to (the cluster module's var.identifier_prefix). Used both to compose the cluster remote-state key and to attach each reader via cluster_identifier."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.cluster_identifier))
    error_message = "cluster_identifier must match ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ (lowercase, 1-63 chars, starts with letter, hyphens internal only — AWS RDS identifier shape)."
  }

  nullable = false
}

variable "identifier_prefix" {
  description = "Stable prefix for each reader instance identifier. Each reader is named <identifier_prefix>-replica-<key>. Must satisfy the AWS RDS identifier shape (lowercase, starts with a letter); keep it short enough that the composed identifier stays within 63 chars (guarded by a precondition)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.identifier_prefix))
    error_message = "identifier_prefix must match ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ (lowercase, 1-63 chars, starts with letter, hyphens internal only)."
  }

  nullable = false
}

variable "replicas" {
  description = "Map of reader instances to create, keyed by a short suffix that composes the reader identifier (<identifier_prefix>-replica-<key>). Empty map = zero readers. Each value is a hybrid object: required instance_class plus optional tuning attributes (availability_zone, promotion_tier [default 15 — below the writer's tier 0], performance_insights_enabled, monitoring_interval + monitoring_role_arn, auto_minor_version_upgrade, publicly_accessible). Engine, engine version, subnet group, and parameter group are inherited from the cluster remote state — not settable per reader."
  type = map(object({
    instance_class               = string
    availability_zone            = optional(string)
    promotion_tier               = optional(number, 15)
    performance_insights_enabled = optional(bool, false)
    monitoring_interval          = optional(number, 0)
    monitoring_role_arn          = optional(string)
    auto_minor_version_upgrade   = optional(bool, true)
    publicly_accessible          = optional(bool, false)
  }))

  # Q7 — each key is interpolated into <identifier_prefix>-replica-<key>,
  # so it must be RDS-identifier-safe. Key shape + length are
  # self-contained (reference only var.replicas); the exact composed-≤63
  # guard (which needs var.identifier_prefix) is a precondition in
  # replicas.tf per the validation-split doctrine (terraform >= 1.1).
  validation {
    condition     = alltrue([for k in keys(var.replicas) : can(regex("^[a-z0-9-]+$", k))])
    error_message = "Each replicas key must match ^[a-z0-9-]+$ (lowercase letters, digits, hyphens) — it is interpolated into the reader identifier <identifier_prefix>-replica-<key>."
  }

  validation {
    condition     = alltrue([for k in keys(var.replicas) : length(k) >= 1 && length(k) <= 30])
    error_message = "Each replicas key must be 1-30 chars so the composed identifier <identifier_prefix>-replica-<key> stays within the AWS 63-char RDS identifier limit."
  }

  validation {
    condition     = alltrue([for r in values(var.replicas) : r.promotion_tier >= 0 && r.promotion_tier <= 15])
    error_message = "Each replicas entry's promotion_tier must be in the range [0, 15] (lower = higher failover priority; readers default to 15, below the writer's 0)."
  }

  validation {
    condition     = alltrue([for r in values(var.replicas) : contains([0, 1, 5, 10, 15, 30, 60], r.monitoring_interval)])
    error_message = "Each replicas entry's monitoring_interval must be one of 0, 1, 5, 10, 15, 30, 60 (AWS RDS Enhanced Monitoring hard bounds; 0 disables)."
  }

  nullable = false
}

#--------------------------------------------------------------
# Optional inputs
#--------------------------------------------------------------

variable "apply_immediately" {
  description = "When true, reader modifications apply immediately instead of waiting for the maintenance window. Default false (AWS-recommended posture; prevents accidental reader reboots from benign changes)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "AWS resource tags applied to every reader instance in the module."
  type        = map(string)
  default     = {}
}
