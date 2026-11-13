# ECR image intake (DESIGN-0031 / IMPL-0027): the quarantine and
# promoted-prefix creation templates, the role ECR assumes to apply
# them, and the optional intake event rule.
#
# Templates apply to repositories CREATED after the template exists
# (create-on-push). Repositories that predate it keep whatever policy
# they had, so stand this module up before the first sync.

#--------------------------------------------------------------
# Template role
#--------------------------------------------------------------

resource "aws_iam_role" "template" {
  name        = "${var.name}-ecr-templates"
  description = "Assumed by ECR to create repositories from the ${var.name} creation templates"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecr.amazonaws.com" }
      Action    = "sts:AssumeRole"
      # Confused-deputy guard: only this account's ECR may assume it.
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "template" {
  name   = "ecr-creation-templates"
  role   = aws_iam_role.template.id
  policy = local.template_role_policy
}

#--------------------------------------------------------------
# Quarantine template
#--------------------------------------------------------------

resource "aws_ecr_repository_creation_template" "quarantine" {
  prefix      = var.quarantine_prefix
  description = "Quarantine: writers push here, images expire after ${var.quarantine_retention_days} days"
  applied_for = ["CREATE_ON_PUSH"]

  # MUTABLE on purpose: intake keys on the DIGEST from the push event,
  # so a tag move cannot redirect it, and re-running a sync never fails.
  image_tag_mutability = "MUTABLE"

  lifecycle_policy  = local.quarantine_lifecycle_policy
  repository_policy = local.quarantine_repository_policy
  custom_role_arn   = aws_iam_role.template.arn
  resource_tags     = data.aws_default_tags.current.tags

  encryption_configuration {
    encryption_type = var.kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.kms_key_arn
  }

  lifecycle {
    precondition {
      condition     = length(local.foreign_writers) == 0
      error_message = "writer_principal_arns must all be in the registry account (${local.account_id}): a repository-policy exemption grants nothing cross-account, so these writers could never push (DESIGN-0031 OQ 14a): ${join(", ", local.foreign_writers)}"
    }
  }

  depends_on = [aws_iam_role_policy.template]
}

#--------------------------------------------------------------
# Promoted templates
#--------------------------------------------------------------

resource "aws_ecr_repository_creation_template" "promoted" {
  for_each = var.promoted_prefixes

  prefix      = each.key
  description = coalesce(each.value.description, "Promoted: written by intake only, never expires")
  applied_for = ["CREATE_ON_PUSH"]

  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  # No lifecycle_policy (OQ 7a): an untagged-expiry rule could delete a
  # signature or attestation referrer and silently strip a promoted
  # image of its signature. Revocation is admission-side.
  repository_policy = local.promoted_repository_policy
  custom_role_arn   = aws_iam_role.template.arn
  resource_tags     = data.aws_default_tags.current.tags

  dynamic "image_tag_mutability_exclusion_filter" {
    for_each = each.value.tag_mutability_exclusions

    content {
      filter      = image_tag_mutability_exclusion_filter.value
      filter_type = "WILDCARD"
    }
  }

  encryption_configuration {
    encryption_type = var.kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.kms_key_arn
  }

  depends_on = [aws_iam_role_policy.template]
}

#--------------------------------------------------------------
# Intake event (OQ 11a)
#--------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "quarantine_push" {
  count = var.intake_event_target == null ? 0 : 1

  name          = "${var.name}-quarantine-push"
  description   = "Successful pushes to ${var.quarantine_prefix}/, handed to intake"
  event_pattern = jsonencode(local.intake_event_pattern)
}

resource "aws_cloudwatch_event_target" "intake" {
  count = var.intake_event_target == null ? 0 : 1

  rule      = aws_cloudwatch_event_rule.quarantine_push[0].name
  target_id = "intake"
  arn       = var.intake_event_target.arn
  role_arn  = var.intake_event_target.role_arn
}
