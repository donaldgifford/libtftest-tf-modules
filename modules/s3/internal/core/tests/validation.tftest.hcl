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
