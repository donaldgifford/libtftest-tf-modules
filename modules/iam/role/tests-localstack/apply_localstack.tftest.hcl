# Apply against LocalStack — the platform-access-shaped instance end
# to end (IMPL-0022 task 3.1).
#
# Community-safe: pure IAM + STS, token-free
# `localstack/localstack:4.4`. No Pro tier, no auth token, no named
# volume.
#
# WHAT THIS SUITE DOES NOT PROVE: that the trust policy is ENFORCED.
# LocalStack's STS mints credentials for any role ARN regardless of
# who is allowed to assume it (IMPL-0015 Phase 1), so an AssumeRole
# here would pass against a trust policy naming nobody. The suite
# asserts the IAM SURFACE — what the API stored and serves back —
# and FINDINGS.md leads with that caveat.
#
# Required env vars (the `just tf test-localstack` recipe wires these):
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    iam = "http://localhost:4566"
    sts = "http://localhost:4566"
  }
}

variables {
  name        = "sse-platform-access"
  description = "Assumed by the hub argocd-deployer to reach this spoke's cluster"

  trusted_role_arns = [
    "arn:aws:iam::000000000000:role/hub-argocd-deployer",
    "arn:aws:iam::000000000000:role/atlantis-pod-identity",
  ]

  managed_policy_arns  = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
  max_session_duration = 7200
  tags                 = { ManagedBy = "terraform", Suite = "iam-role" }
}

run "setup" {
  command = apply

  module {
    source = "./tests-localstack/fixtures/policies"
  }
}

run "apply_platform_access_shaped" {
  command = apply

  variables {
    customer_managed_policy_arns = [run.setup.caller_owned_policy_arn]
    permissions_boundary         = run.setup.boundary_policy_arn

    inline_policies = {
      eks-access = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Allow"
          Action   = ["eks:DescribeCluster", "eks:ListClusters"]
          Resource = "*"
        }]
      })
    }
  }

  # unique_id is minted by IAM, never by the provider — the strongest
  # single signal that the role really landed on the far side.
  assert {
    condition     = startswith(output.role_unique_id, "AROA")
    error_message = "the role's unique id must be the AROA... value IAM mints at create"
  }

  assert {
    condition     = output.role_name == "sse-platform-access"
    error_message = "the exact name must survive the apply (the by-name contract)"
  }

  assert {
    condition     = output.role_arn == "arn:aws:iam::000000000000:role/sse-platform-access"
    error_message = "role_arn must be the ARN IAM returns for the default path"
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.managed) == 1 && length(aws_iam_role_policy_attachment.customer) == 1
    error_message = "both policy channels must attach live"
  }

  assert {
    condition     = aws_iam_role_policy.inline["eks-access"].name == "eks-access"
    error_message = "the inline policy must apply under its map key"
  }
}

# Read the role BACK through data sources: an independent check of
# what IAM stored, not what the provider recorded.
run "verify_readback" {
  command = apply

  variables {
    role_name          = run.apply_platform_access_shaped.role_name
    inline_policy_name = "eks-access"
  }

  module {
    source = "./tests-localstack/fixtures/verify"
  }

  assert {
    condition     = output.role_arn == "arn:aws:iam::000000000000:role/sse-platform-access"
    error_message = "get-role must return the role at the composed ARN"
  }

  assert {
    condition     = output.role_path == "/"
    error_message = "IAM must have stored the default path"
  }

  assert {
    condition     = output.max_session_duration == 7200
    error_message = "IAM must have stored the caller's session duration"
  }

  # The trust document round-trip: both principals present, exactly
  # one statement, exactly sts:AssumeRole. Two principals means
  # Principal.AWS is a LIST (the single-element-collapse gotcha).
  assert {
    condition     = length(jsondecode(output.assume_role_policy).Statement) == 1
    error_message = "IAM must have stored exactly the one composed trust statement"
  }

  assert {
    condition = toset(one(jsondecode(output.assume_role_policy).Statement).Principal.AWS) == toset([
      "arn:aws:iam::000000000000:role/hub-argocd-deployer",
      "arn:aws:iam::000000000000:role/atlantis-pod-identity",
    ])
    error_message = "IAM must have stored both trusted principals and nothing else"
  }

  assert {
    condition     = one(jsondecode(output.assume_role_policy).Statement).Action == "sts:AssumeRole"
    error_message = "IAM must have stored exactly the sts:AssumeRole grant"
  }

  assert {
    condition     = output.permissions_boundary != ""
    error_message = "IAM must have stored the permissions boundary"
  }

  assert {
    condition     = output.role_tags["ManagedBy"] == "terraform"
    error_message = "IAM must have stored the caller's tags"
  }
}
