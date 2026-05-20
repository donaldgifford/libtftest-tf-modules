# Lifecycle policy JSON content.
#
# Each creation template's lifecycle_policy is a jsonencode() embedding
# var.pre_release_retention_days and var.untagged_retention_days as
# selection.countNumber. Assert the encoded JSON contains the expected
# countNumber values for both defaults and a custom-tuned run.

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

run "default_retention" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  variables {
    pre_release_retention_days = 90
    untagged_retention_days    = 7
  }

  assert {
    condition     = strcontains(aws_ecr_repository_creation_template.helm_charts.lifecycle_policy, "\"countNumber\":90") && strcontains(aws_ecr_repository_creation_template.helm_charts.lifecycle_policy, "\"countNumber\":7")
    error_message = "helm_charts lifecycle_policy JSON must contain countNumber:90 and countNumber:7"
  }

  assert {
    condition     = strcontains(aws_ecr_repository_creation_template.tf_modules.lifecycle_policy, "\"countNumber\":90") && strcontains(aws_ecr_repository_creation_template.tf_modules.lifecycle_policy, "\"countNumber\":7")
    error_message = "tf_modules lifecycle_policy JSON must contain countNumber:90 and countNumber:7"
  }
}

run "custom_retention" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  variables {
    pre_release_retention_days = 30
    untagged_retention_days    = 14
  }

  assert {
    condition     = strcontains(aws_ecr_repository_creation_template.helm_charts.lifecycle_policy, "\"countNumber\":30") && strcontains(aws_ecr_repository_creation_template.helm_charts.lifecycle_policy, "\"countNumber\":14")
    error_message = "helm_charts lifecycle_policy JSON must contain customized countNumber:30 and countNumber:14"
  }

  assert {
    condition     = strcontains(aws_ecr_repository_creation_template.tf_modules.lifecycle_policy, "\"countNumber\":30") && strcontains(aws_ecr_repository_creation_template.tf_modules.lifecycle_policy, "\"countNumber\":14")
    error_message = "tf_modules lifecycle_policy JSON must contain customized countNumber:30 and countNumber:14"
  }
}
