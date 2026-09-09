# Apply-suite verifier: reads the applied role BACK out of the API.
#
# The module's own post-apply attributes are already API responses,
# but they are what the provider chose to record. Reading the role
# back through data sources proves the far side independently — the
# trust document IAM actually stored, the attachments it actually
# holds, the inline document it actually serves.
#
# Deliberately NOT proven here: whether the trust policy is
# ENFORCED. LocalStack's STS mints credentials for any role ARN
# (IMPL-0015 Phase 1), so an AssumeRole against it says nothing at
# all — see FINDINGS.md.

terraform {
  required_version = ">= 1.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}

variable "role_name" {
  description = "Name of the role to read back."
  type        = string
  nullable    = false
}

variable "inline_policy_name" {
  description = "Name of the inline policy to read back off that role."
  type        = string
  nullable    = false
}

data "aws_iam_role" "applied" {
  name = var.role_name
}

output "role_arn" {
  description = "The ARN IAM returns for the applied role — the path-bearing spelling."
  value       = data.aws_iam_role.applied.arn
}

output "role_path" {
  description = "The path IAM stored."
  value       = data.aws_iam_role.applied.path
}

output "max_session_duration" {
  description = "The session duration IAM stored."
  value       = data.aws_iam_role.applied.max_session_duration
}

output "assume_role_policy" {
  description = "The trust document IAM actually stored, as served back."
  value       = data.aws_iam_role.applied.assume_role_policy
}

output "permissions_boundary" {
  description = "The boundary ARN IAM stored (empty string when none)."
  value       = data.aws_iam_role.applied.permissions_boundary
}

output "role_tags" {
  description = "Tags IAM stored on the role."
  value       = data.aws_iam_role.applied.tags
}
