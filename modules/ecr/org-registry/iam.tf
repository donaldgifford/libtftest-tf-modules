#--------------------------------------------------------------
# ECR-assumed IAM role (templates' custom_role_arn)
#--------------------------------------------------------------

data "aws_iam_policy_document" "ecr_template_assume" {
  statement {
    sid     = "EcrServiceAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecr.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecr_template" {
  name               = local.template_role_name
  description        = "Assumed by ECR when creating repos via creation templates (managed by org-registry module)"
  assume_role_policy = data.aws_iam_policy_document.ecr_template_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ecr_template" {
  statement {
    sid    = "ManageRepoConfig"
    effect = "Allow"

    actions = [
      "ecr:CreateRepository",
      "ecr:PutLifecyclePolicy",
      "ecr:SetRepositoryPolicy",
      "ecr:TagResource",
    ]

    resources = [
      "arn:aws:ecr:*:${local.account_id}:repository/${var.helm_charts_prefix}/*",
      "arn:aws:ecr:*:${local.account_id}:repository/${var.tf_modules_prefix}/*",
    ]
  }

  statement {
    sid    = "UseKmsKey"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    resources = [local.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "ecr_template" {
  name   = "${var.name_prefix}-ecr-template-permissions"
  role   = aws_iam_role.ecr_template.id
  policy = data.aws_iam_policy_document.ecr_template.json
}
