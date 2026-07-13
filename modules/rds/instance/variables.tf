#--------------------------------------------------------------
# Required inputs
#--------------------------------------------------------------

variable "region" {
  description = "AWS region for the instance + the S3 backend hosting the VPC remote state."
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
  description = "Stable instance identifier (also used for the subnet group, security group, KMS alias, and parameter group name prefixes). Must satisfy AWS RDS identifier shape: lowercase, 1-63 chars, starts with a letter, ends with letter or digit, hyphens permitted internally."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.identifier_prefix))
    error_message = "identifier_prefix must match ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ (lowercase, 1-63 chars, starts with letter, hyphens internal only)."
  }

  nullable = false
}

variable "engine" {
  description = "Non-Aurora RDS engine: 'postgres' or 'mysql'. The module rejects Aurora engines (those belong to the modules/rds/serverless and modules/rds/cluster modules)."
  type        = string

  validation {
    condition     = can(regex("^(postgres|mysql)$", var.engine))
    error_message = "engine must be 'postgres' or 'mysql' (Aurora engines belong to modules/rds/serverless or modules/rds/cluster)."
  }

  nullable = false
}

variable "instance_class" {
  description = "RDS instance class (e.g. 'db.t4g.medium' for dev, 'db.r6g.large' for prod). Required with no default — sizing is workload- and cost-specific (DESIGN-0012 §Input surface)."
  type        = string
  nullable    = false
}

variable "allocated_storage" {
  description = "Allocated storage in GiB for the instance. Required with no default — the right floor is workload-specific. Minimum 20 GiB (AWS RDS floor for the supported engines)."
  type        = number

  validation {
    condition     = var.allocated_storage >= 20
    error_message = "allocated_storage must be >= 20 (the AWS RDS minimum for postgres/mysql general-purpose storage)."
  }

  nullable = false
}

#--------------------------------------------------------------
# Optional inputs
#--------------------------------------------------------------

variable "engine_version" {
  description = "Optional engine version pin (e.g. '18', '16.4', '8.0'). When null, AWS picks the engine's default at apply time and the parameter family lookup falls back to the default major map in locals.tf (per DESIGN-0012 Q8)."
  type        = string
  default     = null

  validation {
    condition     = var.engine_version == null || can(regex("^(\\d+\\.\\d+|\\d+)$", var.engine_version))
    error_message = "engine_version must be null or match ^(\\d+\\.\\d+|\\d+)$ (e.g. '18', '16.4', '8.0'). Stricter gating happens at the parameter-family precondition."
  }
}

variable "max_allocated_storage" {
  description = "Optional upper bound (GiB) for RDS storage autoscaling. Null (default) disables autoscaling — storage stays at allocated_storage. When set, must be >= allocated_storage (enforced via a precondition on the instance). The AWS provider suppresses the allocated_storage diff once autoscaling grows the volume, so no ignore_changes is needed (DESIGN-0012 Q3 / IMPL-0011 Phase 6)."
  type        = number
  default     = null
}

variable "storage_type" {
  description = "EBS storage type for the instance. Default 'gp3' (current-generation general-purpose SSD). 'gp2' is the previous generation; 'io2' is provisioned-IOPS (requires var.iops, enforced via a precondition)."
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp2", "gp3", "io2"], var.storage_type)
    error_message = "storage_type must be one of 'gp2', 'gp3', or 'io2'."
  }
}

variable "iops" {
  description = "Provisioned IOPS for the storage volume. Null (default) uses the storage type's baseline. Required (non-null) when storage_type = 'io2' (enforced via a precondition); also valid for gp3 above the free-IOPS baseline."
  type        = number
  default     = null
}

variable "storage_throughput" {
  description = "Storage throughput in MiB/s (gp3 only). Null (default) uses the gp3 baseline. AWS rejects this attribute for gp2/io2 — set it only alongside storage_type = 'gp3'."
  type        = number
  default     = null
}

variable "multi_az" {
  description = "When true, RDS provisions a synchronous standby in a second AZ for HA. Default false (single-AZ; matches DESIGN-0007's cost posture — operators opt into HA per instance, DESIGN-0012 Q4)."
  type        = bool
  default     = false
}

variable "db_port" {
  description = "Optional TCP port override. Null (default) uses the engine's default port (5432 postgres, 3306 mysql) resolved in locals.tf. The SG ingress rules follow the resolved port."
  type        = number
  default     = null

  validation {
    condition     = var.db_port == null || (var.db_port >= 1 && var.db_port <= 65535)
    error_message = "db_port must be null or in the range [1, 65535]."
  }
}

variable "database_name" {
  description = "Optional initial database created on instance startup. Null (default) leaves the instance without an initial database; consumers create their schemas via Flyway/Liquibase/Atlas (per DESIGN-0007 Non-Goals — module manages infrastructure, not schema)."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "Optional caller-supplied KMS key ARN for instance storage encryption + master user secret encryption. When null (default), the module creates a dedicated key + alias internally. Same key is used for both encryptions (per IMPL-0007 Q12)."
  type        = string
  default     = null
}

variable "allowed_consumer_sg_ids" {
  description = "Security group IDs whose members may reach the instance on the resolved port. Empty list (default) leaves the instance reachable from nowhere — operators add ingress deliberately."
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
  description = "Master user name created on the instance. Default 'admin' for both engines (per IMPL-0007 Q4 — single default, not per-engine; override per instance if you prefer 'postgres' or another value)."
  type        = string
  default     = "admin"
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
  description = "When true (default), the instance cannot be destroyed via the AWS API until this flag is flipped to false in a deliberate operator plan. Matches the org-registry module's safety posture."
  type        = bool
  default     = true
}

variable "publicly_accessible" {
  description = "When true, the instance gets a public DNS endpoint. Default false (private-subnet-only)."
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "When true, modifications apply immediately instead of waiting for the maintenance window. Default false (AWS-recommended posture; prevents accidental instance reboots from benign tag/parameter changes)."
  type        = bool
  default     = false
}

variable "auto_minor_version_upgrade" {
  description = "When true (default), AWS applies engine-minor upgrades automatically during the maintenance window. Engine-major upgrades remain explicit operator PRs (bumping var.engine_version)."
  type        = bool
  default     = true
}

variable "parameter_family" {
  description = "Optional parameter group family override (e.g. 'postgres18'). When null (default), resolved from var.engine + var.engine_version via the static parameter_family_map in locals.tf (per DESIGN-0012 §Parameter family)."
  type        = string
  default     = null
}

variable "ca_cert_identifier" {
  description = "Optional RDS CA certificate identifier for the instance's server certificate (e.g. 'rds-ca-rsa2048-g1'). Null (default) uses the AWS-account default CA (DESIGN-0012 Q6)."
  type        = string
  default     = null
}

variable "final_snapshot_identifier" {
  description = "Snapshot identifier captured at instance destroy time. Required (non-null) when skip_final_snapshot = false — enforced via a precondition on the instance (per IMPL-0007 Q9). Supply at destroy time via `-var 'final_snapshot_identifier=...'`."
  type        = string
  default     = null
}

variable "skip_final_snapshot" {
  description = "When true, skips the final snapshot at instance destroy. Default false — operators MUST supply var.final_snapshot_identifier at destroy time unless they flip this to true."
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = "Opt-in Performance Insights on the instance. Default false (per IMPL-0007 Q6 — conservative on cost; caller opts in). When true, PI uses local.kms_key_arn for encryption."
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

variable "tags" {
  description = "AWS resource tags applied to every taggable resource in the module (instance, subnet group, security group, parameter group, KMS key)."
  type        = map(string)
  default     = {}
}
