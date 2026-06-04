# Budget notification cardinality per IMPL-0009 Phase 9.
#
# Default thresholds [50,80,100] + forecast 100 -> 3 ACTUAL + 1
# FORECASTED = 4 notification blocks. Custom [25,75] + forecast 90 ->
# 2 ACTUAL + 1 FORECASTED = 3 blocks.

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

run "default_thresholds_four_notifications" {
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

  # The rendered notification set embeds the apply-time SNS ARN, so it
  # is unknown at plan; assert the plan-known notification spec local
  # that drives the dynamic block instead (one ACTUAL per threshold + 1
  # FORECASTED).
  assert {
    condition     = length(local.budget_notifications) == 4
    error_message = "default 3 thresholds + 1 forecast must yield 4 notification specs"
  }

  assert {
    condition     = contains(flatten([for f in aws_budgets_budget.this.cost_filter : f.values]), "user:Team$platform-ai")
    error_message = "budget tag filter must assemble as user:<key>$<value>"
  }
}

run "custom_thresholds_three_notifications" {
  command = plan

  variables {
    budget_thresholds_percent         = [25, 75]
    budget_forecast_threshold_percent = 90
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
    condition     = length(local.budget_notifications) == 3
    error_message = "2 custom thresholds + 1 forecast must yield 3 notification specs"
  }
}
