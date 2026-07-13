#--------------------------------------------------------------
# Computed locals
#--------------------------------------------------------------

locals {
  # KMS key ARN — BYO (var.kms_key_arn != null) OR module-managed
  # (aws_kms_key.this[0] from kms.tf, Phase 3). try() keeps Phase 2
  # plan-valid before Phase 3 lands and after BYO short-circuits the
  # count gate. Same coalesce-with-try pattern used in
  # modules/rds/serverless/locals.tf.
  kms_key_arn = coalesce(var.kms_key_arn, try(aws_kms_key.this[0].arn, null))

  kms_alias_name = "alias/${var.identifier_prefix}-rds-instance"

  # Static engine + major -> non-Aurora parameter family lookup (per
  # DESIGN-0012 §Parameter family). Engine-family drift is rare;
  # Renovate bumps this map as new engine majors GA.
  #
  # Postgres families are keyed by major (18, 17, 16); MySQL families
  # are keyed by major.minor (8.4, 8.0). The lookup key is built
  # engine-aware below.
  #
  # TODO: revisit data.aws_rds_engine_version when family drift becomes
  # painful enough to justify a data-source lookup per plan.
  parameter_family_map = {
    "postgres:18" = "postgres18"
    "postgres:17" = "postgres17"
    "postgres:16" = "postgres16"
    "mysql:8.4"   = "mysql8.4"
    "mysql:8.0"   = "mysql8.0"
  }

  # Per-engine default version segment used when var.engine_version is
  # null (per DESIGN-0012 Q8 — newest GA majors). The shape matches what
  # the family map expects: bare major for postgres, major.minor for
  # MySQL. Renovate bumps as new engine versions GA.
  default_major_map = {
    "postgres" = "18"
    "mysql"    = "8.4"
  }

  # When var.engine_version is non-null, normalize it to the family-map's
  # expected shape: postgres takes the leading integer; MySQL keeps
  # major.minor verbatim. When null, fall back to the default-major map.
  engine_version_normalized = var.engine_version != null ? (var.engine == "postgres" ? split(".", var.engine_version)[0] : var.engine_version) : local.default_major_map[var.engine]

  engine_family_lookup_key = "${var.engine}:${local.engine_version_normalized}"

  resolved_parameter_family = coalesce(var.parameter_family, lookup(local.parameter_family_map, local.engine_family_lookup_key, null))

  # Engine default TCP port — used by the SG ingress rules in Phase 4 and
  # the instance port in Phase 6.
  engine_default_port_map = {
    "postgres" = 5432
    "mysql"    = 3306
  }

  engine_default_port = local.engine_default_port_map[var.engine]
}
