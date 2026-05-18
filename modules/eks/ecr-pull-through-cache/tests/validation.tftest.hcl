# Variable validation negatives.
#
# Two negative runs use expect_failures on var.upstream_registries:
# (a) an unknown upstream name and (b) an empty list. Both must be
# rejected at plan time by the variable's validation blocks.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  region      = "us-east-1"
  name_prefix = "libtftest"
}

run "negative_bogus_upstream" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  variables {
    upstream_registries = ["bogus"]
  }

  expect_failures = [var.upstream_registries]
}

run "negative_empty" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
    }
  }

  variables {
    upstream_registries = []
  }

  expect_failures = [var.upstream_registries]
}
