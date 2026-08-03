# Default-shape pins (IMPL-0018 2.3): zero-configuration singleton
# naming (OQ 3a), the log-delivery grant (OQ 2a), and the retention
# wiring (OQ 1a). account_id/region come from the shared var-file.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

run "zero_configuration_defaults" {
  command = plan

  assert {
    condition     = output.bucket_name == "access-logs-000000000000-us-east-1"
    error_message = "with every default, the sink must compose access-logs-<account_id>-<region> (OQ 3a)"
  }

  assert {
    condition     = contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "AllowS3ServerAccessLogDelivery")
    error_message = "the log-delivery grant must render"
  }

  assert {
    condition     = one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowS3ServerAccessLogDelivery"]).Principal.Service == "logging.s3.amazonaws.com"
    error_message = "the grant principal must be the S3 log-delivery service"
  }

  assert {
    condition     = one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowS3ServerAccessLogDelivery"]).Resource == "arn:aws:s3:::access-logs-000000000000-us-east-1/*"
    error_message = "the grant must cover objects only (/*), never the bucket itself"
  }

  assert {
    condition     = one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "AllowS3ServerAccessLogDelivery"]).Condition.StringEquals["aws:SourceAccount"] == "000000000000"
    error_message = "the grant must be conditioned on aws:SourceAccount (OQ 2a — account-scoped, zero per-source edits)"
  }

  assert {
    condition     = contains(output.lifecycle_rule_ids, "expire-access-logs")
    error_message = "the default 90-day retention rule must be wired (OQ 1a)"
  }

  assert {
    condition = alltrue([
      contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "DenyInsecureTransport"),
      contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "DenyOldTls"),
    ])
    error_message = "the baseline TLS denies must render beside the grant (additive-only merge)"
  }
}

run "retention_disabled" {
  command = plan

  variables {
    log_retention_days = null
  }

  assert {
    condition     = !contains(output.lifecycle_rule_ids, "expire-access-logs")
    error_message = "log_retention_days = null must drop the expiration rule (retain forever)"
  }

  assert {
    condition     = contains(output.lifecycle_rule_ids, "abort-incomplete-multipart-upload")
    error_message = "the baseline MPU-abort hygiene rule must remain"
  }
}

run "non_default_sink_name" {
  command = plan

  variables {
    name = "audit-logs"
  }

  assert {
    condition     = output.bucket_name == "audit-logs-000000000000-us-east-1"
    error_message = "a non-default sink composes its own name — same module, another stack path (INV-0009 OQ 2)"
  }
}
