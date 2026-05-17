#--------------------------------------------------------------
# Mode A — Pod-Identity-trusting IAM role + policy attachments
#--------------------------------------------------------------
#
# All resources here are gated on var.create_role. Phase 3 lands
# the role + trust policy; Phase 4 lands managed/customer/inline
# policy attachments.

data "aws_iam_policy_document" "pod_identity_trust" {
  count = var.create_role ? 1 : 0

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

resource "aws_iam_role" "this" {
  count = var.create_role ? 1 : 0

  name                 = local.role_name
  assume_role_policy   = data.aws_iam_policy_document.pod_identity_trust[0].json
  permissions_boundary = var.permissions_boundary

  tags = var.tags
}
