# Default-shape plan-time invariants per IMPL-0009 Phase 9.
#
# Empty models map (Q3 default) — zero AIPs, zero alarms, no IAM Allow
# statement. Both identity data sources are stubbed via override_data so
# terraform test never attempts a real AWS call (STS GetCallerIdentity,
# Organizations DescribeOrganization) during plan.

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
}

run "default_shape" {
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
    condition     = aws_iam_user.this.name == "platform-ai-claude-code"
    error_message = "IAM user name must derive from cost_tag.value as '<value>-claude-code'"
  }

  assert {
    condition     = aws_iam_policy.bedrock_invoke.name == "platform-ai-claude-code-bedrock-invoke"
    error_message = "IAM policy name must be '<user>-bedrock-invoke'"
  }

  assert {
    condition     = aws_iam_user_policy_attachment.this.user == "platform-ai-claude-code"
    error_message = "Policy attachment must bind to the module's IAM user"
  }

  assert {
    condition     = aws_sns_topic.alerts.name == "platform-ai-claude-code-alerts"
    error_message = "SNS topic name must be '<user>-alerts'"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 0
    error_message = "alert_emails defaults to [] — zero email subscriptions"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.slack) == 0
    error_message = "slack_enabled defaults to false — zero Slack subscriptions"
  }

  assert {
    condition     = length(aws_bedrock_inference_profile.this) == 0
    error_message = "empty models map must create zero AIPs"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.token_count) == 0
    error_message = "empty models map must create zero token alarms"
  }

  assert {
    condition     = aws_budgets_budget.this.limit_amount == "500"
    error_message = "budget limit_amount must equal tostring(var.budget_amount)"
  }

  assert {
    condition     = length(aws_ce_cost_allocation_tag.this) == 1
    error_message = "cost_allocation_tag_activation defaults to 'local' — exactly one cost-allocation tag resource"
  }
}
