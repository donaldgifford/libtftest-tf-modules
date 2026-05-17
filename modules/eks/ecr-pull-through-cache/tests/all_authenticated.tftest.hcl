# All-authenticated upstreams: every upstream needs a secret.
#
# docker-hub + ghcr — both require credentials. Expect 2 cache
# rules, 2 secrets, 2 versions.

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
  upstream_registries = ["docker-hub", "ghcr"]
}

run "plan_auth" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition     = length(aws_ecr_pull_through_cache_rule.this) == 2
    error_message = "All-authenticated upstreams must produce two pull-through cache rules"
  }
  assert {
    condition     = length(aws_secretsmanager_secret.upstream) == 2
    error_message = "All-authenticated upstreams must produce two Secrets Manager secrets"
  }
  assert {
    condition     = length(aws_secretsmanager_secret_version.upstream) == 2
    error_message = "All-authenticated upstreams must produce two Secrets Manager secret versions"
  }
}
