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

#--------------------------------------------------------------
# Policy attachments and inline policies (Mode A)
#--------------------------------------------------------------
#
# managed / customer attachments split across two resources so the
# plan distinguishes AWS-owned from caller-owned ARNs at a glance
# (state-readability dividend per DESIGN-0004).

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = var.create_role ? toset(var.managed_policy_arns) : []

  role       = aws_iam_role.this[0].name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "customer" {
  for_each = var.create_role ? toset(var.customer_managed_policy_arns) : []

  role       = aws_iam_role.this[0].name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  for_each = var.create_role ? var.inline_policies : {}

  name   = each.key
  role   = aws_iam_role.this[0].name
  policy = each.value
}
