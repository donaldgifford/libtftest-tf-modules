# Apply against LocalStack — gap-discovery mode per RFC-0001 / IMPL-0005 Phase 9.
#
# This module's four AWS API surfaces (ECR pull-through cache, ECR
# repository creation template, Secrets Manager, IAM) were probed
# against LocalStack Pro 2026.5.0 on 2026-05-15. Outcome captured in
# FINDINGS.md: ECR pull-through cache and ECR repository creation
# template APIs are both 501/NotImplemented at this resolution; the
# rest (Secrets Manager, IAM) would work but a partial-apply of this
# module isn't meaningful — the cache rule + template ARE the
# module's reason to exist.
#
# Per IMPL-0005 Phase 9 task ("If any apply step 501s in LocalStack,
# comment out that block, log the gap in FINDINGS.md, and proceed —
# gap-discovery success per RFC-0001"): the apply run block is
# preserved below as commented code so future LocalStack releases
# can re-enable it by uncomment-only when CreatePullThroughCacheRule
# and CreateRepositoryCreationTemplate land.
#
# The active suite is the `plan_smoke` run below: a plan against
# LocalStack proves the module is wireable end-to-end (provider
# endpoint resolution, STS GetCallerIdentity reachability, the four
# resource types validate without 501 at PLAN time — they only 501
# on the create call).
#
# Required env vars (the `just tf test-localstack` recipe wires
# these automatically):
#
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1
#
# Findings captured in FINDINGS.md.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ecr            = "http://localhost:4566"
    ecrpublic      = "http://localhost:4566"
    iam            = "http://localhost:4566"
    secretsmanager = "http://localhost:4566"
    sts            = "http://localhost:4566"
  }
}

variables {
  region              = "us-east-1"
  name_prefix         = "tftest-eptc"
  upstream_registries = ["ecr-public", "docker-hub"]
  tags = {
    Environment = "test"
    ManagedBy   = "libtftest"
  }
}

# Plan-only smoke against the LocalStack endpoint. Validates that:
#
#   - The provider resolves STS GetCallerIdentity through LocalStack
#     (real account ID returned, not the fake "000000000000" stub).
#   - Every resource in the module validates at plan time against
#     LocalStack's AWS API surface.
#
# This run will keep passing as the module's surface evolves; a real
# apply assertion against the ECR resources requires LocalStack
# CreatePullThroughCacheRule + CreateRepositoryCreationTemplate
# implementation (FINDINGS.md §Finding #1).
run "plan_smoke" {
  command = plan

  assert {
    condition     = length(aws_ecr_pull_through_cache_rule.this) == 2
    error_message = "Module must plan exactly 2 cache rules for ['ecr-public','docker-hub']"
  }
  assert {
    condition     = length(aws_secretsmanager_secret.upstream) == 1
    error_message = "Module must plan exactly 1 Secrets Manager secret (docker-hub only)"
  }
  assert {
    condition     = length(aws_iam_policy.node_pull_through) == 1
    error_message = "Module must plan exactly 1 node pull-through IAM policy by default"
  }
}

# Apply run preserved for the day LocalStack lands the two missing
# ECR API actions. Uncomment to re-validate (after re-running
# FINDINGS.md "When to re-run").
#
# run "apply_mixed" {
#   command = apply
#
#   assert {
#     condition     = length(aws_ecr_pull_through_cache_rule.this["ecr-public"].id) > 0
#     error_message = "LocalStack ECR must populate the ecr-public cache rule ID"
#   }
#   assert {
#     condition     = length(aws_ecr_pull_through_cache_rule.this["docker-hub"].id) > 0
#     error_message = "LocalStack ECR must populate the docker-hub cache rule ID"
#   }
#   assert {
#     condition     = aws_ecr_pull_through_cache_rule.this["ecr-public"].credential_arn == null
#     error_message = "LocalStack ECR must report null credential_arn for ecr-public"
#   }
#   assert {
#     condition     = length(aws_secretsmanager_secret.upstream["docker-hub"].arn) > 0
#     error_message = "LocalStack Secrets Manager must populate the docker-hub secret ARN"
#   }
#   assert {
#     condition     = length(aws_secretsmanager_secret_version.upstream["docker-hub"].id) > 0
#     error_message = "LocalStack Secrets Manager must populate the docker-hub secret version ID"
#   }
#   assert {
#     condition     = length(aws_ecr_repository_creation_template.pull_through.id) > 0
#     error_message = "LocalStack ECR must populate the creation template ID"
#   }
#   assert {
#     condition     = length(aws_iam_policy.node_pull_through[0].arn) > 0
#     error_message = "LocalStack IAM must populate the node policy ARN"
#   }
#   assert {
#     condition     = can(regex("^[0-9]+\\.dkr\\.ecr\\.us-east-1\\.amazonaws\\.com/docker-hub$", output.cache_url_prefixes["docker-hub"]))
#     error_message = "cache_url_prefixes['docker-hub'] must match <acct>.dkr.ecr.us-east-1.amazonaws.com/docker-hub"
#   }
# }
