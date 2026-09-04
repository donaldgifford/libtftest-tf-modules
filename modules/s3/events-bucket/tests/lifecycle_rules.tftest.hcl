# Lifecycle exposure (DESIGN-0022 Phase 2 / IMPL-0021 2.4): the typed
# lifecycle_rules surface passes through to the core's
# extra_lifecycle_rules. Rendering depth (transition blocks, filter,
# status) is the CORE suite's job — child-module resources aren't
# assertable here, so this suite proves the passthrough is
# type-faithful (a transitions-bearing rule plans clean) and pins rule
# ordering via the lifecycle_rule_ids window.
#
# access_logging is disabled in every run: lifecycle is orthogonal to
# the tri-state, and the default path would attempt a real
# remote-state read (the family's known expect_failures gotcha).

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

  access_logging = {
    enabled = false
  }

  # events-bucket only: satisfies its at-least-one-destination
  # precondition so this file stays identical across the pair.
  # terraform test ignores variables the module under test does not
  # declare (same as -var-file), so `bucket` is unaffected.
  eventbridge_enabled = true
}

run "lifecycle_passthrough" {
  command = plan

  variables {
    versioning_enabled = true
    lifecycle_rules = [
      {
        id                                 = "tier-and-expire"
        noncurrent_version_expiration_days = 730
        transitions = [
          { days = 90, storage_class = "GLACIER_IR" },
          { days = 365, storage_class = "DEEP_ARCHIVE" },
        ]
        noncurrent_version_transitions = [
          { noncurrent_days = 30, storage_class = "STANDARD_IA" },
        ]
      },
      {
        id              = "staging-expiry"
        prefix          = "staging/"
        expiration_days = 7
      },
    ]
  }

  assert {
    condition     = join(",", output.lifecycle_rule_ids) == "abort-incomplete-multipart-upload,tier-and-expire,staging-expiry"
    error_message = "caller rules must append after the baseline MPU-abort rule, in caller order"
  }
}

run "reserved_rule_id_rejected" {
  command = plan

  variables {
    lifecycle_rules = [{
      id              = "abort-incomplete-multipart-upload"
      expiration_days = 30
    }]
  }

  expect_failures = [var.lifecycle_rules]
}
