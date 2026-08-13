# Default-shape plan-time invariants (IMPL-0019 1.5).
#
# REAL provider + fake creds, NOT mock_provider: Terraform's provider
# mocking rejects ephemeral resource types outright (even count-gated to
# zero) and no override_ephemeral exists — a mock_provider "aws" here
# would fail every run in the file (INV-0010 F3.1/F3.2). The ephemeral
# random_password opens LOCALLY, so these runs are fully offline.
#
# The no-leak gate lives here: a passing plan in which
# secret_string_wo == null (write-only values never enter plan) while
# its version gate stays visible. That assertion is the mechanical
# backstop for the module's ephemeral-reference invariant — do not
# remove it.

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

run "bare_password_shape" {
  command = plan

  # The no-leak gate (INV-0010 F3 probe assertion, baked in for good).
  assert {
    condition     = aws_secretsmanager_secret_version.this.secret_string_wo == null
    error_message = "write-only secret value leaked into the plan — the no-leak invariant is broken"
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this.secret_string_wo_version == var.secret_string_version
    error_message = "secret_string_wo_version must ride var.secret_string_version (the F4 version gate)"
  }

  assert {
    condition     = aws_secretsmanager_secret.this.name_prefix == "platform-db-master-"
    error_message = "physical secret name_prefix must be var.name + '-'"
  }

  assert {
    condition     = aws_secretsmanager_secret.this.kms_key_id == null
    error_message = "default must leave kms_key_id unset (AWS-managed aws/secretsmanager key)"
  }

  assert {
    condition     = aws_secretsmanager_secret.this.recovery_window_in_days == 30
    error_message = "default recovery window must be 30 days"
  }
}

run "db_credentials_shape" {
  command = plan

  variables {
    username = "app_admin"
  }

  # Same no-leak gate with the JSON content shape selected — the
  # composed jsonencode value must be exactly as absent from plan as
  # the bare string.
  assert {
    condition     = aws_secretsmanager_secret_version.this.secret_string_wo == null
    error_message = "write-only secret value leaked into the plan on the DB-credentials shape"
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this.secret_string_wo_version == 1
    error_message = "version gate must default to 1"
  }
}

run "byo_kms_and_tags" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    tags = {
      Environment = "test"
      ManagedBy   = "terraform"
    }
  }

  assert {
    condition     = aws_secretsmanager_secret.this.kms_key_id == "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    error_message = "BYO CMK must ride the resource kms_key_id"
  }

  assert {
    condition     = aws_secretsmanager_secret.this.tags["Environment"] == "test"
    error_message = "tags must pass through to the secret"
  }
}

run "version_bump_rides_the_gate" {
  command = plan

  variables {
    secret_string_version = 5
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this.secret_string_wo_version == 5
    error_message = "a bumped secret_string_version must reach secret_string_wo_version verbatim"
  }
}

run "teardown_window_zero_accepted" {
  command = plan

  variables {
    secret_recovery_window_days = 0
  }

  assert {
    condition     = aws_secretsmanager_secret.this.recovery_window_in_days == 0
    error_message = "recovery window 0 (immediate deletion — the test-teardown path) must be accepted"
  }
}
