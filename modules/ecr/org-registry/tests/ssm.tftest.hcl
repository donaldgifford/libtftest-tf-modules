# SSM Parameter Store publication matrix: off / on same-account /
# on cross-account.
#
# Default (publish_to_ssm = false): zero SSM resources, zero
# resource-based policy reads. Same-account (true, no cross-account
# org): two Standard-tier parameters, no resource-based policy.
# Cross-account (true, cross-account org id set): two Advanced-tier
# parameters plus the resource-based policy JSON scoped by
# aws:PrincipalOrgID.

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

run "ssm_off_default" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  assert {
    condition     = length(aws_ssm_parameter.publisher_policy_arn) == 0
    error_message = "Default publish_to_ssm = false must plan zero ARN SSM parameters"
  }

  assert {
    condition     = length(aws_ssm_parameter.publisher_policy_json) == 0
    error_message = "Default publish_to_ssm = false must plan zero JSON SSM parameters"
  }

  assert {
    condition     = length(data.aws_iam_policy_document.ssm_org_read) == 0
    error_message = "Default must not read the cross-account resource-policy doc"
  }
}

run "ssm_on_same_account" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  variables {
    publish_to_ssm = true
  }

  assert {
    condition     = length(aws_ssm_parameter.publisher_policy_arn) == 1 && length(aws_ssm_parameter.publisher_policy_json) == 1
    error_message = "Same-account SSM publication must plan exactly one ARN parameter and one JSON parameter"
  }

  assert {
    condition     = aws_ssm_parameter.publisher_policy_arn[0].tier == "Standard" && aws_ssm_parameter.publisher_policy_json[0].tier == "Standard"
    error_message = "Same-account (no cross-account org id) must use Standard tier on both parameters"
  }

  assert {
    condition     = length(data.aws_iam_policy_document.ssm_org_read) == 0
    error_message = "Same-account mode must NOT emit the cross-account resource-policy doc"
  }
}

run "ssm_on_cross_account" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  variables {
    publish_to_ssm           = true
    ssm_cross_account_org_id = "o-crossacct12"
  }

  assert {
    condition     = length(aws_ssm_parameter.publisher_policy_arn) == 1 && length(aws_ssm_parameter.publisher_policy_json) == 1
    error_message = "Cross-account SSM publication must plan exactly one ARN parameter and one JSON parameter"
  }

  assert {
    condition     = aws_ssm_parameter.publisher_policy_arn[0].tier == "Advanced" && aws_ssm_parameter.publisher_policy_json[0].tier == "Advanced"
    error_message = "Cross-account mode must flip both parameters to Advanced tier (prerequisite for resource-based policies)"
  }

  assert {
    condition     = length(data.aws_iam_policy_document.ssm_org_read) == 1
    error_message = "Cross-account mode must emit exactly one ssm_org_read policy doc"
  }

  # Assert via the structural HCL (plan-known) rather than the
  # rendered .json (unknown at plan because the resources[] list
  # contains aws_ssm_parameter.X[0].arn, computed at apply). The
  # `condition` block is a set in the data source schema, so use
  # `one()` to extract the singleton.
  assert {
    condition     = one(data.aws_iam_policy_document.ssm_org_read[0].statement[0].condition).variable == "aws:PrincipalOrgID"
    error_message = "Cross-account resource-policy must condition on aws:PrincipalOrgID"
  }

  assert {
    condition     = one(data.aws_iam_policy_document.ssm_org_read[0].statement[0].condition).values[0] == "o-crossacct12"
    error_message = "Cross-account resource-policy condition value must equal the supplied org ID"
  }
}
