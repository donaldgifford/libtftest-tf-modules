# All-open upstreams: zero Secrets Manager resources.
#
# ecr-public + kubernetes + mcr — all three are open (no auth
# required). Default enable_node_pull_through_policy = true emits
# one IAM policy.

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
  upstream_registries = ["ecr-public", "kubernetes", "mcr"]
}

run "plan_open" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition     = length(aws_ecr_pull_through_cache_rule.this) == 3
    error_message = "Three open upstreams must produce three pull-through cache rules"
  }
  assert {
    condition     = length(aws_secretsmanager_secret.upstream) == 0
    error_message = "All-open upstreams must produce zero Secrets Manager secrets"
  }
  assert {
    condition     = length(aws_secretsmanager_secret_version.upstream) == 0
    error_message = "All-open upstreams must produce zero Secrets Manager secret versions"
  }
  assert {
    condition     = length(aws_iam_policy.node_pull_through) == 1
    error_message = "Default enable_node_pull_through_policy = true must emit exactly one IAM policy"
  }

  # credential_arn is null for every open upstream.
  assert {
    condition     = aws_ecr_pull_through_cache_rule.this["ecr-public"].credential_arn == null
    error_message = "ecr-public's credential_arn must be null (open upstream)"
  }
}
