#--------------------------------------------------------------
# Secrets Manager secrets for authenticated upstreams
#--------------------------------------------------------------
#
# One secret + initial version per authenticated upstream (Docker
# Hub, GHCR). The secret name MUST be prefixed
# "ecr-pullthroughcache/" — ECR's API rejects pull-through cache
# rules whose credential_arn doesn't follow this convention.
#
# The version body is a placeholder. Operators populate the real
# credentials post-apply via:
#
#   aws secretsmanager put-secret-value \
#     --secret-id ecr-pullthroughcache/<name_prefix>-docker-hub \
#     --secret-string '{"username":"<user>","accessToken":"<token>"}'
#
# lifecycle.ignore_changes = [secret_string] on the version ensures
# the operator-rotated value persists across subsequent terraform
# apply runs — Terraform won't clobber it back to the placeholder.

resource "aws_secretsmanager_secret" "upstream" {
  for_each = local.authenticated

  name        = "ecr-pullthroughcache/${var.name_prefix}-${each.key}"
  description = "ECR pull-through cache credentials for ${each.value.upstream_url}"

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "upstream" {
  for_each = local.authenticated

  secret_id     = aws_secretsmanager_secret.upstream[each.key].id
  secret_string = jsonencode({ username = "REPLACE_ME", accessToken = "REPLACE_ME" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
