#--------------------------------------------------------------
# Module-managed KMS key (gated bring-your-own per var.kms_key_arn)
#
# Same gating + prevent_destroy posture as
# modules/rds/serverless/kms.tf — destroying the key after the
# cluster has been written to is a data-loss event; operators
# explicitly remove the prevent_destroy block + the cluster + the key
# in a deliberate two-step plan. README documents the procedure.
#--------------------------------------------------------------

resource "aws_kms_key" "this" {
  count = var.kms_key_arn == null ? 1 : 0

  description             = "KMS key for Aurora provisioned cluster ${var.identifier_prefix} (storage at rest + master user secret per IMPL-0007 Q12)"
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
