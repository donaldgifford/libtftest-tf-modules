#--------------------------------------------------------------
# Repository creation template (auto-vivification)
#--------------------------------------------------------------
#
# One template with prefix = "ROOT" applies to every repository
# ECR auto-creates via pull-through cache (DESIGN-0005 / IMPL-0005
# Q2). The v6 provider's plan-time validation rejects "*" — the
# special match-all value is the literal "ROOT", not "*". DESIGN
# -0005's "*" example was speculative; per Q3 we follow the schema.
# Caller-controlled untagged-image retention drives the lifecycle
# policy JSON; AES256 encryption per DESIGN-0005.
#
# Per IMPL-0005 Q3 (schema verification at implementation time):
# the v6 provider schema for aws_ecr_repository_creation_template
# does NOT expose scan_on_push as a template attribute. ECR's
# scan-on-push setting is per-account (aws_ecr_registry_scanning
# _configuration) rather than per-template — out-of-scope for this
# module per DESIGN-0005. Consumers who want scan-on-push manage it
# at the account level alongside whatever else they configure on
# the ECR registry.
#
# repository_policy is intentionally omitted — ECR attaches a
# service-principal policy to pull-through-created repos
# automatically. A caller-supplied repo policy is only needed for
# cross-account scenarios, which DESIGN-0005 marks out-of-scope.

resource "aws_ecr_repository_creation_template" "pull_through" {
  prefix      = var.repo_creation_template_prefix
  applied_for = ["PULL_THROUGH_CACHE"]

  image_tag_mutability = "MUTABLE"

  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Prune untagged images after ${var.untagged_image_retention_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_retention_days
        }
        action = {
          type = "expire"
        }
      },
    ]
  })

  resource_tags = var.tags

  encryption_configuration {
    encryption_type = "AES256"
  }
}
