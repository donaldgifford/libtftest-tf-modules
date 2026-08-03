# Core baseline defaults (IMPL-0018 1.8 / DESIGN-0019 F2). The core is
# the root module here, so its resources are directly assertable — this
# is the family's deep baseline pin; the purpose modules can only see
# the re-exported security_baseline output. account_id/region come from
# the shared var-file (account_id 000000000000, region us-east-1).

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

run "baseline_defaults" {
  command = plan

  assert {
    condition     = aws_s3_bucket.this.bucket == "core-test-000000000000-us-east-1"
    error_message = "default composed name must be <name>-<account_id>-<region>"
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "all four Block Public Access flags must be on (fixed baseline)"
  }

  assert {
    condition     = one(aws_s3_bucket_ownership_controls.this.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "ownership must be BucketOwnerEnforced (fixed baseline — ACLs disabled)"
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.this.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "default encryption must be SSE-KMS"
  }

  # NB: no resource-attribute null assert for kms_master_key_id — the
  # attribute is Optional+Computed (unknown at plan when unset); the
  # aws/s3-managed-key default is pinned via security_baseline below.

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule).bucket_key_enabled == true
    error_message = "bucket key must be enabled with SSE-KMS (KMS request-cost control)"
  }

  assert {
    condition     = one(aws_s3_bucket_versioning.this.versioning_configuration).status == "Suspended"
    error_message = "versioning must default off (Suspended) — INV-0009 F2 operator decision"
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.this.rule[0].abort_incomplete_multipart_upload).days_after_initiation == 7
    error_message = "baseline MPU-abort hygiene rule must default to 7 days"
  }

  assert {
    condition     = aws_s3_bucket.this.force_destroy == false
    error_message = "force_destroy must default off (data loss is opt-in)"
  }

  assert {
    condition = alltrue([
      contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyInsecureTransport"),
      contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyOldTls"),
    ])
    error_message = "both fixed TLS deny statements must always render"
  }

  assert {
    condition     = !contains([for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid], "DenyOutsideVpce")
    error_message = "the VPCE-only deny must not render by default (opt-in)"
  }

  assert {
    condition     = length(aws_s3_bucket_logging.this) == 0
    error_message = "no logging resource when logging is null (disabled path)"
  }

  assert {
    condition = alltrue([
      output.security_baseline.block_public_acls,
      output.security_baseline.tls_deny_sids_present,
      output.security_baseline.sse_algorithm == "aws:kms",
      output.security_baseline.kms_key_arn == null,
      output.security_baseline.bucket_key_enabled == true,
      output.security_baseline.object_ownership == "BucketOwnerEnforced",
      output.security_baseline.versioning_status == "Suspended",
      output.security_baseline.mpu_abort_days == 7,
      output.security_baseline.vpce_restricted == false,
    ])
    error_message = "security_baseline output must mirror the composed baseline (the purpose modules' only test window)"
  }

  assert {
    condition     = output.logging_target == null && output.logging_prefix == null
    error_message = "logging outputs must be null when logging is off"
  }
}
