# Mixed open + authenticated upstreams.
#
# ecr-public is open; docker-hub + ghcr require credentials. Expect
# 3 cache rules, 2 Secrets Manager secrets, 2 versions, 1 template,
# 1 IAM policy. The credential_arn wiring asserts that authenticated
# upstreams reference their own secret (not null) and open upstreams
# stay null.

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
  upstream_registries = ["ecr-public", "docker-hub", "ghcr"]
}

run "plan_mixed" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition     = length(aws_ecr_pull_through_cache_rule.this) == 3
    error_message = "Mixed shape must produce three pull-through cache rules"
  }
  assert {
    condition     = length(aws_secretsmanager_secret.upstream) == 2
    error_message = "Mixed shape must produce two Secrets Manager secrets (docker-hub + ghcr)"
  }
  assert {
    condition     = length(aws_secretsmanager_secret_version.upstream) == 2
    error_message = "Mixed shape must produce two Secrets Manager secret versions"
  }
  assert {
    condition     = aws_ecr_repository_creation_template.pull_through.prefix == "ROOT"
    error_message = "Mixed shape must produce exactly one repository creation template with prefix \"ROOT\""
  }
  assert {
    condition     = length(aws_iam_policy.node_pull_through) == 1
    error_message = "Default enable_node_pull_through_policy = true must emit exactly one IAM policy"
  }

  # credential_arn wiring: open upstreams stay null. Authenticated
  # upstreams' credential_arn is the secret's ARN, which is unknown
  # at plan time — assert structurally by checking the secret resource
  # exists in the docker-hub key (the for_each in main.tf wires the
  # arn deterministically when local.authenticated[key] is present).
  assert {
    condition     = aws_ecr_pull_through_cache_rule.this["ecr-public"].credential_arn == null
    error_message = "ecr-public cache rule's credential_arn must be null (open upstream)"
  }
  assert {
    condition     = contains(keys(aws_secretsmanager_secret.upstream), "docker-hub")
    error_message = "docker-hub must have a Secrets Manager secret whose ARN populates its cache rule's credential_arn"
  }
}
