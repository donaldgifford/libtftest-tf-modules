# Variable-validation negatives per IMPL-0009 Phase 9. Each run wires
# expect_failures at the offending variable. Validation fires before any
# data source is read, so only caller_identity is stubbed (defensively);
# the org data source is left alone to avoid count=0 override targets.

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

run "invalid_region_rejected" {
  command = plan

  variables {
    region = "invalid-region"
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
    var.region,
  ]
}

run "invalid_activation_rejected" {
  command = plan

  variables {
    cost_allocation_tag_activation = "wrong"
  }

  # No org override here: activation = "wrong" gates the org data source
  # to count 0, so data.aws_organizations_organization.current[0] does
  # not exist to override.
  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "111122223333"
    }
  }

  expect_failures = [
    var.cost_allocation_tag_activation,
  ]
}

run "invalid_slack_delivery_rejected" {
  command = plan

  variables {
    slack_delivery = "teams"
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
    var.slack_delivery,
  ]
}

run "invalid_model_provider_rejected" {
  command = plan

  variables {
    models = {
      x = { provider = "nonexistent", model_id = "arn:aws:bedrock:us-west-2::foundation-model/x" }
    }
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
    var.models,
  ]
}

run "zero_budget_amount_rejected" {
  command = plan

  variables {
    budget_amount = 0
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
    var.budget_amount,
  ]
}

run "out_of_range_threshold_rejected" {
  command = plan

  variables {
    budget_thresholds_percent = [150]
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
    var.budget_thresholds_percent,
  ]
}

run "empty_cost_tag_key_rejected" {
  command = plan

  variables {
    cost_tag = { key = "", value = "platform-ai" }
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
    var.cost_tag,
  ]
}
