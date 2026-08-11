# Variable-validation rejections (IMPL-0019 1.5).
#
# Real provider + fake creds — see default.tftest.hcl for why
# mock_provider is structurally impossible in this module. All runs are
# offline: the only ephemeral here is the local random_password, and a
# variable-validation failure is asserted via expect_failures.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name = "platform-db-master"
}

run "name_bad_charset_rejected" {
  command = plan

  variables {
    name = "Bad_Name"
  }

  expect_failures = [var.name]
}

run "name_too_short_rejected" {
  command = plan

  variables {
    name = "ab"
  }

  expect_failures = [var.name]
}

run "recovery_window_in_dead_zone_rejected" {
  command = plan

  variables {
    secret_recovery_window_days = 3
  }

  expect_failures = [var.secret_recovery_window_days]
}

run "version_zero_rejected" {
  command = plan

  variables {
    secret_string_version = 0
  }

  expect_failures = [var.secret_string_version]
}

run "version_fractional_rejected" {
  command = plan

  variables {
    secret_string_version = 1.5
  }

  expect_failures = [var.secret_string_version]
}

run "short_password_rejected" {
  command = plan

  variables {
    password_length = 8
  }

  expect_failures = [var.password_length]
}

run "username_bad_shape_rejected" {
  command = plan

  variables {
    username = "1starts_with_digit"
  }

  expect_failures = [var.username]
}

run "kms_non_arn_rejected" {
  command = plan

  variables {
    kms_key_arn = "not-an-arn"
  }

  expect_failures = [var.kms_key_arn]
}
