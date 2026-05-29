#--------------------------------------------------------------
# Backup policy — gated by var.backup_policy_enabled
#
# Default false per DESIGN-0008 Q7 — the AWS-managed default
# backup vault carries its own retention + lifecycle defaults that
# may not match site policy; operators opt in deliberately.
# Promoting var.backup_policy_enabled to a typed object that
# carries vault overrides is a follow-up IMPL when a concrete
# consumer requires per-filesystem vault selection.
#--------------------------------------------------------------

resource "aws_efs_backup_policy" "this" {
  count = var.backup_policy_enabled ? 1 : 0

  file_system_id = aws_efs_file_system.this.id

  backup_policy {
    status = "ENABLED"
  }
}
