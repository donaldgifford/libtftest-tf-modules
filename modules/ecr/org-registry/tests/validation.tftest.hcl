# Variable validation negatives.
#
# Five expect_failures runs:
#   - retention_days = 0 (must be >= 1)
#   - helm_charts_prefix = "ROOT" (catch-all reserved literal)
#   - organizations_org_id malformed
#   - ssm_parameter_path_arn missing leading slash
#   - ssm_cross_account_org_id malformed
# All should be rejected at plan time by variable validation blocks.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name_prefix          = "platform"
  organizations_org_id = "o-test1234ab"
}

run "negative_pre_release_zero" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  variables {
    pre_release_retention_days = 0
  }

  expect_failures = [var.pre_release_retention_days]
}

run "negative_helm_prefix_root" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  variables {
    helm_charts_prefix = "ROOT"
  }

  expect_failures = [var.helm_charts_prefix]
}

run "negative_bad_org_id" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  variables {
    organizations_org_id = "bogus"
  }

  expect_failures = [var.organizations_org_id]
}

run "negative_bad_ssm_path" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  variables {
    publish_to_ssm         = true
    ssm_parameter_path_arn = "no-leading-slash"
  }

  expect_failures = [var.ssm_parameter_path_arn]
}

run "negative_bad_cross_account_org_id" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  variables {
    publish_to_ssm           = true
    ssm_cross_account_org_id = "not-an-org-id"
  }

  expect_failures = [var.ssm_cross_account_org_id]
}
