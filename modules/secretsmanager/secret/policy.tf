#--------------------------------------------------------------
# Optional resource policy — cross-account reads (DESIGN-0020 OQ 3a)
#
# Count-gated: no principals, no policy resource at all (the fleet's
# optional-resource convention). The grant is read-only and exact:
# GetSecretValue + DescribeSecret to precisely the listed principals.
# A raw policy_json passthrough was explicitly DEFERRED, not rejected
# (DESIGN-0020 Follow-up 4) — do not bolt one on here without that
# design catching up.
#
# Two caveats the README states for consumers (AWS restrictions, not
# module choices): cross-account reads do not work at all on the
# AWS-managed aws/secretsmanager key (use var.kms_key_arn), and a
# CMK-encrypted secret ALSO needs a kms:Decrypt grant in the key's own
# policy, which this module does not own.
#--------------------------------------------------------------

data "aws_iam_policy_document" "read_access" {
  count = length(var.read_principals) > 0 ? 1 : 0

  statement {
    sid    = "AllowSecretRead"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.read_principals
    }

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    resources = ["*"] # scoped by attachment: a secret policy applies only to its own secret
  }
}

resource "aws_secretsmanager_secret_policy" "read_access" {
  count = length(var.read_principals) > 0 ? 1 : 0

  secret_arn = aws_secretsmanager_secret.this.arn
  policy     = data.aws_iam_policy_document.read_access[0].json
}
