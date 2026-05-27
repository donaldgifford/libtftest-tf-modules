#--------------------------------------------------------------
# Computed locals
#
# Populated in Phase 2:
#   - account_id (from data.aws_caller_identity.current)
#   - kms_key_arn (coalesce of var.kms_key_arn + module-managed key)
#   - parameter_family_map (static engine + major → family lookup)
#   - default_major_map (per-engine default major when var.engine_version is null, per IMPL-0007 Q3)
#   - engine_default_port_map (5432 / 3306)
#   - resolved_parameter_family (coalesce of var.parameter_family + lookup)
#--------------------------------------------------------------
