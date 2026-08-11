# Pointer-only output contract (IMPL-0019 1.5 / INV-0010 F7).
#
# Pins the consumer-facing half of the contract that is knowable at
# plan: the three var-passthrough outputs (kms_key_arn,
# secret_string_version, username) must echo their inputs faithfully —
# kms_key_arn's faithful NULL is what routes rds/proxy down its
# ViaService-fenced wildcard path. The three resource-derived outputs
# (secret_arn / secret_id / secret_name) are unknown at plan; their
# existence is enforced by terraform validate (they reference the
# resource), and their values are asserted in the apply suite.
#
# Real provider + fake creds — see default.tftest.hcl.

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

run "managed_key_reports_null" {
  command = plan

  assert {
    condition     = output.kms_key_arn == null
    error_message = "kms_key_arn output must be null on the managed-key default — rds/proxy branches on exactly this"
  }

  assert {
    condition     = output.username == null
    error_message = "username output must be null in bare-password mode"
  }

  assert {
    condition     = output.secret_string_version == 1
    error_message = "secret_string_version output must echo the version gate"
  }
}

run "byo_key_and_credentials_echo" {
  command = plan

  variables {
    username              = "app_admin"
    kms_key_arn           = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    secret_string_version = 3
  }

  assert {
    condition     = output.kms_key_arn == "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
    error_message = "kms_key_arn output must echo the BYO CMK ARN verbatim"
  }

  assert {
    condition     = output.username == "app_admin"
    error_message = "username output must echo the non-secret credential half"
  }

  assert {
    condition     = output.secret_string_version == 3
    error_message = "secret_string_version output must echo the bumped gate"
  }
}
