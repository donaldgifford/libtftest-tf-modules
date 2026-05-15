#--------------------------------------------------------------
# Shared Pod Identity trust policy (IMPL-0003 Q1)
#--------------------------------------------------------------
#
# Every addon-managed PIA in this module attaches an IAM role
# whose trust policy is identical: pods.eks.amazonaws.com with
# sts:AssumeRole + sts:TagSession. Declared once here and
# referenced by aws_iam_role.vpc_cni / ebs_csi / efs_csi.
#
# Lives in locals.tf rather than iam.tf per Q1 resolution — one
# data source is sub-module ceremony for a dedicated iam.tf file.

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

#--------------------------------------------------------------
# Per-addon IAM role names
#--------------------------------------------------------------
#
# AWS IAM role names cap at 64 chars. Substr the cluster_name
# fragment so the suffix always survives.

locals {
  vpc_cni_role_name = "${substr(var.cluster_name, 0, 56)}-vpc-cni"
  ebs_csi_role_name = "${substr(var.cluster_name, 0, 56)}-ebs-csi"
}
