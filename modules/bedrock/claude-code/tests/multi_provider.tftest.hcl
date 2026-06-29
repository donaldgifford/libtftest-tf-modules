# Multi-provider invariants per IMPL-0009 Phase 9 (DESIGN-0009 Q5
# Day-1 multi-provider). Four providers in one models map -> four AIPs,
# created uniformly (the module is provider-agnostic at the Bedrock
# layer) and tagged with the cost-allocation pair regardless of vendor.

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
    opus  = { provider = "anthropic", model_id = "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-3-opus-20240229-v1:0" }
    nova  = { provider = "amazon", model_id = "arn:aws:bedrock:us-west-2::foundation-model/amazon.nova-pro-v1:0" }
    llama = { provider = "meta", model_id = "arn:aws:bedrock:us-west-2::foundation-model/meta.llama3-1-70b-instruct-v1:0" }
    gpt55 = { provider = "openai", model_id = "arn:aws:bedrock:us-west-2::foundation-model/openai.gpt-oss-120b-1:0" }
  }
}

run "four_providers" {
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
    condition     = length(aws_bedrock_inference_profile.this) == 4
    error_message = "4-provider models map must create exactly 4 AIPs (provider-agnostic creation)"
  }

  assert {
    condition     = aws_bedrock_inference_profile.this["nova"].tags["Team"] == "platform-ai"
    error_message = "Amazon AIP must carry the cost-allocation tag like every other provider"
  }

  assert {
    condition     = aws_bedrock_inference_profile.this["gpt55"].tags["Team"] == "platform-ai"
    error_message = "OpenAI AIP must carry the cost-allocation tag like every other provider"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.token_count) == 4
    error_message = "4 AIPs must produce 4 token alarms regardless of provider"
  }
}
