#--------------------------------------------------------------
# Module-managed KMS key (gated bring-your-own per var.kms_key_arn)
#
# Same gating + prevent_destroy posture as the rest of the fleet —
# modules/eks/cluster, modules/ecr/org-registry, and
# modules/rds/serverless all carry this lifecycle block. Destroying
# the key after the filesystem has been written to is a data-loss
# event; operators explicitly remove the prevent_destroy block plus
# the filesystem + the key in a deliberate two-step plan. README's
# Operational gotchas section documents the procedure.
#--------------------------------------------------------------

resource "aws_kms_key" "this" {
  count = var.kms_key_arn == null ? 1 : 0

  description             = "KMS key for EFS filesystem ${var.identifier_prefix} encryption at rest"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "this" {
  count = var.kms_key_arn == null ? 1 : 0

  name          = local.kms_alias_name
  target_key_id = aws_kms_key.this[0].key_id
}
