#--------------------------------------------------------------
# Managed master secret rotation schedule (INV-0008 / IMPL-0017)
#
# Adopts the AWS-managed master user secret into a declarative rotation
# schedule, replacing AWS's 7-day default cadence with the module's
# quarterly default. No rotation_lambda_arn — the secret rotates via
# RDS's service-managed rotation; this resource only sets the schedule.
# rotate_immediately = false so adopting the schedule does not trigger
# an out-of-band rotation at apply time.
#
# Omitted when manage_master_user_password = false (no managed secret
# exists — OQ 1a) or master_secret_rotation_days = null (leave AWS's
# schedule alone).
#
# LocalStack parity (IMPL-0017 Phase 1): Pro 2026.7.0 mints the managed
# secret without a managed-rotation registration, so this resource
# cannot apply there — the apply suites pass
# master_secret_rotation_days = null and the plan suites gate this
# surface (OQ 2a; see tests-localstack*/FINDINGS.md).
#--------------------------------------------------------------

resource "aws_secretsmanager_secret_rotation" "master" {
  count = var.manage_master_user_password && var.master_secret_rotation_days != null ? 1 : 0

  secret_id          = aws_rds_cluster.this.master_user_secret[0].secret_arn
  rotate_immediately = false

  rotation_rules {
    automatically_after_days = var.master_secret_rotation_days
  }
}
