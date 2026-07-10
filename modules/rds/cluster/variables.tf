#--------------------------------------------------------------
# Required inputs
#--------------------------------------------------------------

variable "region" {
  description = "AWS region for the cluster + the S3 backend hosting the VPC remote state."
  type        = string
  nullable    = false
}

variable "remote_state_bucket" {
  description = "S3 bucket holding the VPC stack's terraform state. The module reads <region>/vpc/<vpc_name>/terraform.tfstate for vpc_id + private_subnet_ids (per IMPL-0007 Q1)."
  type        = string
  nullable    = false
}

variable "vpc_name" {
  description = "VPC name used to compose the remote-state key. Must match the VPC stack's identifier."
  type        = string
  nullable    = false
}

variable "identifier_prefix" {
  description = "Stable cluster identifier (also used for the subnet group, security group, KMS alias, and parameter group name prefixes). Must satisfy AWS RDS identifier shape: lowercase, 1-63 chars, starts with a letter, ends with letter or digit, hyphens permitted internally."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.identifier_prefix))
    error_message = "identifier_prefix must match ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ (lowercase, 1-63 chars, starts with letter, hyphens internal only)."
  }

  nullable = false
}

variable "engine" {
  description = "Aurora engine: 'aurora-postgresql' or 'aurora-mysql'. The module rejects non-Aurora engines (single-instance postgres/mysql belong to modules/rds/instance)."
  type        = string

  validation {
    condition     = can(regex("^aurora-(postgresql|mysql)$", var.engine))
    error_message = "engine must be 'aurora-postgresql' or 'aurora-mysql'."
  }

  nullable = false
}

variable "instance_class" {
  description = "Aurora instance class for the writer (e.g. 'db.r6g.large' for prod, 'db.t4g.medium' for dev). Required with no default — sizing is workload- and cost-specific (DESIGN-0013 Q2). NOT 'db.serverless' (that is the modules/rds/serverless module)."
  type        = string
  nullable    = false
}

#--------------------------------------------------------------
# Optional inputs
#--------------------------------------------------------------

variable "engine_version" {
  description = "Optional engine version pin (e.g. '16', '16.4', '8.0'). When null, AWS picks the engine's default at apply time and the parameter family lookup falls back to the default major map in locals.tf (per IMPL-0007 Q3)."
  type        = string
  default     = null

  validation {
    condition     = var.engine_version == null || can(regex("^(\\d+\\.\\d+|\\d+)$", var.engine_version))
    error_message = "engine_version must be null or match ^(\\d+\\.\\d+|\\d+)$ (e.g. '16', '16.4', '8.0'). Stricter gating happens at the parameter-family precondition."
  }
}

variable "storage_type" {
  description = "Optional Aurora storage type. Null (default) = Aurora Standard; 'aurora' is the explicit Standard value; 'aurora-iopt1' is I/O-Optimized (no per-request I/O charges, ~30% higher instance/storage rate — for cost-conscious high-I/O clusters). (DESIGN-0013 Q3.)"
  type        = string
  default     = null

  validation {
    condition     = var.storage_type == null || contains(["aurora", "aurora-iopt1"], var.storage_type)
    error_message = "storage_type must be null (Aurora Standard), \"aurora\" (Standard), or \"aurora-iopt1\" (I/O-Optimized)."
  }
}

variable "backtrack_window" {
  description = "Aurora MySQL Backtrack target window in seconds (0 = disabled, default). Aurora-MySQL-only — a precondition on the cluster rejects non-zero values for aurora-postgresql (DESIGN-0013 Q4). Max 259200 (72h)."
  type        = number
  default     = 0

  validation {
    condition     = var.backtrack_window >= 0
    error_message = "backtrack_window must be >= 0 (seconds; 0 disables Backtrack)."
  }
}

variable "enabled_cloudwatch_logs_exports" {
  description = "List of log types to export to CloudWatch Logs. Default [] (off) — log exports cost CloudWatch ingestion and the right set is engine-specific (e.g. [\"postgresql\"] for aurora-postgresql; [\"audit\",\"error\",\"general\",\"slowquery\"] for aurora-mysql). (DESIGN-0013 Q6.)"
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "Optional caller-supplied KMS key ARN for cluster storage encryption + master user secret encryption. When null (default), the module creates a dedicated key + alias internally. Same key is used for both encryptions (per IMPL-0007 Q12)."
  type        = string
  default     = null
}

variable "allowed_consumer_sg_ids" {
  description = "Security group IDs whose members may reach the cluster on the engine's default port. Empty list (default) leaves the cluster reachable from nowhere — operators add ingress deliberately."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for sg in var.allowed_consumer_sg_ids : can(regex("^sg-[a-f0-9]+$", sg))])
    error_message = "Each allowed_consumer_sg_ids entry must match ^sg-[a-f0-9]+$ (AWS security group ID shape)."
  }
}

variable "iam_database_authentication_enabled" {
  description = "Opt-in IAM database authentication. When true, consumers obtain a connection token via `aws rds generate-db-auth-token` (composable with the SG ingress gate — limits authentication, not reachability)."
  type        = bool
  default     = false
}

variable "manage_master_user_password" {
  description = "When true (default), AWS provisions and rotates the master user password in Secrets Manager. The secret ARN is emitted via the master_user_secret_arn output. Opt-out is documented as an escape hatch for operators migrating from a pre-existing secret."
  type        = bool
  default     = true
}

variable "master_username" {
  description = "Master user name created on the cluster. Default 'admin' for both engines (per IMPL-0007 Q4 — single default, not per-engine; override per cluster if you prefer 'postgres' or another value)."
  type        = string
  default     = "admin"
}

variable "database_name" {
  description = "Optional initial database created on cluster startup. Null (default) leaves the cluster without an initial database; consumers create their schemas via Flyway/Liquibase/Atlas (per DESIGN-0007 Non-Goals — module manages infrastructure, not schema)."
  type        = string
  default     = null
}

variable "backup_retention_period" {
  description = "Days to retain automated backups. Range: 1 - 35. Default 7 (matches AWS RDS default)."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be in the range [1, 35] (AWS RDS hard bounds)."
  }
}

variable "preferred_backup_window" {
  description = "Daily UTC window during which automated backups occur. Format: HH:MM-HH:MM. Default 02:00-03:00 (off-peak in most US timezones)."
  type        = string
  default     = "02:00-03:00"
}

variable "preferred_maintenance_window" {
  description = "Weekly UTC window during which AWS applies maintenance + engine-minor upgrades. Format: ddd:HH:MM-ddd:HH:MM. Default sun:04:00-sun:05:00."
  type        = string
  default     = "sun:04:00-sun:05:00"
}

variable "deletion_protection" {
  description = "When true (default), the cluster cannot be destroyed via the AWS API until this flag is flipped to false in a deliberate operator plan. Matches the org-registry module's safety posture."
  type        = bool
  default     = true
}

variable "publicly_accessible" {
  description = "When true, the cluster instance gets a public DNS endpoint. Default false (private-subnet-only)."
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "When true, modifications apply immediately instead of waiting for the maintenance window. Default false (AWS-recommended posture; prevents accidental cluster reboots from benign tag/parameter changes)."
  type        = bool
  default     = false
}

variable "auto_minor_version_upgrade" {
  description = "When true (default), AWS applies engine-minor upgrades automatically during the maintenance window. Engine-major upgrades remain explicit operator PRs (bumping var.engine_version)."
  type        = bool
  default     = true
}

variable "parameter_family" {
  description = "Optional parameter group family override (e.g. 'aurora-postgresql16'). When null (default), resolved from var.engine + var.engine_version via the static parameter_family_map in locals.tf (per DESIGN-0007 Q3 / IMPL-0007 Q3)."
  type        = string
  default     = null
}

variable "final_snapshot_identifier" {
  description = "Snapshot identifier captured at cluster destroy time. Required (non-null) when skip_final_snapshot = false — enforced via a precondition on the cluster resource (per IMPL-0007 Q9). Supply at destroy time via `-var 'final_snapshot_identifier=...'`."
  type        = string
  default     = null
}

variable "skip_final_snapshot" {
  description = "When true, skips the final snapshot at cluster destroy. Default false — operators MUST supply var.final_snapshot_identifier at destroy time unless they flip this to true."
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = "Opt-in Performance Insights on the writer instance. Default false (per IMPL-0007 Q6 — conservative on cost; caller opts in). When true, PI uses local.kms_key_arn for encryption."
  type        = bool
  default     = false
}

variable "enhanced_monitoring_interval" {
  description = "Seconds between Enhanced Monitoring data points (1, 5, 10, 15, 30, 60). Default 0 (disabled, per IMPL-0007 Q6). Setting > 0 requires var.enhanced_monitoring_role_arn."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.enhanced_monitoring_interval)
    error_message = "enhanced_monitoring_interval must be one of 0, 1, 5, 10, 15, 30, 60 (AWS RDS hard bounds)."
  }
}

variable "enhanced_monitoring_role_arn" {
  description = "IAM role ARN granting RDS permission to send Enhanced Monitoring metrics to CloudWatch. Caller-supplied — the module does NOT provision this role (per IMPL-0007 Q6 / module-boundary policy). Required when enhanced_monitoring_interval > 0."
  type        = string
  default     = null
}

variable "promotion_tier" {
  description = "Failover priority tier for the writer instance (0-15; lower = higher priority). Default 0 — the writer is the highest-priority failover target. The read-replica module's readers default to tier 15 so they never outrank the writer (DESIGN-0013 Q1 / DESIGN-0014 Q2)."
  type        = number
  default     = 0

  validation {
    condition     = var.promotion_tier >= 0 && var.promotion_tier <= 15
    error_message = "promotion_tier must be in the range [0, 15]."
  }
}

variable "tags" {
  description = "AWS resource tags applied to every taggable resource in the module (cluster, instance, subnet group, security group, parameter groups, KMS key)."
  type        = map(string)
  default     = {}
}
