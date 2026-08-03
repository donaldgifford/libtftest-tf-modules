# Apply against LocalStack — the tri-state's default path end to end.
#
# Community-safe (pure S3 + STS, token-free `localstack/localstack:4.4`,
# OQ 5a). The fixture creates the fleet state bucket, applies the REAL
# access-logs-bucket module, and seeds its contract output at the
# reserved ADR-0020 key; this module then reads that key back through
# the account-scoped + assume_role path (IMPL-0015 — LocalStack's STS
# mints credentials for any role ARN, and the global AWS_ENDPOINT_URL
# routes both STS and S3) and wires logging to whatever the sink
# actually produced.
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
  s3_use_path_style           = true

  endpoints {
    s3  = "http://localhost:4566"
    sts = "http://localhost:4566"
  }
}

variables {
  name          = "app-data"
  force_destroy = true
}

# Top-level declarations so the setup run can thread the shared
# var-file globals into the fixture module.
variable "account_name" {
  type = string
}

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "remote_state_bucket" {
  type = string
}

run "setup" {
  command = apply

  variables {
    account_name        = var.account_name
    account_id          = var.account_id
    region              = var.region
    remote_state_bucket = var.remote_state_bucket
  }

  module {
    source = "./tests-localstack/fixtures/access-logs"
  }
}

# Default tri-state: resolve the sink through the reserved-key read.
run "apply_with_looked_up_sink" {
  command = apply

  assert {
    condition     = output.logging_target == run.setup.sink_bucket_name
    error_message = "the default path must log to the sink the fixture actually created (read back through the reserved ADR-0020 key)"
  }

  assert {
    condition     = output.logging_prefix == "app-data-000000000000-us-east-1/"
    error_message = "a null prefix must resolve to \"<composed-name>/\" after apply"
  }

  assert {
    condition = alltrue([
      output.security_baseline.block_public_acls,
      output.security_baseline.block_public_policy,
      output.security_baseline.ignore_public_acls,
      output.security_baseline.restrict_public_buckets,
      output.security_baseline.object_ownership == "BucketOwnerEnforced",
      output.security_baseline.versioning_status == "Suspended",
      output.security_baseline.mpu_abort_days == 7,
      output.security_baseline.tls_deny_sids_present,
    ])
    error_message = "the F2 baseline must hold end-to-end after a real apply"
  }
}

# Explicit override: no remote-state read, logging still wired.
run "apply_with_explicit_target" {
  command = apply

  variables {
    access_logging = {
      target_bucket = run.setup.sink_bucket_name
      prefix        = "explicit/"
    }
  }

  assert {
    condition     = length(data.terraform_remote_state.access_logs) == 0
    error_message = "the override path must skip the remote-state read on a real apply too"
  }

  assert {
    condition     = output.logging_prefix == "explicit/"
    error_message = "an explicit prefix must pass through verbatim"
  }
}
