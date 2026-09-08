#--------------------------------------------------------------
# Trust policy composition (DESIGN-0025)
#
# aws_iam_policy_document evaluates LOCALLY — no API call — so the
# composed assume_role_policy is plan-known and the plan suite
# asserts its content via jsondecode rather than trusting a
# reference (the same plan-knowability discipline as the S3 core's
# deterministic bucket ARN).
#
# Deliberately ONE statement: the trust surface is a flat principal
# list in v1, and DESIGN-0025 Follow-up 1 (typed conditions —
# external_id first) slots a conditions block in here without
# reshaping var.trusted_role_arns.
#--------------------------------------------------------------

data "aws_iam_policy_document" "trust" {
  statement {
    sid    = "AllowAssumeRole"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.trusted_role_arns
    }

    actions = ["sts:AssumeRole"]
  }
}
