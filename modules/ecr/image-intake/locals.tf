#--------------------------------------------------------------
# Policy composition (DESIGN-0031 § The quarantine template,
# § The promoted templates, § IAM policy outputs)
#
# Every document is jsonencode'd, never aws_iam_policy_document: the
# latter collapses single-element sets to strings, and these documents
# are decoded by the plan suite and by humans reading a template.
#--------------------------------------------------------------

locals {
  account_id      = data.aws_caller_identity.current.account_id
  region          = data.aws_region.current.region
  repository_base = "arn:aws:ecr:${local.region}:${local.account_id}:repository"

  promoted_keys = sort(keys(var.promoted_prefixes))

  quarantine_arn = "${local.repository_base}/${var.quarantine_prefix}/*"
  promoted_arns  = [for p in local.promoted_keys : "${local.repository_base}/${p}/*"]

  # Writers must live in the registry account (OQ 14a): a resource-side
  # Deny exemption grants nothing cross-account, so a cross-account
  # writer would plan clean and then fail every push.
  foreign_writers = [for a in var.writer_principal_arns : a if element(split(":", a), 4) != local.account_id]

  # The exemption sets. Sorted and de-duplicated so the rendered policy
  # is stable across input ordering.
  quarantine_exempt = sort(distinct(concat(var.writer_principal_arns, var.intake_principal_arns, var.admin_principal_arns)))
  intake_exempt     = sort(distinct(concat(var.intake_principal_arns, var.admin_principal_arns)))
  admin_exempt      = sort(distinct(var.admin_principal_arns))

  pull_actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
  ]

  push_actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:CompleteLayerUpload",
    "ecr:InitiateLayerUpload",
    "ecr:PutImage",
    "ecr:UploadLayerPart",
  ]

  # aws:PrincipalArn is ABSENT for AWS service principals, and
  # ArnNotLike on an absent key evaluates TRUE, so without the
  # BoolIfExists clause these Denys would also block ECR's own scanning
  # and replication. Conditions within a statement AND.
  service_exemption = { BoolIfExists = { "aws:PrincipalIsAWSService" = "false" } }

  quarantine_repository_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonPipelineImageAccess"
      Effect    = "Deny"
      Principal = "*"
      Action = sort(distinct(concat(local.pull_actions, local.push_actions, [
        "ecr:BatchDeleteImage",
      ])))
      Condition = merge(
        { ArnNotLike = { "aws:PrincipalArn" = local.quarantine_exempt } },
        local.service_exemption,
      )
    }]
  })

  quarantine_lifecycle_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire every quarantined image ${var.quarantine_retention_days} days after push"
      selection = {
        tagStatus   = "any"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = var.quarantine_retention_days
      }
      action = { type = "expire" }
    }]
  })

  promoted_repository_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonIntakeWrites"
        Effect    = "Deny"
        Principal = "*"
        Action    = sort(concat(local.push_actions, ["ecr:BatchDeleteImage"]))
        Condition = merge(
          { ArnNotLike = { "aws:PrincipalArn" = local.intake_exempt } },
          local.service_exemption,
        )
      },
      {
        # Mirrors s3/mirror-bucket's policy-mutation guard: only admins
        # may loosen a promoted repository.
        Sid       = "DenyNonAdminPolicyChanges"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "ecr:DeleteLifecyclePolicy",
          "ecr:DeleteRepository",
          "ecr:DeleteRepositoryPolicy",
          "ecr:PutImageTagMutability",
          "ecr:PutLifecyclePolicy",
          "ecr:SetRepositoryPolicy",
        ]
        Condition = merge(
          { ArnNotLike = { "aws:PrincipalArn" = local.admin_exempt } },
          local.service_exemption,
        )
      },
    ]
  })

  # Identity policies for roles the caller owns (OQ 10a). Writers get
  # nothing outside quarantine; intake gets push only on promoted
  # prefixes.
  writer_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthorizationToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        # CreateRepository: create-on-push needs it. BatchGetImage: the
        # sync example's `crane digest` idempotency check and cosign copy
        # read the destination manifest (IMPL-0027 Phase 4 build note).
        Sid      = "QuarantinePush"
        Effect   = "Allow"
        Action   = sort(concat(local.push_actions, ["ecr:BatchGetImage", "ecr:CreateRepository"]))
        Resource = [local.quarantine_arn]
      },
    ]
  })

  intake_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthorizationToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid      = "QuarantineRead"
        Effect   = "Allow"
        Action   = sort(concat(local.pull_actions, ["ecr:DescribeImageScanFindings", "ecr:DescribeImages"]))
        Resource = [local.quarantine_arn]
      },
      {
        # Pull as well as push: cosign sign and attest read the promoted
        # manifest they sign (IMPL-0027 Phase 4 build note).
        Sid      = "PromotedWrite"
        Effect   = "Allow"
        Action   = sort(distinct(concat(local.pull_actions, local.push_actions, ["ecr:CreateRepository", "ecr:DescribeImageScanFindings", "ecr:DescribeImages"])))
        Resource = local.promoted_arns
      },
    ]
  })

  # The template role ECR assumes when it creates a repository from a
  # template (tags, and KMS when set). Scoped to the module's prefixes.
  template_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid    = "CreateFromTemplate"
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository",
          "ecr:PutLifecyclePolicy",
          "ecr:SetRepositoryPolicy",
          "ecr:TagResource",
        ]
        Resource = concat([local.quarantine_arn], local.promoted_arns)
      }],
      (var.kms_key_arn == null ? [] : [{
        Sid      = "UseRepositoryKey"
        Effect   = "Allow"
        Action   = ["kms:CreateGrant", "kms:DescribeKey", "kms:RetireGrant"]
        Resource = [var.kms_key_arn]
      }]),
    )
  })

  intake_event_pattern = {
    source        = ["aws.ecr"]
    "detail-type" = ["ECR Image Action"]
    detail = {
      "action-type"     = ["PUSH"]
      result            = ["SUCCESS"]
      "repository-name" = [{ prefix = "${var.quarantine_prefix}/" }]
    }
  }
}
