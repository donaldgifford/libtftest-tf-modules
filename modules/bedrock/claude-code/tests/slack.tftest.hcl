# Slack delivery + precondition per IMPL-0009 Phase 9 (DESIGN-0009 Q10).
#
# Default: no Slack subscription. chatbot -> https protocol; lambda ->
# lambda protocol. Negative: slack_enabled with a null target trips the
# lifecycle.precondition on the Slack subscription.

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

run "no_slack_by_default" {
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
    condition     = length(aws_sns_topic_subscription.slack) == 0
    error_message = "slack_enabled defaults to false — zero Slack subscriptions"
  }
}

run "chatbot_https" {
  command = plan

  variables {
    slack_enabled  = true
    slack_delivery = "chatbot"
    slack_target   = "https://global.sns-api.chatbot.amazonaws.com"
  }

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
    condition     = length(aws_sns_topic_subscription.slack) == 1
    error_message = "slack_enabled = true must create exactly one Slack subscription"
  }

  assert {
    condition     = aws_sns_topic_subscription.slack[0].protocol == "https"
    error_message = "chatbot delivery must use the https protocol"
  }
}

run "lambda_relay" {
  command = plan

  variables {
    slack_enabled  = true
    slack_delivery = "lambda"
    slack_target   = "arn:aws:lambda:us-west-2:111122223333:function:slack-relay"
  }

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
    condition     = aws_sns_topic_subscription.slack[0].protocol == "lambda"
    error_message = "lambda delivery must use the lambda protocol"
  }
}

run "slack_enabled_without_target_rejected" {
  command = plan

  variables {
    slack_enabled = true
    slack_target  = null
  }

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

  expect_failures = [
    aws_sns_topic_subscription.slack,
  ]
}
