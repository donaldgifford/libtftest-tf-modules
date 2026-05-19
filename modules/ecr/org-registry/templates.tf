#--------------------------------------------------------------
# Org-wide pull policy (shared by both creation templates)
#--------------------------------------------------------------

data "aws_iam_policy_document" "org_pull" {
  statement {
    sid    = "OrgPull"
    effect = "Allow"

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [var.organizations_org_id]
    }
  }
}

#--------------------------------------------------------------
# Repository creation templates (helm-charts/* and tf-modules/*)
#--------------------------------------------------------------

resource "aws_ecr_repository_creation_template" "helm_charts" {
  prefix      = var.helm_charts_prefix
  applied_for = ["CREATE_ON_PUSH"]
  description = "Internal Helm charts published as OCI artifacts"

  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "latest"
    filter_type = "WILDCARD"
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = local.kms_key_arn
  }

  custom_role_arn = aws_iam_role.ecr_template.arn

  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire pre-release / dev-tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*-dev*", "*-rc*", "*-pre*"]
          countType      = "sinceImagePushed"
          countUnit      = "days"
          countNumber    = var.pre_release_retention_days
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_retention_days
        }
        action = {
          type = "expire"
        }
      },
    ]
  })

  repository_policy = data.aws_iam_policy_document.org_pull.json

  resource_tags = merge(var.tags, {
    artifact_type = "helm-chart"
    managed_by    = "platform"
  })
}

resource "aws_ecr_repository_creation_template" "tf_modules" {
  prefix      = var.tf_modules_prefix
  applied_for = ["CREATE_ON_PUSH"]
  description = "Internal Terraform modules published as OCI artifacts"

  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "latest"
    filter_type = "WILDCARD"
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = local.kms_key_arn
  }

  custom_role_arn = aws_iam_role.ecr_template.arn

  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire pre-release / dev-tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*-dev*", "*-rc*", "*-pre*"]
          countType      = "sinceImagePushed"
          countUnit      = "days"
          countNumber    = var.pre_release_retention_days
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Expire untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_retention_days
        }
        action = {
          type = "expire"
        }
      },
    ]
  })

  repository_policy = data.aws_iam_policy_document.org_pull.json

  resource_tags = merge(var.tags, {
    artifact_type = "terraform-module"
    managed_by    = "platform"
  })
}
