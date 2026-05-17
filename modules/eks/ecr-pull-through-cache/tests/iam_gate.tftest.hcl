# ADR-0015 gate (a): emission-time consent.
#
# enable_node_pull_through_policy = false must produce zero IAM
# resources and a null node_pull_through_policy_arn output. The
# consumer's Terragrunt config provides gate (b) (the actual attach
# to a node role) — either consent alone is a no-op.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  region                          = "us-east-1"
  name_prefix                     = "libtftest"
  upstream_registries             = ["docker-hub"]
  enable_node_pull_through_policy = false
}

run "iam_disabled" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition     = length(aws_iam_policy.node_pull_through) == 0
    error_message = "enable_node_pull_through_policy = false must produce zero IAM policy resources"
  }
  assert {
    condition     = output.node_pull_through_policy_arn == null
    error_message = "enable_node_pull_through_policy = false must produce a null node_pull_through_policy_arn output"
  }
}
