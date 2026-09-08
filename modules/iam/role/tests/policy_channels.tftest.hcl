# The three policy channels and their address stability
# (IMPL-0022 task 1.6).
#
# Every channel keys by a stable value — the policy ARN for the two
# attachment for_eachs, the policy name for inline — so adding or
# removing one entry never churns a sibling's address. That is the
# whole reason the fleet prefers for_each over count, and it is worth
# a test because a regression here shows up as unexplained
# destroy/create churn in a production plan, not as an error.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name              = "channels-role"
  trusted_role_arns = ["arn:aws:iam::000000000000:role/atlantis-pod-identity"]
}

run "all_three_channels" {
  command = plan

  variables {
    managed_policy_arns = [
      "arn:aws:iam::aws:policy/ReadOnlyAccess",
      "arn:aws:iam::aws:policy/AWSCloudTrail_ReadOnlyAccess",
    ]

    customer_managed_policy_arns = [
      "arn:aws:iam::000000000000:policy/platform-deploy",
    ]

    inline_policies = {
      s3-evidence = jsonencode({
        Version   = "2012-10-17"
        Statement = [{ Effect = "Allow", Action = "s3:PutObject", Resource = "*" }]
      })
      kms-decrypt = jsonencode({
        Version   = "2012-10-17"
        Statement = [{ Effect = "Allow", Action = "kms:Decrypt", Resource = "*" }]
      })
    }
  }

  # Addresses key by the ARN itself, not a list index.
  assert {
    condition     = aws_iam_role_policy_attachment.managed["arn:aws:iam::aws:policy/ReadOnlyAccess"].policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "managed attachments must be addressed by policy ARN (stable under list edits)"
  }

  assert {
    condition     = aws_iam_role_policy_attachment.customer["arn:aws:iam::000000000000:policy/platform-deploy"].policy_arn == "arn:aws:iam::000000000000:policy/platform-deploy"
    error_message = "customer attachments must be addressed by policy ARN"
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.managed) == 2
    error_message = "both AWS-managed policies must attach"
  }

  # The channel split is the point: AWS-owned and caller-owned ARNs
  # land in different resources so a plan distinguishes them at a
  # glance.
  assert {
    condition     = length(aws_iam_role_policy_attachment.customer) == 1
    error_message = "the caller-owned channel must stay separate from the AWS-managed one"
  }

  assert {
    condition     = toset(keys(aws_iam_role_policy.inline)) == toset(["s3-evidence", "kms-decrypt"])
    error_message = "inline policies must be addressed by their map keys"
  }

  assert {
    condition     = alltrue([for p in values(aws_iam_role_policy.inline) : p.role == aws_iam_role.this.name])
    error_message = "every inline policy must bind to this module's role"
  }
}

# The same call with one managed ARN REMOVED: the surviving entries
# keep their addresses, which is exactly what keying by ARN buys.
run "removing_one_entry_leaves_siblings_addressed" {
  command = plan

  variables {
    managed_policy_arns = [
      "arn:aws:iam::aws:policy/AWSCloudTrail_ReadOnlyAccess",
    ]

    inline_policies = {
      kms-decrypt = jsonencode({
        Version   = "2012-10-17"
        Statement = [{ Effect = "Allow", Action = "kms:Decrypt", Resource = "*" }]
      })
    }
  }

  assert {
    condition     = aws_iam_role_policy_attachment.managed["arn:aws:iam::aws:policy/AWSCloudTrail_ReadOnlyAccess"].policy_arn == "arn:aws:iam::aws:policy/AWSCloudTrail_ReadOnlyAccess"
    error_message = "the surviving managed attachment must keep its ARN-keyed address after a sibling is removed"
  }

  assert {
    condition     = aws_iam_role_policy.inline["kms-decrypt"].name == "kms-decrypt"
    error_message = "the surviving inline policy must keep its name-keyed address after a sibling is removed"
  }
}

run "no_policies_is_legal" {
  command = plan

  assert {
    condition = alltrue([
      length(aws_iam_role_policy_attachment.managed) == 0,
      length(aws_iam_role_policy_attachment.customer) == 0,
      length(aws_iam_role_policy.inline) == 0,
    ])
    error_message = "a role with no policies must plan clean — permissions can arrive later, and a trust-boundary role is useful before it is empowered"
  }

  assert {
    condition     = output.role_name == "channels-role"
    error_message = "the pointer outputs must resolve on a bare role"
  }
}
