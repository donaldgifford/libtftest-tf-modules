#--------------------------------------------------------------
# Secrets Manager secret producer (DESIGN-0020 / INV-0010 1b)
#
# The value's entire lifecycle: generated in memory during the
# operation (ephemeral — local, no API call) -> sent write-only
# (secret_string_wo, never in state or plan) -> durable in exactly one
# place: the secret itself.
#
# THE EPHEMERAL-REFERENCE INVARIANT: nothing outside
# aws_secretsmanager_secret_version.this may reference
# ephemeral.random_password.this.result — not an output, not a local,
# not another resource. The plan suite's `secret_string_wo == null`
# assertion is the mechanical backstop; this comment is the review
# contract.
#--------------------------------------------------------------

resource "aws_secretsmanager_secret" "this" {
  # name_prefix, not name: Secrets Manager reserves a deleted secret's
  # name for the length of the recovery window (up to 30 days), so an
  # exact name would brick recreate-after-destroy (DESIGN-0020
  # resolution 5a). Consumers resolve the secret by ARN from remote
  # state, never by constructing the physical name.
  name_prefix = "${var.name}-"
  description = var.description

  # Null leaves the AWS-managed aws/secretsmanager key in charge (the
  # OQ 2 resolution's default); the kms_key_arn output then reports
  # null and rds/proxy takes its ViaService-fenced wildcard path.
  kms_key_id = var.kms_key_arn

  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

# Local ephemeral (INV-0010 resolution 3a): opens with NO API call,
# which keeps the generation path fully plan-testable offline — the
# aws provider's aws_secretsmanager_random_password would break every
# offline plan run and is unmockable (F3.1/F3.4). Re-opened (i.e.
# regenerated) on every operation; harmless, because the value is only
# ever SENT when the version gate below changes.
ephemeral "random_password" "this" {
  length           = var.password_length
  special          = true
  override_special = var.password_override_special
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id

  # Content shape (OQ 1a): username set -> RDS-format DB-credentials
  # JSON (what rds/proxy requires of any secret it fronts, INV-0010
  # F5); username null -> the bare generated password.
  secret_string_wo = (
    var.username != null
    ? jsonencode({
      username = var.username
      password = ephemeral.random_password.this.result
    })
    : ephemeral.random_password.this.result
  )

  # The F4 version gate: the write-only value above is only sent when
  # this integer changes. Steady-state applies are no-ops; bumping
  # var.secret_string_version mints exactly one new password.
  secret_string_wo_version = var.secret_string_version
}
