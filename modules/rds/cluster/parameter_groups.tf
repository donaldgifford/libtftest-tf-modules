#--------------------------------------------------------------
# Aurora cluster + instance parameter groups
#
# Both resolve their family from local.resolved_parameter_family (a
# coalesce of var.parameter_family and the static lookup keyed by
# engine + major in locals.tf). create_before_destroy keeps renames
# downtime-free since AWS treats parameter group renames as
# destroy-then-create at the resource level.
#
# No custom parameter blocks in v1 (IMPL-0012 Q7) — operators repoint
# var.parameter_family to a different family (e.g. an engine-minor
# pin); per-parameter tuning is an additive follow-up.
#--------------------------------------------------------------

resource "aws_rds_cluster_parameter_group" "this" {
  name_prefix = "${var.identifier_prefix}-cluster-"
  family      = local.resolved_parameter_family
  description = "Aurora provisioned cluster ${var.identifier_prefix} cluster parameter group"
  tags        = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.identifier_prefix}-instance-"
  family      = local.resolved_parameter_family
  description = "Aurora provisioned cluster ${var.identifier_prefix} instance parameter group"
  tags        = var.tags

  lifecycle {
    create_before_destroy = true
  }
}
