# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches the IAM user, the SNS topic and the budget.

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  default_tags {
    tags = { DefaultTagProbe = "design-0029" }
  }
}

# A second provider whose default_tags also set a key the module owns.
# Runs that select it prove the module's value wins the collision.
provider "aws" {
  alias                       = "collision"
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  default_tags {
    tags = { DefaultTagProbe = "design-0029", Team = "from-default-tags" }
  }
}

variables {
  region        = "us-west-2"
  cost_tag      = { key = "Team", value = "platform-ai" }
  budget_amount = 500
}

run "default_tags_reach_resources" {
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
    condition     = aws_iam_user.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the IAM user (tags_all)"
  }

  assert {
    condition     = aws_sns_topic.alerts.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the SNS topic (tags_all)"
  }

  assert {
    condition     = aws_budgets_budget.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the budget (which carries no module-set tags, IMPL-0026 OQ 6a) (tags_all)"
  }
}

run "cost_tag_wins_over_default_tags" {
  command   = plan
  providers = { aws = aws.collision }

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

  # Resource tags beat provider default_tags on a key collision, so the
  # cost_tag pair still attributes spend correctly.
  assert {
    condition     = aws_iam_user.this.tags_all["Team"] == "platform-ai"
    error_message = "the cost_tag value must win over a provider default_tags value for the same key (IAM user)"
  }

  assert {
    condition     = aws_sns_topic.alerts.tags_all["Team"] == "platform-ai"
    error_message = "the cost_tag value must win over a provider default_tags value for the same key (SNS topic)"
  }

  # The budget carries no module-set tags (IMPL-0026 OQ 6a), so it shows
  # the default_tags value. This pins that decision rather than a defect.
  assert {
    condition     = aws_budgets_budget.this.tags_all["Team"] == "from-default-tags"
    error_message = "the budget carries default_tags only (IMPL-0026 OQ 6a), so a colliding default must show through"
  }
}
