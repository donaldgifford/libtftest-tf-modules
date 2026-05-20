#--------------------------------------------------------------
# Reusable publisher IAM policy (CI / IRSA attach this)
#--------------------------------------------------------------

data "aws_iam_policy_document" "oci_publisher" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrCreateAndPush"
    effect = "Allow"

    actions = [
      "ecr:CreateRepository",
      "ecr:DescribeRepositories",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
    ]

    resources = [
      "arn:aws:ecr:*:${local.account_id}:repository/${var.helm_charts_prefix}/*",
      "arn:aws:ecr:*:${local.account_id}:repository/${var.tf_modules_prefix}/*",
    ]
  }

  statement {
    sid    = "UseKmsForEncryption"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    resources = [local.kms_key_arn]
  }
}

resource "aws_iam_policy" "oci_publisher" {
  name        = local.publisher_policy_name
  description = "Permissions to push internal Helm charts and Terraform modules to ECR via create-on-push (consumed by CI / IRSA roles)"
  policy      = data.aws_iam_policy_document.oci_publisher.json
  tags        = var.tags
}
