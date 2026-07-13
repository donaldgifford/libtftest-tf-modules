#--------------------------------------------------------------
# DB parameter group
#
# A single instance needs only one aws_db_parameter_group (no Aurora
# cluster parameter group). Its family resolves from
# local.resolved_parameter_family (a coalesce of var.parameter_family
# and the static engine + major lookup in locals.tf).
# create_before_destroy keeps renames downtime-free since AWS treats
# parameter group renames as destroy-then-create at the resource level.
#
# No custom `parameter` blocks in v1 (Q7) — operators repoint
# var.parameter_family for a different family; per-parameter tuning is a
# later additive change.
#--------------------------------------------------------------

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.identifier_prefix}-"
  family      = local.resolved_parameter_family
  description = "Instance parameter group for ${var.identifier_prefix}"
  tags        = var.tags

  lifecycle {
    create_before_destroy = true
  }
}
