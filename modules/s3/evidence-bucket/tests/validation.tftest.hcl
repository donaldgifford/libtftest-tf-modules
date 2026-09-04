# Guardrails (IMPL-0021 3.5): the evidence retention rules plus the
# guards carried from the `bucket` fork parent (tri-state
# contradictions, reserved sid, reserved rule id, naming bounds).
# Every run is constructed so exactly ONE rule can fire (per-rule
# verification, task 3.5): a passing expect_failures run proves only
# that the object errored, not which rule caught it.
#
# retention rides the file-level variables; access_logging is
# disabled in every run (a variable-validation failure does NOT
# short-circuit data-source evaluation — the default tri-state would
# attempt a real S3 read).

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name = "loki-archive"

  retention = {
    days = 400
  }

  access_logging = {
    enabled = false
  }
}

# --- The evidence retention rules ---

# OQ 1a: the duration is REQUIRED — an empty retention object (mode
# alone defaults fine) must fail, not silently under-configure.
run "retention_missing_duration_rejected" {
  command = plan

  variables {
    retention = {}
  }

  expect_failures = [var.retention]
}

run "retention_both_durations_rejected" {
  command = plan

  variables {
    retention = {
      days  = 400
      years = 1
    }
  }

  expect_failures = [var.retention]
}

run "retention_bad_mode_rejected" {
  command = plan

  variables {
    retention = {
      mode = "LEGAL_HOLD"
      days = 400
    }
  }

  expect_failures = [var.retention]
}

# --- Carried from the fork parent ---

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

run "reserved_sid_rejected" {
  command = plan

  variables {
    additional_policy_statements = [{
      sid     = "DenyInsecureTransport"
      actions = ["s3:GetObject"]
    }]
  }

  expect_failures = [var.additional_policy_statements]
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

run "name_bad_charset_rejected" {
  command = plan

  variables {
    name = "Loki_Archive"
  }

  expect_failures = [var.name]
}
