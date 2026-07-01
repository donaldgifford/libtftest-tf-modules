#--------------------------------------------------------------
# Required inputs — pointers
#
# Under remote-state composition (DESIGN-0010 Q3 / ADR-0001) the
# DB-derived values (secret ARN, DB security group, subnets, vpc_id,
# engine, identifier, IAM-auth flag) are NOT inputs — they are read
# from the target's remote state in main.tf/locals.tf (Phase 3). The
# required inputs below are just the pointers needed to locate that
# state plus the proxy's own name.
#--------------------------------------------------------------

variable "region" {
  description = "AWS region for the proxy and for the S3 backend hosting the target DB module's remote state."
  type        = string
  nullable    = false
}

variable "name" {
  description = "Name of the RDS Proxy (DESIGN-0010 Q4-a — explicit, operator-chosen). Must begin with a letter, contain only ASCII letters, digits, and hyphens, not end with a hyphen, and be 2-60 characters. AWS additionally rejects two consecutive hyphens at apply time."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,58}[a-zA-Z0-9]$", var.name))
    error_message = "name must match ^[a-zA-Z][a-zA-Z0-9-]{0,58}[a-zA-Z0-9]$ (begins with a letter, letters/digits/hyphens only, no trailing hyphen, 2-60 chars)."
  }

  nullable = false
}

variable "target_type" {
  description = "Discriminator selecting which data-tier module the proxy fronts: 'rds-instance' (single aws_db_instance), 'aurora-cluster' (Aurora provisioned), or 'serverless' (Aurora Serverless v2). Selects the remote-state key shape and whether the proxy target is keyed by db_instance_identifier or db_cluster_identifier."
  type        = string

  # V1 — discriminator hygiene (DESIGN-0010 V1).
  validation {
    condition     = contains(["rds-instance", "aurora-cluster", "serverless"], var.target_type)
    error_message = "target_type must be one of: rds-instance, aurora-cluster, serverless."
  }

  nullable = false
}

variable "target_identifier" {
  description = "Identifier of the target DB instance or cluster. Used both to compose the remote-state key (<region>/rds/<dir>/<target_identifier>/terraform.tfstate) and as the db_instance_identifier / db_cluster_identifier on the proxy target."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.target_identifier))
    error_message = "target_identifier must match ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ (lowercase, 1-63 chars, starts with letter, hyphens internal only — AWS RDS identifier shape)."
  }

  nullable = false
}

variable "remote_state_bucket" {
  description = "S3 bucket holding the target DB module's terraform state. The proxy reads <region>/rds/<dir>/<target_identifier>/terraform.tfstate for the target's outputs (DESIGN-0010 Q3 — remote-state composition)."
  type        = string
  nullable    = false
}

#--------------------------------------------------------------
# Optional inputs — proxy behaviour knobs
#--------------------------------------------------------------

variable "db_port" {
  description = "TCP port the proxy listens on and connects to the DB with. When null (default), derived from the target engine read from remote state (5432 for Postgres, 3306 for MySQL)."
  type        = number
  default     = null

  validation {
    condition     = var.db_port == null || (var.db_port >= 1 && var.db_port <= 65535)
    error_message = "db_port must be null or in the range [1, 65535]."
  }
}

variable "allowed_consumer_sg_ids" {
  description = "Security group IDs whose members may reach the proxy on the engine listener port. Empty list (default) leaves the proxy reachable from nowhere — operators add ingress deliberately. The proxy's own SG id is emitted as an output so it can be added to the DB module's allowed_consumer_sg_ids on a subsequent apply."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for sg in var.allowed_consumer_sg_ids : can(regex("^sg-[a-f0-9]+$", sg))])
    error_message = "Each allowed_consumer_sg_ids entry must match ^sg-[a-f0-9]+$ (AWS security group ID shape)."
  }
}

variable "require_tls" {
  description = "When true (default), the proxy requires TLS for client connections. Recommended on — clients connecting to the proxy endpoint must use TLS."
  type        = bool
  default     = true
}

variable "require_iam_auth" {
  description = "When true, client-to-proxy connections require IAM authentication (auth.iam_auth = REQUIRED); when false (default), DISABLED. Requires the target to have iam_database_authentication_enabled = true — enforced via a precondition (V4)."
  type        = bool
  default     = false
}

variable "idle_client_timeout" {
  description = "Seconds a client connection may sit idle before the proxy closes it. Range: 1 - 28800. Default 1800 (30 minutes, the AWS default)."
  type        = number
  default     = 1800

  validation {
    condition     = var.idle_client_timeout >= 1 && var.idle_client_timeout <= 28800
    error_message = "idle_client_timeout must be in the range [1, 28800] seconds."
  }
}

variable "create_read_only_endpoint" {
  description = "When true, create an additional READ_ONLY proxy endpoint routing to Aurora readers. Only valid for Aurora targets (aurora-cluster / serverless) — a precondition (V3) rejects it on rds-instance, which has no proxy reader routing. Default false."
  type        = bool
  default     = false
}

variable "max_connections_percent" {
  description = "Maximum percentage of the target's max_connections that the proxy may use for its connection pool. Range: 1 - 100. Default 100."
  type        = number
  default     = 100

  # V6 — coherent pool config (DESIGN-0010 V6).
  validation {
    condition     = var.max_connections_percent >= 1 && var.max_connections_percent <= 100
    error_message = "max_connections_percent must be in the range [1, 100]."
  }
}

variable "max_idle_connections_percent" {
  description = "Maximum percentage of max_connections_percent that the proxy keeps idle in the pool. Range: 0 - 100. Should not exceed max_connections_percent — a precondition (V6) enforces that cross-variable bound. Default 50."
  type        = number
  default     = 50

  # V6 — static bound; the max_idle <= max_connections cross-check is a precondition.
  validation {
    condition     = var.max_idle_connections_percent >= 0 && var.max_idle_connections_percent <= 100
    error_message = "max_idle_connections_percent must be in the range [0, 100]."
  }
}

variable "connection_borrow_timeout" {
  description = "Seconds a client waits to borrow a connection from the pool before timing out. Range: 0 - 3600 (0 = wait indefinitely is not used; AWS caps at 3600). Default 120."
  type        = number
  default     = 120

  # V7 — non-negative borrow timeout (DESIGN-0010 V7).
  validation {
    condition     = var.connection_borrow_timeout >= 0 && var.connection_borrow_timeout <= 3600
    error_message = "connection_borrow_timeout must be in the range [0, 3600] seconds."
  }
}

variable "session_pinning_filters" {
  description = "Connection-pinning filters to relax. The only AWS-supported value is 'EXCLUDE_VARIABLE_SETS' (avoids pinning on SET statements). Empty list (default) keeps all pinning behaviour."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for f in var.session_pinning_filters : contains(["EXCLUDE_VARIABLE_SETS"], f)])
    error_message = "Each session_pinning_filters entry must be 'EXCLUDE_VARIABLE_SETS' (the only AWS-supported filter)."
  }
}

variable "init_query" {
  description = "Optional SQL run on every new database connection the proxy opens (e.g. 'SET x=1; SET y=2'). Null (default) runs no init query."
  type        = string
  default     = null
}

variable "debug_logging" {
  description = "When true, the proxy logs detailed SQL to CloudWatch (useful for debugging, verbose + potentially sensitive). Default false."
  type        = bool
  default     = false
}

variable "tags" {
  description = "AWS resource tags applied to every taggable resource in the module (proxy, target group, endpoint, IAM role, security group)."
  type        = map(string)
  default     = {}
}
