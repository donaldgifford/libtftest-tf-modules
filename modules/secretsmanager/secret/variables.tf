#--------------------------------------------------------------
# Required inputs
#--------------------------------------------------------------

variable "name" {
  description = "Logical secret name. Seeds the aws_secretsmanager_secret name_prefix (the created secret is <name>-<random-suffix>) and is the <name> segment of the ADR-0020 remote-state key consumers compose: <account_name>/<region>/secrets/<name>/terraform.tfstate. The state-key coupling is to THIS value, not the suffixed physical secret name."

  type = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,62}[a-z0-9]$", var.name))
    error_message = "name must match ^[a-z][a-z0-9-]{1,62}[a-z0-9]$ (lowercase, 3-64 chars, starts with a letter, ends with a letter or digit, hyphens internal only)."
  }

  nullable = false
}

#--------------------------------------------------------------
# Secret content (DESIGN-0020 OQ 1a)
#
# `username` doubles as the content-shape switch: set -> the secret
# value is the RDS-format DB-credentials JSON
# {"username": ..., "password": <generated>} that rds/proxy requires of
# any secret it fronts (INV-0010 F5); null (default) -> the value is
# the bare generated password string.
#--------------------------------------------------------------

variable "username" {
  description = "Non-secret username half of a DB-credential pair. When set, the secret value is the RDS-format JSON {\"username\", \"password\"}; when null (default), the value is the bare generated password. Also emitted as a (non-secret) output for consumer sanity checks."
  type        = string
  default     = null

  validation {
    condition     = var.username == null || can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.username))
    error_message = "username, when set, must match ^[a-zA-Z][a-zA-Z0-9_]{0,62}$ (1-63 chars, starts with a letter, alphanumerics + underscore — the RDS master-username shape)."
  }
}

variable "secret_string_version" {
  description = "Version gate for the write-only secret value (INV-0010 F4). The generated password is only SENT when this integer changes: leave it and applies are no-ops (the in-memory regeneration is discarded unsent); bump it and exactly one new password lands in the secret. Rotation = bump this number. Consumers that copy the value onward do NOT pick the rotation up automatically."
  type        = number
  default     = 1

  validation {
    condition     = var.secret_string_version >= 1 && floor(var.secret_string_version) == var.secret_string_version
    error_message = "secret_string_version must be a whole number >= 1 (it is a monotonic version gate, not a count)."
  }
}

#--------------------------------------------------------------
# Password generation (DESIGN-0020 OQ 5a)
#
# Defaults are RDS-legal so the DB-credentials shape works out of the
# box for both postgres and mysql: master passwords forbid '/', '@',
# '"', and spaces, so the default special-character set excludes them.
#--------------------------------------------------------------

variable "password_length" {
  description = "Length of the generated password."
  type        = number
  default     = 32

  validation {
    condition     = var.password_length >= 16
    error_message = "password_length must be >= 16."
  }
}

variable "password_override_special" {
  description = "Special characters the generator may use. The default is the RDS-legal set (no '/', '@', '\"', or space) so the DB-credentials shape works for postgres and mysql master passwords without per-consumer tuning."
  type        = string
  default     = "!#$%&*()-_=+[]{}<>:?"
}

#--------------------------------------------------------------
# Secret lifecycle
#--------------------------------------------------------------

variable "secret_recovery_window_days" {
  description = "Recovery window Secrets Manager holds a deleted secret for. 0 = immediate permanent deletion (test teardown / break-glass); otherwise 7-30 days (AWS API constraint). NB: the secret NAME stays reserved for the length of this window — which is why the module uses name_prefix (DESIGN-0020 resolution 5a)."
  type        = number
  default     = 30

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 (immediate deletion) or between 7 and 30."
  }
}

#--------------------------------------------------------------
# Encryption (DESIGN-0020 OQ 2, resolved Other)
#
# Default = the AWS-managed aws/secretsmanager key (kms_key_arn null,
# resource kms_key_id unset); BYO CMK overrides. The kms_key_arn OUTPUT
# faithfully reports null in the managed case — downstream (rds/proxy)
# keys off that: non-null -> exact kms:Decrypt scoping, null -> the
# ViaService-fenced wildcard path. Cross-account reads REQUIRE the BYO
# CMK path (the managed key cannot cross accounts).
#--------------------------------------------------------------

variable "kms_key_arn" {
  description = "Optional CMK ARN encrypting the secret. Null (default) uses the AWS-managed aws/secretsmanager key — zero cost, but cross-account reads are impossible and consumers see a null kms_key_arn output (rds/proxy then uses its ViaService-fenced wildcard). Set a CMK for cross-account reads or exact downstream kms:Decrypt scoping; granting the key policy is out of module scope."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:", var.kms_key_arn))
    error_message = "kms_key_arn, when set, must be a KMS key ARN (arn:aws:kms:...)."
  }
}

#--------------------------------------------------------------
# Metadata
#--------------------------------------------------------------

variable "description" {
  description = "Description on the Secrets Manager secret."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the secret."
  type        = map(string)
  default     = {}
}
