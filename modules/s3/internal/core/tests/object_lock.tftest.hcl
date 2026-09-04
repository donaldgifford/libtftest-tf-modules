# Object Lock capability (DESIGN-0022 core change 1 / IMPL-0021 1.4).
#
# The default run is the load-bearing one: object_lock_enabled must
# plan as explicit false with zero config resources, because explicit
# false is identical to the pre-DESIGN-0022 absent argument — every
# existing bucket in the fleet replans zero-diff against this core
# (INV-0011 F4's no-op requirement). The rejection runs live in
# validation.tftest.hcl with the other guardrails.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name = "core-test"
}

run "default_is_noop" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this.object_lock_enabled == false
    error_message = "object_lock_enabled must plan false by default — explicit false is the provider's absent-argument equivalent, the existing-bucket zero-diff guarantee"
  }

  assert {
    condition     = length(aws_s3_bucket_object_lock_configuration.this) == 0
    error_message = "no object-lock configuration resource may exist by default"
  }

  assert {
    condition     = output.object_lock == null
    error_message = "the object_lock output must be null when no default retention is configured"
  }
}

run "lock_with_days" {
  command = plan

  variables {
    versioning_enabled = true
    object_lock = {
      enabled = true
      days    = 400
    }
  }

  assert {
    condition     = aws_s3_bucket.this.object_lock_enabled == true
    error_message = "object_lock.enabled must set the create-time bucket flag"
  }

  assert {
    condition     = length(aws_s3_bucket_object_lock_configuration.this) == 1
    error_message = "a set retention duration must render the config resource"
  }

  assert {
    condition     = one(one(aws_s3_bucket_object_lock_configuration.this[0].rule).default_retention).mode == "COMPLIANCE"
    error_message = "retention mode must default to COMPLIANCE (INV-0011 OQ 6a — the admins-cannot-shorten requirement)"
  }

  assert {
    condition     = one(one(aws_s3_bucket_object_lock_configuration.this[0].rule).default_retention).days == 400
    error_message = "default retention days must carry the caller's value"
  }

  # days/mode/years are Optional and NOT computed in the provider
  # schema, so the unset sibling is null (not unknown) at plan —
  # assertable, unlike the kms_master_key_id exception.
  assert {
    condition     = one(one(aws_s3_bucket_object_lock_configuration.this[0].rule).default_retention).years == null
    error_message = "years must stay null when days is the chosen duration"
  }

  assert {
    condition     = output.object_lock.mode == "COMPLIANCE" && output.object_lock.days == 400 && output.object_lock.years == null
    error_message = "the object_lock output must mirror the config resource attributes (the purpose modules' only window)"
  }
}

run "lock_with_years_governance" {
  command = plan

  variables {
    versioning_enabled = true
    object_lock = {
      enabled = true
      mode    = "GOVERNANCE"
      years   = 1
    }
  }

  assert {
    condition     = one(one(aws_s3_bucket_object_lock_configuration.this[0].rule).default_retention).mode == "GOVERNANCE"
    error_message = "GOVERNANCE must be selectable for lower-stakes tiers"
  }

  assert {
    condition     = one(one(aws_s3_bucket_object_lock_configuration.this[0].rule).default_retention).years == 1
    error_message = "default retention years must carry the caller's value"
  }

  assert {
    condition     = one(one(aws_s3_bucket_object_lock_configuration.this[0].rule).default_retention).days == null
    error_message = "days must stay null when years is the chosen duration"
  }

  assert {
    condition     = output.object_lock.years == 1 && output.object_lock.days == null
    error_message = "the object_lock output must carry the years-form retention"
  }
}

# Lock-enabled with no default retention is legal S3 (per-object
# retention only) — the config resource must count-gate away, and the
# output stays null: it reports the DEFAULT retention, not lock state.
run "lock_enabled_without_retention" {
  command = plan

  variables {
    versioning_enabled = true
    object_lock = {
      enabled = true
    }
  }

  assert {
    condition     = aws_s3_bucket.this.object_lock_enabled == true
    error_message = "the bucket flag must still be set with no default retention"
  }

  assert {
    condition     = length(aws_s3_bucket_object_lock_configuration.this) == 0
    error_message = "no config resource may render without a retention duration"
  }

  assert {
    condition     = output.object_lock == null
    error_message = "the object_lock output reports default retention, so it must be null here"
  }
}
