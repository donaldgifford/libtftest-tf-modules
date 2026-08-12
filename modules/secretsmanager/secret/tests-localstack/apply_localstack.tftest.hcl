# Apply against LocalStack — the producer end to end, metadata-only
# (IMPL-0019 3.1/3.2, DESIGN-0020 OQ 6a).
#
# Community-safe: Secrets Manager + STS are Community-tier, so this
# runs on the token-free `localstack/localstack:4.4` pin with
# SERVICES=secretsmanager,sts. No Pro, no auth token, no named volume.
#
# secret_recovery_window_days = 0 so `terraform test` teardown actually
# deletes the secret (the name would otherwise stay reserved for the
# recovery window).
#
# OQ 6a discipline: assertions are METADATA-ONLY. The versions-check
# fixture reads aws_secretsmanager_secret_versions (plural — never the
# singular value-bearing data source), so the secret value exists
# nowhere outside Secrets Manager, not even in this suite's transient
# state. The rotation runs (3.2, OQ 2a) prove the F4 version-gate
# mechanism live: bumping secret_string_version replaces the AWSCURRENT
# version id.
#
# Required env vars (the `just tf test-localstack` recipe wires these):
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    secretsmanager = "http://localhost:4566"
    sts            = "http://localhost:4566"
  }
}

variables {
  name                        = "platform-db-master"
  username                    = "app_admin"
  secret_recovery_window_days = 0
}

run "create" {
  command = apply

  assert {
    condition     = can(regex("^arn:aws:secretsmanager:us-east-1:[0-9]{12}:secret:platform-db-master-", output.secret_arn))
    error_message = "secret_arn must be a real Secrets Manager ARN embedding the name prefix"
  }

  assert {
    condition     = can(regex("^platform-db-master-", output.secret_name))
    error_message = "the physical secret name must start with var.name + '-' (name_prefix)"
  }

  assert {
    condition     = output.kms_key_arn == null
    error_message = "kms_key_arn output must be null on the managed-key path"
  }

  assert {
    condition     = output.username == "app_admin"
    error_message = "username output must echo the credential half"
  }
}

run "verify_current" {
  command = apply

  module {
    source = "./tests-localstack/fixtures/versions-check"
  }

  variables {
    secret_id = run.create.secret_arn
  }

  assert {
    condition     = output.current_version_id != ""
    error_message = "the write-only initial version must be staged AWSCURRENT"
  }
}

run "rotate" {
  command = apply

  variables {
    secret_string_version = 2
  }

  assert {
    condition     = output.secret_string_version == 2
    error_message = "the bumped version gate must echo through the output"
  }
}

run "verify_rotated" {
  command = apply

  module {
    source = "./tests-localstack/fixtures/versions-check"
  }

  variables {
    secret_id = run.create.secret_arn
  }

  assert {
    condition     = output.current_version_id != ""
    error_message = "rotation must leave an AWSCURRENT version staged"
  }

  # The live F4 proof: one version bump = one new password = a NEW
  # AWSCURRENT version id.
  assert {
    condition     = output.current_version_id != run.verify_current.current_version_id
    error_message = "bumping secret_string_version must mint a new secret version (the AWSCURRENT id did not change)"
  }
}
