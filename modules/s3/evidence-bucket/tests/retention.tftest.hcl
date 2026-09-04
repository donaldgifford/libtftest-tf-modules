# Retention wiring + the evidence-only object_lock output contract
# (DESIGN-0022 OQ 7a / IMPL-0021 3.5). The output is the purpose
# module's only window on the core's config resource (child-module
# resources aren't assertable), and it is never null here — the
# duration is required, so the config resource always renders.
#
# access_logging is disabled in every run: retention is orthogonal to
# the tri-state (default.tftest.hcl owns those paths), and the default
# path would attempt a real remote-state read.

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

  access_logging = {
    enabled = false
  }
}

run "compliance_days_default" {
  command = plan

  variables {
    retention = {
      days = 400
    }
  }

  assert {
    condition     = output.object_lock.mode == "COMPLIANCE"
    error_message = "retention.mode must default to COMPLIANCE (INV-0011 OQ 6a — the admins-cannot-shorten requirement)"
  }

  assert {
    condition     = output.object_lock.days == 400 && output.object_lock.years == null
    error_message = "the days-form retention must reach the config resource as given"
  }

  # The pinned posture, visible through the baseline window: an
  # evidence bucket is born versioned (Object Lock requires it).
  assert {
    condition     = output.security_baseline.versioning_status == "Enabled"
    error_message = "versioning must be pinned Enabled with no variable to flip"
  }
}

run "governance_years_override" {
  command = plan

  variables {
    retention = {
      mode  = "GOVERNANCE"
      years = 1
    }
  }

  assert {
    condition     = output.object_lock.mode == "GOVERNANCE"
    error_message = "GOVERNANCE must be selectable for lower-stakes tiers"
  }

  assert {
    condition     = output.object_lock.years == 1 && output.object_lock.days == null
    error_message = "the years-form retention must reach the config resource as given"
  }
}

# OQ 2a: the full lifecycle surface rides the evidence bucket —
# tiering locked evidence to Glacier is the cost story for long
# retention (expiration of locked versions defers until retention
# passes; transitions are unaffected by lock status).
run "lifecycle_passthrough" {
  command = plan

  variables {
    retention = {
      days = 400
    }
    lifecycle_rules = [{
      id                                 = "tier-and-expire"
      noncurrent_version_expiration_days = 730
      transitions = [
        { days = 90, storage_class = "GLACIER_IR" },
      ]
    }]
  }

  assert {
    condition     = join(",", output.lifecycle_rule_ids) == "abort-incomplete-multipart-upload,tier-and-expire"
    error_message = "caller rules must append after the baseline MPU-abort rule"
  }

  assert {
    condition     = output.object_lock.days == 400
    error_message = "lifecycle rules and lock retention must compose"
  }
}
