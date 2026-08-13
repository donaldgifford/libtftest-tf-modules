# read_principals resource-policy shapes (IMPL-0019 2.3 / DESIGN-0020
# OQ 3a).
#
# Real provider + fake creds — see default.tftest.hcl for why
# mock_provider is structurally impossible in this module.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name = "platform-db-master"
}

run "no_principals_no_policy_resource" {
  command = plan

  assert {
    condition     = length(aws_secretsmanager_secret_policy.read_access) == 0
    error_message = "an empty read_principals must create no policy resource at all (count-gated)"
  }

  assert {
    condition     = length(data.aws_iam_policy_document.read_access) == 0
    error_message = "an empty read_principals must not even compose the policy document"
  }
}

run "grant_shape_two_principals" {
  command = plan

  variables {
    read_principals = [
      "arn:aws:iam::111111111111:role/app-reader",
      "arn:aws:iam::222222222222:root",
    ]
  }

  assert {
    condition     = length(aws_secretsmanager_secret_policy.read_access) == 1
    error_message = "read_principals set must create exactly one policy resource"
  }

  assert {
    condition = (
      jsondecode(data.aws_iam_policy_document.read_access[0].json).Statement[0].Sid
      == "AllowSecretRead"
    )
    error_message = "the grant statement must carry the AllowSecretRead sid"
  }

  assert {
    condition = toset(
      jsondecode(data.aws_iam_policy_document.read_access[0].json).Statement[0].Action
      ) == toset([
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
    ])
    error_message = "the grant must be exactly GetSecretValue + DescribeSecret (read-only, no mutation actions)"
  }

  assert {
    condition = toset(
      jsondecode(data.aws_iam_policy_document.read_access[0].json).Statement[0].Principal.AWS
      ) == toset([
        "arn:aws:iam::111111111111:role/app-reader",
        "arn:aws:iam::222222222222:root",
    ])
    error_message = "the grant principals must be exactly the read_principals list"
  }
}

run "wildcard_principal_rejected" {
  command = plan

  variables {
    read_principals = ["*"]
  }

  expect_failures = [var.read_principals]
}

run "non_arn_principal_rejected" {
  command = plan

  variables {
    read_principals = ["app-reader"]
  }

  expect_failures = [var.read_principals]
}
