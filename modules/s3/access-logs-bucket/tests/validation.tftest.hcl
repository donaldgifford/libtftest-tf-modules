# Guardrails (IMPL-0018 2.3).

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

run "retention_below_one_rejected" {
  command = plan

  variables {
    log_retention_days = 0
  }

  expect_failures = [var.log_retention_days]
}

run "name_bad_charset_rejected" {
  command = plan

  variables {
    name = "Access_Logs"
  }

  expect_failures = [var.name]
}
