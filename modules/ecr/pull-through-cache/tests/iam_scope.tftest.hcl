# IAM policy resource ARN scope.
#
# The node IAM policy's Resource ARN must be scoped to var.region +
# this account's ECR repositories. The account ID is supplied via
# override_data on data.aws_caller_identity.current — assert the
# substituted ARN matches the expected shape.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  region              = "us-east-1"
  name_prefix         = "libtftest"
  upstream_registries = ["ecr-public"]
}

run "policy_scope" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  assert {
    condition     = strcontains(aws_iam_policy.node_pull_through[0].policy, "arn:aws:ecr:us-east-1:123456789012:repository/*")
    error_message = "IAM policy Resource must be scoped to arn:aws:ecr:<region>:<account_id>:repository/*"
  }
}
