# Apply-suite fixture: the caller-owned policy the module attaches
# through its customer_managed_policy_arns channel.
#
# It must exist before the attachment, and the module deliberately
# does NOT create policies (DESIGN-0025 OQ 3a — attach-only; policy
# creation is the future iam/policy sibling's concern), so the
# fixture stands in for the calling stack that would own it.

terraform {
  required_version = ">= 1.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}

resource "aws_iam_policy" "caller_owned" {
  name        = "iam-role-suite-caller-owned"
  description = "Caller-owned policy attached by the module under test"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_policy" "boundary" {
  name        = "iam-role-suite-boundary"
  description = "Permissions boundary attached by the module under test"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:*", "eks:*"]
      Resource = "*"
    }]
  })
}

output "caller_owned_policy_arn" {
  description = "ARN of the caller-owned policy the module attaches."
  value       = aws_iam_policy.caller_owned.arn
}

output "boundary_policy_arn" {
  description = "ARN of the policy the module attaches as a permissions boundary."
  value       = aws_iam_policy.boundary.arn
}
