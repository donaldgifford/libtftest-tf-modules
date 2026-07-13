#--------------------------------------------------------------
# The DB instance
#
# A single non-clustered aws_db_instance carrying the full storage /
# credential / backup / monitoring surface. Storage is encrypted at rest
# with local.kms_key_arn (BYO or module-managed); the master password is
# AWS-managed in Secrets Manager (manage_master_user_password) with the
# same key. Plan-time preconditions enforce the cross-variable invariants
# that a single-variable validation can't express (validation-split
# doctrine, terraform >= 1.1).
#
# Q3 (storage-autoscaling drift): when var.max_allocated_storage is set,
# the AWS provider suppresses the allocated_storage diff for growth driven
# by RDS autoscaling — so NO lifecycle.ignore_changes is added here (that
# would also suppress deliberate operator resizes). See
# tests-localstack/FINDINGS.md for the recorded probe outcome.
#--------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier                          = var.identifier_prefix
  instance_class                      = var.instance_class
  engine                              = var.engine
  engine_version                      = var.engine_version
  db_name                             = var.database_name
  db_subnet_group_name                = aws_db_subnet_group.this.name
  parameter_group_name                = aws_db_parameter_group.this.name
  vpc_security_group_ids              = [aws_security_group.this.id]
  port                                = local.resolved_port
  allocated_storage                   = var.allocated_storage
  apply_immediately                   = var.apply_immediately
  auto_minor_version_upgrade          = var.auto_minor_version_upgrade
  backup_retention_period             = var.backup_retention_period
  backup_window                       = var.preferred_backup_window
  ca_cert_identifier                  = var.ca_cert_identifier
  deletion_protection                 = var.deletion_protection
  final_snapshot_identifier           = var.final_snapshot_identifier
  iam_database_authentication_enabled = var.iam_database_authentication_enabled
  iops                                = var.iops
  kms_key_id                          = local.kms_key_arn
  maintenance_window                  = var.preferred_maintenance_window
  manage_master_user_password         = var.manage_master_user_password
  master_user_secret_kms_key_id       = local.kms_key_arn
  max_allocated_storage               = var.max_allocated_storage
  monitoring_interval                 = var.enhanced_monitoring_interval
  monitoring_role_arn                 = var.enhanced_monitoring_role_arn
  multi_az                            = var.multi_az
  performance_insights_enabled        = var.performance_insights_enabled
  performance_insights_kms_key_id     = var.performance_insights_enabled ? local.kms_key_arn : null
  publicly_accessible                 = var.publicly_accessible
  skip_final_snapshot                 = var.skip_final_snapshot
  storage_encrypted                   = true
  storage_throughput                  = var.storage_throughput
  storage_type                        = var.storage_type
  tags                                = var.tags
  username                            = var.master_username

  lifecycle {
    precondition {
      condition     = local.resolved_parameter_family != null
      error_message = "Could not resolve a DB parameter family for engine '${var.engine}' + version '${coalesce(var.engine_version, "(default)")}'. Set var.parameter_family explicitly or use a supported engine major (see parameter_family_map in locals.tf)."
    }

    precondition {
      condition     = var.skip_final_snapshot || var.final_snapshot_identifier != null
      error_message = "final_snapshot_identifier must be set when skip_final_snapshot = false. Supply it at destroy time via -var 'final_snapshot_identifier=...' or flip skip_final_snapshot = true."
    }

    precondition {
      condition     = var.max_allocated_storage == null || var.max_allocated_storage >= var.allocated_storage
      error_message = "max_allocated_storage must be >= allocated_storage when set (it is the autoscaling ceiling, not a second floor)."
    }

    precondition {
      condition     = var.enhanced_monitoring_interval == 0 || var.enhanced_monitoring_role_arn != null
      error_message = "enhanced_monitoring_role_arn must be set when enhanced_monitoring_interval > 0. The module does not provision this role (per IMPL-0007 Q6); supply the ARN of a pre-existing rds-monitoring-role."
    }

    precondition {
      condition     = var.storage_type != "io2" || var.iops != null
      error_message = "iops must be set when storage_type = 'io2' (provisioned-IOPS storage requires an explicit IOPS value)."
    }
  }
}
