# Apply against LocalStack — gap-discovery mode per RFC-0001 / IMPL-0005
# Phase 9 fall-back pattern (see FINDINGS.md for the full probe results).
#
# This module's load-bearing AWS surface — Bedrock application inference
# profiles, AWS Budgets, and Cost Explorer cost-allocation tags — was
# probed against LocalStack Community 3.8.1 on 2026-06-02 and is
# unavailable: bedrock has no implemented operations (HTTP 500 "Unable
# to find operation"), budgets and ce return HTTP 501 "not yet
# implemented or pro feature", and organizations returns 501 as well.
# A full module apply is therefore not meaningful here, so the
# `apply_default` run is preserved below as commented code (re-enable by
# uncomment-only once LocalStack lands the APIs — or a Pro license is
# available at run time).
#
# The active run is `plan_smoke`: a plan against the LocalStack
# endpoints with a 1-entry models map and cost_allocation_tag_activation
# = "none" (so the organizations data source — which 501s — is gated to
# count 0). It proves the module is wireable end-to-end against the
# LocalStack provider (STS GetCallerIdentity resolves; every resource
# validates at plan time — the Bedrock/Budgets/CE resources only fail on
# create, not plan).
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
    bedrock       = "http://localhost:4566"
    budgets       = "http://localhost:4566"
    cloudwatch    = "http://localhost:4566"
    costexplorer  = "http://localhost:4566"
    iam           = "http://localhost:4566"
    organizations = "http://localhost:4566"
    sns           = "http://localhost:4566"
    sts           = "http://localhost:4566"
    s3            = "http://s3.localhost.localstack.cloud:4566"
  }
}

variables {
  region        = "us-east-1"
  cost_tag      = { key = "Team", value = "tftest-bedrock" }
  budget_amount = 100
  # none mode keeps the organizations data source (which 501s on
  # LocalStack Community) gated to count 0.
  cost_allocation_tag_activation = "none"
  models = {
    haiku = { provider = "anthropic", model_id = "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-5-haiku-20241022-v1:0" }
  }
}

run "plan_smoke" {
  command = plan

  assert {
    condition     = length(aws_bedrock_inference_profile.this) == 1
    error_message = "Plan must wire exactly one AIP from the 1-entry models map against LocalStack endpoints"
  }

  assert {
    condition     = aws_iam_user.this.name == "tftest-bedrock-claude-code"
    error_message = "Plan must resolve the IAM user name against LocalStack endpoints"
  }

  assert {
    condition     = length(aws_ce_cost_allocation_tag.this) == 0
    error_message = "none mode must plan zero cost-allocation tag resources (gating off the 501-prone CE + Organizations calls)"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.token_count) == 1
    error_message = "Plan must wire exactly one token alarm for the single AIP"
  }
}

# Full apply — STILL BLOCKED on Pro 2026.6.0 (probed 2026-07-01):
# aws_bedrock_inference_profile hits `CreateInferenceProfile => 501
# InternalFailure: ... operation on the bedrock service is not currently
# supported by LocalStack`. The AIP is the module's reason to exist, so the
# suite stays plan-only per the RFC-0001 fall-back; re-enable when LocalStack
# implements CreateInferenceProfile. See FINDINGS.md §Probe results.
# (Downstream IAM / SNS / Budgets are covered separately by plan_smoke.)
#
# run "apply_default" {
#   command = apply
#
#   assert {
#     condition     = length(aws_bedrock_inference_profile.this["haiku"].id) > 0
#     error_message = "LocalStack must populate the AIP id on create"
#   }
#
#   assert {
#     condition     = length(aws_iam_policy.bedrock_invoke.arn) > 0
#     error_message = "LocalStack must populate the IAM policy ARN on create"
#   }
#
#   assert {
#     condition     = aws_budgets_budget.this.limit_amount == "100"
#     error_message = "LocalStack must create the budget with the configured limit"
#   }
#
#   assert {
#     condition     = length(aws_sns_topic.alerts.arn) > 0
#     error_message = "LocalStack must create the SNS topic"
#   }
# }
