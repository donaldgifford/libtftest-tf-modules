#--------------------------------------------------------------
# SSM Parameter Store publication (opt-in)
#
# Two parameters surface the publisher policy for consumer discovery:
# - publisher_policy_arn → same-account consumers attach by ARN.
# - publisher_policy_json → cross-account consumers read the JSON and
#   recreate the policy locally (IAM policies don't cross account
#   boundaries by reference).
#
# Schema-driven gap (IMPL-0005 Q3 pattern): hashicorp/aws ~> 6.2
# (v6.45.0 installed) does NOT expose a dedicated resource for SSM
# parameter resource-based policies (no aws_ssm_resource_policy
# resource; aws_ssm_parameter has no inline access-policy attribute).
# When var.ssm_cross_account_org_id is non-null, the parameter tier
# flips to Advanced (prerequisite for resource-based policies) and
# the org-read policy JSON is emitted via the ssm_org_read_policy_json
# output for operators to attach manually via
# `aws ssm put-resource-policy` — see README for the recipe.
#--------------------------------------------------------------

resource "aws_ssm_parameter" "publisher_policy_arn" {
  count = var.publish_to_ssm ? 1 : 0

  name        = var.ssm_parameter_path_arn
  type        = "String"
  value       = aws_iam_policy.oci_publisher.arn
  tier        = var.ssm_cross_account_org_id == null ? "Standard" : "Advanced"
  description = "ARN of the org-wide ECR OCI publisher IAM policy. Attach to CI / IRSA roles in the artifact-hosting account."
  tags        = var.tags
}

resource "aws_ssm_parameter" "publisher_policy_json" {
  count = var.publish_to_ssm ? 1 : 0

  name        = var.ssm_parameter_path_json
  type        = "String"
  value       = data.aws_iam_policy_document.oci_publisher.json
  tier        = var.ssm_cross_account_org_id == null ? "Standard" : "Advanced"
  description = "Full JSON of the org-wide ECR OCI publisher IAM policy. Cross-account consumers read this and recreate the policy in their own accounts."
  tags        = var.tags
}

#--------------------------------------------------------------
# Cross-account resource-based policy JSON (emitted as output)
#--------------------------------------------------------------

data "aws_iam_policy_document" "ssm_org_read" {
  count = var.publish_to_ssm && var.ssm_cross_account_org_id != null ? 1 : 0

  statement {
    sid    = "OrgRead"
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]

    resources = [
      aws_ssm_parameter.publisher_policy_arn[0].arn,
      aws_ssm_parameter.publisher_policy_json[0].arn,
    ]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [var.ssm_cross_account_org_id]
    }
  }
}
