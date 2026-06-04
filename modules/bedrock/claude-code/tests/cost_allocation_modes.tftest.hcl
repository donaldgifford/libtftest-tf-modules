# Cost-allocation activation modes per IMPL-0009 Phase 9.
#
# 'local' (default) creates one aws_ce_cost_allocation_tag; 'payer' and
# 'none' create zero (the org data source is also count-gated off, so
# those runs override only caller_identity).

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

run "local_mode_one_tag" {
  command = plan

  variables {
    cost_allocation_tag_activation = "local"
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
    condition     = length(aws_ce_cost_allocation_tag.this) == 1
    error_message = "local mode must create exactly one cost-allocation tag"
  }

  assert {
    condition     = length(data.aws_organizations_organization.current) == 1
    error_message = "local mode must read the org data source (count 1) for the guardrail"
  }
}

run "payer_mode_zero_tags" {
  command = plan

  variables {
    cost_allocation_tag_activation = "payer"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "111122223333"
    }
  }

  assert {
    condition     = length(aws_ce_cost_allocation_tag.this) == 0
    error_message = "payer mode must create zero cost-allocation tags (activation happens in the management account)"
  }

  assert {
    condition     = length(data.aws_organizations_organization.current) == 0
    error_message = "payer mode must not read the org data source"
  }
}

run "none_mode_zero_tags" {
  command = plan

  variables {
    cost_allocation_tag_activation = "none"
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "111122223333"
    }
  }

  assert {
    condition     = length(aws_ce_cost_allocation_tag.this) == 0
    error_message = "none mode must create zero cost-allocation tags"
  }
}
