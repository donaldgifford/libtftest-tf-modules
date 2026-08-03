# Guardrails (IMPL-0018 3.3): tri-state contradictions + the
# root-level reserved-sid mirror + naming bounds.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name = "app-data"
}

run "disabled_with_target_rejected" {
  command = plan

  variables {
    access_logging = {
      enabled       = false
      target_bucket = "some-sink"
    }
  }

  expect_failures = [var.access_logging]
}

run "disabled_with_prefix_rejected" {
  command = plan

  variables {
    access_logging = {
      enabled = false
      prefix  = "logs/"
    }
  }

  expect_failures = [var.access_logging]
}

run "reserved_sid_rejected" {
  command = plan

  variables {
    access_logging = {
      enabled = false
    }
    additional_policy_statements = [{
      sid     = "DenyInsecureTransport"
      actions = ["s3:GetObject"]
    }]
  }

  expect_failures = [var.additional_policy_statements]
}

run "name_bad_charset_rejected" {
  command = plan

  variables {
    name = "App_Data"

    # A variable-validation failure does NOT short-circuit data-source
    # evaluation, so the default tri-state would still attempt a real
    # S3 read here (no override_data on an expect_failures run).
    access_logging = {
      enabled = false
    }
  }

  expect_failures = [var.name]
}
