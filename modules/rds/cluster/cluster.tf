#--------------------------------------------------------------
# Aurora provisioned cluster
#
# engine_mode = "provisioned" WITHOUT a serverlessv2_scaling_
# configuration block is the provisioned (non-serverless) Aurora
# incantation — the writer's capacity comes from a concrete
# aws_rds_cluster_instance.instance_class (instance.tf), not ACUs.
# Storage and master user secret share local.kms_key_arn per
# IMPL-0007 Q12. Three preconditions enforce cross-variable invariants
# that terraform 1.1 variable.validation can't express.
#--------------------------------------------------------------

resource "aws_rds_cluster" "this" {
  cluster_identifier = var.identifier_prefix

  apply_immediately                   = var.apply_immediately
  backtrack_window                    = var.backtrack_window
  backup_retention_period             = var.backup_retention_period
  database_name                       = var.database_name
  db_cluster_parameter_group_name     = aws_rds_cluster_parameter_group.this.name
  db_subnet_group_name                = aws_db_subnet_group.this.name
  deletion_protection                 = var.deletion_protection
  enabled_cloudwatch_logs_exports     = var.enabled_cloudwatch_logs_exports
  engine                              = var.engine
  engine_mode                         = "provisioned"
  engine_version                      = var.engine_version
  final_snapshot_identifier           = var.final_snapshot_identifier
  iam_database_authentication_enabled = var.iam_database_authentication_enabled
  kms_key_id                          = local.kms_key_arn
  manage_master_user_password         = var.manage_master_user_password
  master_username                     = var.master_username
  master_user_secret_kms_key_id       = local.kms_key_arn
  preferred_backup_window             = var.preferred_backup_window
  preferred_maintenance_window        = var.preferred_maintenance_window
  skip_final_snapshot                 = var.skip_final_snapshot
  storage_encrypted                   = true
  storage_type                        = var.storage_type
  tags                                = var.tags
  vpc_security_group_ids              = [aws_security_group.this.id]

  lifecycle {
    precondition {
      condition     = local.resolved_parameter_family != null
      error_message = "Could not resolve parameter family for engine=${var.engine} engine_version=${coalesce(var.engine_version, "<null>")}. Set var.parameter_family explicitly or extend parameter_family_map in locals.tf."
    }

    precondition {
      condition     = var.skip_final_snapshot || var.final_snapshot_identifier != null
      error_message = "final_snapshot_identifier must be set when skip_final_snapshot = false (the default). Supply via `-var 'final_snapshot_identifier=...'` at destroy time, or set skip_final_snapshot = true to opt out of the final snapshot deliberately."
    }

    precondition {
      condition     = var.backtrack_window == 0 || var.engine == "aurora-mysql"
      error_message = "backtrack_window is Aurora-MySQL-only — it must be 0 for engine=${var.engine}. Aurora Backtrack (fast rewind) is not available for aurora-postgresql."
    }
  }
}
