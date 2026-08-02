# Encryption modes (kms CMK / s3) + logging wiring (IMPL-0018 1.8).

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

run "cmk_override" {
  command = plan

  variables {
    encryption = {
      mode        = "kms"
      kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/test-cmk"
    }
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).kms_master_key_id == "arn:aws:kms:us-east-1:000000000000:key/test-cmk"
    error_message = "CMK override must flow into the SSE configuration"
  }

  assert {
    condition     = output.security_baseline.kms_key_arn == "arn:aws:kms:us-east-1:000000000000:key/test-cmk"
    error_message = "security_baseline.kms_key_arn must expose the CMK"
  }
}

run "sse_s3_mode" {
  command = plan

  variables {
    encryption = {
      mode = "s3"
    }
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "mode s3 must render AES256 (the access-logs sink's forced mode)"
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).bucket_key_enabled == false
    error_message = "bucket keys are SSE-KMS-only — must be off under AES256"
  }
}

run "logging_wired_default_prefix" {
  command = plan

  variables {
    logging = {
      target_bucket = "access-logs-000000000000-us-east-1"
    }
  }

  assert {
    condition     = length(aws_s3_bucket_logging.this) == 1
    error_message = "a resolved logging target must create the logging resource"
  }

  assert {
    condition     = aws_s3_bucket_logging.this[0].target_prefix == "core-test-000000000000-us-east-1/"
    error_message = "null prefix must default to '<composed name>/' (the sink self-organizes by source)"
  }

  assert {
    condition = alltrue([
      output.logging_target == "access-logs-000000000000-us-east-1",
      output.logging_prefix == "core-test-000000000000-us-east-1/",
    ])
    error_message = "logging outputs must expose the resolved wiring"
  }
}

run "logging_explicit_prefix" {
  command = plan

  variables {
    logging = {
      target_bucket = "access-logs-000000000000-us-east-1"
      prefix        = "custom/path/"
    }
  }

  assert {
    condition     = aws_s3_bucket_logging.this[0].target_prefix == "custom/path/"
    error_message = "an explicit prefix must be used verbatim"
  }
}

run "extra_lifecycle_rule" {
  command = plan

  variables {
    extra_lifecycle_rules = [{
      id              = "expire-logs"
      expiration_days = 90
    }]
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.this.rule) == 2
    error_message = "extra rules must append after the baseline MPU-abort rule"
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.this.rule[1].expiration).days == 90
    error_message = "the appended rule must carry its expiration"
  }
}
