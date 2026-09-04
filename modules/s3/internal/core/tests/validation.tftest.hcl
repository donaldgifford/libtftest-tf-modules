# Guardrails: every validation + precondition fails closed
# (IMPL-0018 1.8). Precondition failures are expected against the
# carrying resource; variable validations against the variable.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  secret_key                  = "test"
}

variables {
  name = "core-test"
}

run "name_bad_charset" {
  command = plan

  variables {
    name = "Bad_Name"
  }

  expect_failures = [var.name]
}

run "name_too_short" {
  command = plan

  variables {
    name = "ab"
  }

  expect_failures = [var.name]
}

run "override_exceeds_63_chars" {
  command = plan

  variables {
    name_override = "this-override-is-way-too-long-to-be-a-valid-s3-bucket-name-because-it-exceeds-sixty-three"
  }

  expect_failures = [aws_s3_bucket.this]
}

run "override_bad_charset" {
  command = plan

  variables {
    name_override = "Has_Underscores_And_Caps"
  }

  expect_failures = [aws_s3_bucket.this]
}

run "invalid_encryption_mode" {
  command = plan

  variables {
    encryption = {
      mode = "sse"
    }
  }

  expect_failures = [var.encryption]
}

run "kms_key_on_s3_mode" {
  command = plan

  variables {
    encryption = {
      mode        = "s3"
      kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/test-cmk"
    }
  }

  expect_failures = [aws_s3_bucket_server_side_encryption_configuration.this]
}

run "reserved_sid_rejected" {
  command = plan

  variables {
    internal_policy_statements = [{
      sid     = "DenyOldTls"
      actions = ["s3:GetObject"]
    }]
  }

  expect_failures = [var.internal_policy_statements]
}

run "non_alphanumeric_sid_rejected" {
  command = plan

  variables {
    internal_policy_statements = [{
      sid     = "bad-sid"
      actions = ["s3:GetObject"]
    }]
  }

  expect_failures = [var.internal_policy_statements]
}

run "self_logging_rejected" {
  command = plan

  variables {
    logging = {
      target_bucket = "core-test-000000000000-us-east-1"
    }
  }

  expect_failures = [aws_s3_bucket_logging.this]
}

# --- Object lock guardrails (DESIGN-0022 / IMPL-0021 1.4) ---
# Each run is constructed so exactly ONE rule can fire (verified
# per-rule, IMPL-0021 task 1.5): a passing expect_failures run proves
# only that the object errored, not which rule caught it.

run "object_lock_bad_mode" {
  command = plan

  variables {
    versioning_enabled = true
    object_lock = {
      enabled = true
      mode    = "LEGAL_HOLD"
      days    = 1
    }
  }

  expect_failures = [var.object_lock]
}

run "object_lock_days_and_years" {
  command = plan

  variables {
    versioning_enabled = true
    object_lock = {
      enabled = true
      days    = 1
      years   = 1
    }
  }

  expect_failures = [var.object_lock]
}

# The coherence guard (IMPL-0020's silent-widening lesson, inverted):
# { days = 400 } — "retain 400 days" with enabled forgotten — must
# fail, not silently configure nothing.
run "object_lock_retention_without_enabled" {
  command = plan

  variables {
    object_lock = {
      days = 400
    }
  }

  expect_failures = [var.object_lock]
}

run "object_lock_without_versioning" {
  command = plan

  variables {
    object_lock = {
      enabled = true
      days    = 1
    }
  }

  expect_failures = [aws_s3_bucket_versioning.this]
}

run "bad_transition_storage_class" {
  command = plan

  variables {
    extra_lifecycle_rules = [{
      id = "bad-tier"
      transitions = [
        { days = 90, storage_class = "GLACIER_FLEX" },
      ]
    }]
  }

  expect_failures = [var.extra_lifecycle_rules]
}
