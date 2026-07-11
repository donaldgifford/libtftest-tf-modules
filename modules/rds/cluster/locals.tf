#--------------------------------------------------------------
# Computed locals
#--------------------------------------------------------------

locals {
  # KMS key ARN — BYO (var.kms_key_arn != null) OR module-managed
  # (aws_kms_key.this[0] from kms.tf, Phase 3). try() keeps this
  # plan-valid before Phase 3 lands and after BYO short-circuits the
  # count gate. Same coalesce-with-try pattern used in
  # modules/rds/serverless/locals.tf.
  kms_key_arn = coalesce(var.kms_key_arn, try(aws_kms_key.this[0].arn, null))

  kms_alias_name = "alias/${var.identifier_prefix}-rds-cluster"

  # Static engine + major → Aurora parameter family lookup (per
  # DESIGN-0007 Q3 / IMPL-0007 Q3, IMPL-0012 Q2 — seeded to match the
  # shipped serverless module post-PR-#32 so the whole Aurora family
  # shares one version posture). Renovate bumps this map as new engine
  # majors GA.
  #
  # Postgres families are keyed by major (18, 17, 16, 15, 14); MySQL
  # families are keyed by major.minor (8.0). The lookup key is built
  # engine-aware below.
  #
  # TODO: revisit data.aws_rds_engine_version when family drift becomes
  # painful enough to justify a data-source lookup per plan.
  parameter_family_map = {
    "aurora-postgresql:18" = "aurora-postgresql18"
    "aurora-postgresql:17" = "aurora-postgresql17"
    "aurora-postgresql:16" = "aurora-postgresql16"
    "aurora-postgresql:15" = "aurora-postgresql15"
    "aurora-postgresql:14" = "aurora-postgresql14"
    "aurora-mysql:8.0"     = "aurora-mysql8.0"
  }

  # Per-engine default version segment used when var.engine_version is
  # null (per IMPL-0007 Q3 / IMPL-0012 Q2). The shape matches what the
  # family map expects: bare major for postgres, major.minor for MySQL.
  # Renovate bumps as new engine versions GA — annual cadence per engine.
  default_major_map = {
    "aurora-postgresql" = "18"
    "aurora-mysql"      = "8.0"
  }

  # When var.engine_version is non-null, normalize it to the
  # family-map's expected shape: postgres takes the leading integer;
  # MySQL keeps major.minor verbatim. When null, fall back to the
  # default-major map.
  engine_version_normalized = var.engine_version != null ? (var.engine == "aurora-postgresql" ? split(".", var.engine_version)[0] : var.engine_version) : local.default_major_map[var.engine]

  engine_family_lookup_key = "${var.engine}:${local.engine_version_normalized}"

  resolved_parameter_family = coalesce(var.parameter_family, lookup(local.parameter_family_map, local.engine_family_lookup_key, null))

  # Engine default TCP port — used by the SG ingress rules in Phase 4.
  engine_default_port_map = {
    "aurora-postgresql" = 5432
    "aurora-mysql"      = 3306
  }

  engine_default_port = local.engine_default_port_map[var.engine]
}
