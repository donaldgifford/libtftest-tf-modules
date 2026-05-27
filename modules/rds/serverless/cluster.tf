#--------------------------------------------------------------
# Aurora Serverless v2 cluster
#
# engine_mode = "provisioned" + serverlessv2_scaling_configuration
# is the Serverless v2 incantation; engine_mode = "serverless" is
# the deprecated v1 path. Storage and master user secret share
# local.kms_key_arn per IMPL-0007 Q12. Three preconditions enforce
# cross-variable invariants that terraform 1.1 variable.validation
# can't express (need terraform 1.9+ for cross-var checks).
#--------------------------------------------------------------

resource "aws_rds_cluster" "this" {
  cluster_identifier = var.identifier_prefix

  apply_immediately                   = var.apply_immediately
  backup_retention_period             = var.backup_retention_period
  database_name                       = var.database_name
  db_cluster_parameter_group_name     = aws_rds_cluster_parameter_group.this.name
  db_subnet_group_name                = aws_db_subnet_group.this.name
  deletion_protection                 = var.deletion_protection
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
  tags                                = var.tags
  vpc_security_group_ids              = [aws_security_group.this.id]

  serverlessv2_scaling_configuration {
    min_capacity = var.min_acu
    max_capacity = var.max_acu
  }

  lifecycle {
    precondition {
      condition     = var.min_acu <= var.max_acu
      error_message = "min_acu must be <= max_acu (got min=${var.min_acu}, max=${var.max_acu}). Aurora Serverless v2 scaling configuration rejects inverted bounds."
    }

    precondition {
      condition     = local.resolved_parameter_family != null
      error_message = "Could not resolve parameter family for engine=${var.engine} engine_version=${coalesce(var.engine_version, "<null>")}. Set var.parameter_family explicitly or extend parameter_family_map in locals.tf."
    }

    precondition {
      condition     = var.skip_final_snapshot || var.final_snapshot_identifier != null
      error_message = "final_snapshot_identifier must be set when skip_final_snapshot = false (the default). Supply via `-var 'final_snapshot_identifier=...'` at destroy time, or set skip_final_snapshot = true to opt out of the final snapshot deliberately."
    }
  }
}
