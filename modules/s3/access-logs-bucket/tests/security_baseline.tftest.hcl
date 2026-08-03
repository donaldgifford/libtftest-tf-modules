# Security-baseline pin — the F3 VARIANT of the family's shared
# baseline suite (DESIGN-0019 / IMPL-0018 OQ 3a): the access-logs sink
# deliberately diverges on encryption (SSE-S3/AES256 — log delivery
# does not write to KMS targets) and has no tri-state surface, so this
# file is NOT byte-identical to the bucket/events-bucket pair (which
# the Phase-5 diff guard compares). Everything else pins the same
# composed baseline through the re-exported security_baseline output.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

run "baseline_pin" {
  command = plan

  assert {
    condition = alltrue([
      output.security_baseline.block_public_acls,
      output.security_baseline.block_public_policy,
      output.security_baseline.ignore_public_acls,
      output.security_baseline.restrict_public_buckets,
    ])
    error_message = "Block Public Access must be fully on (fixed family baseline)"
  }

  assert {
    condition     = output.security_baseline.object_ownership == "BucketOwnerEnforced"
    error_message = "ownership must be BucketOwnerEnforced (the delivery grant is policy-based, not ACL-based)"
  }

  assert {
    condition     = output.security_baseline.tls_deny_sids_present == true
    error_message = "both TLS deny statements must render (fixed family baseline)"
  }

  assert {
    condition     = output.security_baseline.versioning_status == "Suspended"
    error_message = "versioning must be off (F3: log objects are append-only noise to version)"
  }

  assert {
    condition     = output.security_baseline.mpu_abort_days == 7
    error_message = "the MPU-abort hygiene rule must hold at the family default"
  }

  assert {
    condition     = output.security_baseline.vpce_restricted == false
    error_message = "no VPCE restriction by default"
  }

  # F3 divergence from the bucket/events baseline: AES256, no KMS.
  assert {
    condition = alltrue([
      output.security_baseline.sse_algorithm == "AES256",
      output.security_baseline.kms_key_arn == null,
      output.security_baseline.bucket_key_enabled == false,
    ])
    error_message = "the sink must pin SSE-S3 (F3: S3 log delivery does not write to SSE-KMS targets)"
  }
}
