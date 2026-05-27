#--------------------------------------------------------------
# Aurora Serverless v2 cluster instance
#
# Aurora Serverless v2 requires at least one cluster instance to be
# reachable; instance_class = "db.serverless" is the literal signal
# that this instance is Serverless v2 (vs. db.r6g.* etc. for
# provisioned Aurora).
#
# engine + engine_version flow from the cluster resource (single
# source of truth — instance can't drift from cluster by
# construction).
#--------------------------------------------------------------

resource "aws_rds_cluster_instance" "this" {
  cluster_identifier              = aws_rds_cluster.this.id
  identifier                      = "${var.identifier_prefix}-1"
  instance_class                  = "db.serverless"
  engine                          = aws_rds_cluster.this.engine
  engine_version                  = aws_rds_cluster.this.engine_version
  db_subnet_group_name            = aws_db_subnet_group.this.name
  db_parameter_group_name         = aws_db_parameter_group.this.name
  apply_immediately               = var.apply_immediately
  auto_minor_version_upgrade      = var.auto_minor_version_upgrade
  monitoring_interval             = var.enhanced_monitoring_interval
  monitoring_role_arn             = var.enhanced_monitoring_role_arn
  performance_insights_enabled    = var.performance_insights_enabled
  performance_insights_kms_key_id = var.performance_insights_enabled ? local.kms_key_arn : null
  publicly_accessible             = var.publicly_accessible
  tags                            = var.tags

  lifecycle {
    precondition {
      condition     = var.enhanced_monitoring_interval == 0 || var.enhanced_monitoring_role_arn != null
      error_message = "enhanced_monitoring_role_arn must be set when enhanced_monitoring_interval > 0. The module does not provision this role (per IMPL-0007 Q6); supply the ARN of a pre-existing rds-monitoring-role."
    }
  }
}
