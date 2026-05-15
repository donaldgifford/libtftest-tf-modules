#--------------------------------------------------------------
# KMS envelope encryption
#--------------------------------------------------------------
#
# Module-managed CMK gated on var.kms_key_arn == null. When the caller
# passes a pre-existing key ARN, this block is a no-op and the cluster
# encrypts secrets against the external key. local.kms_key_arn collapses
# both modes into a single reference downstream resources can use.

data "aws_iam_policy_document" "kms_cluster" {
  count = var.kms_key_arn == null ? 1 : 0

  statement {
    sid    = "AccountRootFullAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }
}

resource "aws_kms_key" "cluster" {
  count = var.kms_key_arn == null ? 1 : 0

  description             = "EKS envelope encryption CMK for cluster ${var.tags.ClusterName}"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_cluster[0].json
  tags                    = var.tags
}

resource "aws_kms_alias" "cluster" {
  count = var.kms_key_arn == null ? 1 : 0

  name          = "alias/eks/${var.tags.ClusterName}"
  target_key_id = aws_kms_key.cluster[0].key_id
}
