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
# The placeholder is seeded WRITE-ONLY (secret_string_wo, IMPL-0019
# Phase 4 / the DESIGN-0020 no-leak invariant). The old secret_string
# + ignore_changes shape had a refresh leak: secret_string is read
# back on every refresh, so once an operator rotated in the real
# token, the next plan/apply persisted it into Terraform state in
# plaintext. Write-only arguments are never read back and never
# stored. The pinned secret_string_wo_version = 1 is what ignore_
# changes used to do: the provider only re-sends the placeholder if
# that integer changes, so the operator-rotated value persists across
# applies untouched.

resource "aws_secretsmanager_secret" "upstream" {
  for_each = local.authenticated

  name        = "ecr-pullthroughcache/${var.name_prefix}-${each.key}"
  description = "ECR pull-through cache credentials for ${each.value.upstream_url}"

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "upstream" {
  for_each = local.authenticated

  secret_id                = aws_secretsmanager_secret.upstream[each.key].id
  secret_string_wo         = jsonencode({ username = "REPLACE_ME", accessToken = "REPLACE_ME" })
  secret_string_wo_version = 1
}
