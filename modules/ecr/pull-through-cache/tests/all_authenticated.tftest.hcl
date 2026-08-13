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

  # The no-leak gate (IMPL-0019 Phase 4): the placeholder is seeded
  # write-only, so even in a plan it must surface as null. If this
  # fails, someone reverted to the persisted secret_string argument.
  assert {
    condition = alltrue([
      for v in aws_secretsmanager_secret_version.upstream : v.secret_string_wo == null
    ])
    error_message = "the credential placeholder leaked into the plan — secret_string_wo (write-only) is the only allowed seed path"
  }
}
