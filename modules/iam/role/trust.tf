#--------------------------------------------------------------
# Trust policy composition (DESIGN-0025)
#
# aws_iam_policy_document evaluates LOCALLY — no API call — so the
# composed assume_role_policy is plan-known and the plan suite
# asserts its content via jsondecode rather than trusting a
# reference (the same plan-knowability discipline as the S3 core's
# deterministic bucket ARN).
#
# Deliberately ONE statement, and with DESIGN-0027's conditions that
# is now a SECURITY INVARIANT rather than a simplification. IAM's
# three combining rules do not agree with each other:
#
#   values inside one condition ....... OR   ("in ANY of our orgs")
#   conditions inside one statement ... AND  (org AND external id)
#   statements inside one document .... OR   (either alone grants)
#
# So the org-id list ORs correctly *inside* its condition, while the
# two conditions must stay *inside* this one statement to AND.
# Splitting them across statements would silently turn "in our org
# AND presenting the external id" into "... OR ...", a widening with
# no diff a reviewer would notice. tests/trust_conditions.tftest.hcl
# pins the statement count at 1 in every conditions run.
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

    dynamic "condition" {
      for_each = local.trust_conditions

      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
    }
  }
}
