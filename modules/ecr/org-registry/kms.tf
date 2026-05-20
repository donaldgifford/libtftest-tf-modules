#--------------------------------------------------------------
# Module-managed KMS key (gated bring-your-own per var.kms_key_arn)
#--------------------------------------------------------------

resource "aws_kms_key" "ecr_oci" {
  count = var.kms_key_arn == null ? 1 : 0

  description             = "ECR encryption key for OCI artifact repos (${var.helm_charts_prefix}/*, ${var.tf_modules_prefix}/*)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "ecr_oci" {
  count = var.kms_key_arn == null ? 1 : 0

  name          = local.kms_alias_name
  target_key_id = aws_kms_key.ecr_oci[0].key_id
}
