# Apply against LocalStack — probe A of the F6 discipline
# (DESIGN-0022 / IMPL-0021 4.1): does token-free Community 4.4 accept
# object_lock_enabled at create + PutObjectLockConfiguration? A green
# apply here IS the answer — if either call is rejected, the apply
# errors. Probe B (does 4.4 ENFORCE retention — deny a version delete
# before expiry?) cannot ride this suite: it needs an object written
# and a delete attempted, and this apply deliberately writes NO
# objects — an empty locked bucket deletes cleanly, so teardown never
# fights COMPLIANCE mode. Probe B runs as a recorded CLI probe; both
# outcomes live in FINDINGS.md.
#
# Community-safe (pure S3 + STS). Standalone on purpose: logging is
# disabled, so no remote-state read, no fixture, no setup run — the
# tri-state's live proof is the `bucket` module's apply; the plan
# suite pins this module's key composition.
#
# Required env vars (the `just tf test-localstack` recipe wires these):
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    s3  = "http://localhost:4566"
    sts = "http://localhost:4566"
  }
}

variables {
  name          = "loki-archive"
  force_destroy = true

  # Retention stays 1 day: even if the emulator enforces COMPLIANCE
  # semantics on the bucket itself, nothing locked exists (no objects)
  # and the shortest legal window bounds any surprise.
  retention = {
    days = 1
  }

  access_logging = {
    enabled = false
  }
}

run "apply_locked_bucket" {
  command = apply

  # Probe A, asserted: the config surface round-trips — the applied
  # default retention comes back attribute-derived from the config
  # resource the emulator accepted.
  assert {
    condition     = output.object_lock.mode == "COMPLIANCE" && output.object_lock.days == 1 && output.object_lock.years == null
    error_message = "the applied default retention must round-trip through the object-lock configuration resource (probe A)"
  }

  assert {
    condition     = output.security_baseline.versioning_status == "Enabled"
    error_message = "the pinned versioning must hold after a real apply (Object Lock requires it)"
  }

  assert {
    condition = alltrue([
      output.security_baseline.block_public_acls,
      output.security_baseline.block_public_policy,
      output.security_baseline.ignore_public_acls,
      output.security_baseline.restrict_public_buckets,
      output.security_baseline.object_ownership == "BucketOwnerEnforced",
      output.security_baseline.mpu_abort_days == 7,
      output.security_baseline.tls_deny_sids_present,
    ])
    error_message = "the F2 baseline must hold end-to-end on a locked bucket"
  }

  assert {
    condition     = output.logging_target == null
    error_message = "the disabled tri-state path must configure no logging live"
  }
}
