# Lifecycle policy JSON content.
#
# The creation template's lifecycle_policy is a jsonencode() of an
# object embedding var.untagged_image_retention_days as
# selection.countNumber. Assert the encoded JSON contains the
# expected countNumber for both the default (7) and a custom (30)
# retention — a regression of the JSON encoding (e.g., dropping
# countNumber or renaming the field) would fail this test.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  region              = "us-east-1"
  name_prefix         = "libtftest"
  upstream_registries = ["ecr-public"]
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
    untagged_image_retention_days = 7
  }

  assert {
    condition     = strcontains(aws_ecr_repository_creation_template.pull_through.lifecycle_policy, "\"countNumber\":7")
    error_message = "Default retention (7) must be embedded as countNumber:7 in the lifecycle_policy JSON"
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
    untagged_image_retention_days = 30
  }

  assert {
    condition     = strcontains(aws_ecr_repository_creation_template.pull_through.lifecycle_policy, "\"countNumber\":30")
    error_message = "Custom retention (30) must be embedded as countNumber:30 in the lifecycle_policy JSON"
  }
}
