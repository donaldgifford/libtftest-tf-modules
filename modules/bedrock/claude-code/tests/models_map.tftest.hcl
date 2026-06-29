# Models-map invariants per IMPL-0009 Phase 9.
#
# Three Claude tiers (Opus/Sonnet/Haiku) -> three AIPs, three token
# alarms, and an IAM Allow statement scoped to 6 ARNs (3 AIPs + 3 FMs).
# AIP ARNs are apply-time-unknown, so the suite asserts plan-knowable
# facts: resource cardinality, names, and the FM-ARN local's length.

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  region        = "us-west-2"
  cost_tag      = { key = "Team", value = "platform-ai" }
  budget_amount = 500
  models = {
    opus   = { provider = "anthropic", model_id = "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-3-opus-20240229-v1:0" }
    sonnet = { provider = "anthropic", model_id = "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0" }
    haiku  = { provider = "anthropic", model_id = "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-3-5-haiku-20241022-v1:0" }
  }
}

run "three_aips" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "111122223333"
    }
  }

  override_data {
    target = data.aws_organizations_organization.current[0]
    values = {
      master_account_id = "111122223333"
    }
  }

  assert {
    condition     = length(aws_bedrock_inference_profile.this) == 3
    error_message = "3-entry models map must create exactly 3 AIPs"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.token_count) == 3
    error_message = "3 AIPs must produce exactly 3 token alarms"
  }

  assert {
    condition     = aws_bedrock_inference_profile.this["opus"].name == "opus"
    error_message = "AIP name must equal its models map key"
  }

  assert {
    condition     = aws_bedrock_inference_profile.this["haiku"].model_source[0].copy_from == "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-3-5-haiku-20241022-v1:0"
    error_message = "AIP model_source.copy_from must equal the entry's model_id"
  }

  assert {
    condition     = length(local.model_fm_arns) == 3
    error_message = "3 models must yield 3 backing FM ARNs (FM half of the 6-ARN Allow statement)"
  }

  assert {
    condition     = length(local.aip_arns) == 3
    error_message = "3 AIPs must yield 3 AIP ARNs (AIP half of the 6-ARN Allow statement)"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.token_count["sonnet"].alarm_name == "platform-ai-claude-code-sonnet-tokens"
    error_message = "alarm name must be '<user>-<aip>-tokens'"
  }
}
