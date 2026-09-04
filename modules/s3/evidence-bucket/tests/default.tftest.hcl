# Tri-state + contract pins, carried from the `bucket` fork parent
# (IMPL-0021 3.5): all three access-logging paths, the ADR-0020
# reserved-key assertion, and the additive policy merge — proving the
# fork keeps the full reference-consumer surface. retention rides the
# file-level variables (the module's one required input).
# account_name/account_id/region come from the shared var-file
# (sandbox / 000000000000 / us-east-1).

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
}

# Path 1 (default {}): the reserved-key lookup wires the fleet sink.
run "default_lookup" {
  command = plan

  override_data {
    target = data.terraform_remote_state.access_logs
    values = {
      outputs = {
        bucket_name = "access-logs-000000000000-us-east-1"
      }
    }
  }

  # ADR-0020: the composed key IS the contract — a template edit must
  # fail this suite loudly.
  assert {
    condition     = data.terraform_remote_state.access_logs[0].config.key == "sandbox/us-east-1/s3/access-logs/terraform.tfstate"
    error_message = "the reserved-key composition must match ADR-0020: <account_name>/<region>/s3/access-logs/terraform.tfstate (flat — no <name> segment)"
  }

  assert {
    condition     = output.logging_target == "access-logs-000000000000-us-east-1"
    error_message = "the default path must wire logging to the looked-up fleet sink"
  }

  assert {
    condition     = output.logging_prefix == "loki-archive-000000000000-us-east-1/"
    error_message = "a null prefix must resolve to \"<composed-name>/\" in the core"
  }

  assert {
    condition     = output.bucket_name == "loki-archive-000000000000-us-east-1"
    error_message = "the composed name must be <name>-<account_id>-<region>"
  }
}

# Path 2 (explicit target_bucket): no remote-state read is created.
run "explicit_override" {
  command = plan

  variables {
    access_logging = {
      target_bucket = "my-nondefault-sink"
    }
  }

  assert {
    condition     = length(data.terraform_remote_state.access_logs) == 0
    error_message = "an explicit target_bucket must not create the remote-state read"
  }

  assert {
    condition     = output.logging_target == "my-nondefault-sink"
    error_message = "the override path must wire logging to the explicit sink verbatim"
  }
}

# Path 3 (enabled = false): no read, no logging.
run "disabled" {
  command = plan

  variables {
    access_logging = {
      enabled = false
    }
  }

  assert {
    condition     = length(data.terraform_remote_state.access_logs) == 0
    error_message = "the disabled path must not create the remote-state read"
  }

  assert {
    condition     = output.logging_target == null && output.logging_prefix == null
    error_message = "the disabled path must configure no logging at all"
  }
}

# OQ 4b: operator statements append beside the intact baseline.
run "additional_statements_additive" {
  command = plan

  variables {
    access_logging = {
      enabled = false
    }
    additional_policy_statements = [{
      sid        = "AllowAuditReadOnly"
      principals = { AWS = ["arn:aws:iam::000000000000:role/audit-reader"] }
      actions    = ["s3:GetObject"]
    }]
  }

  assert {
    condition     = contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "AllowAuditReadOnly")
    error_message = "operator statements must render in the composed policy"
  }

  assert {
    condition = alltrue([
      contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "DenyInsecureTransport"),
      contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "DenyOldTls"),
    ])
    error_message = "the baseline denies must render beside operator statements (additive-only merge)"
  }

  assert {
    condition = toset(one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowAuditReadOnly"]).Resource) == toset([
      "arn:aws:s3:::loki-archive-000000000000-us-east-1",
      "arn:aws:s3:::loki-archive-000000000000-us-east-1/*",
    ])
    error_message = "operator statement resources must expand against this bucket's ARN (resource_suffixes contract)"
  }
}
