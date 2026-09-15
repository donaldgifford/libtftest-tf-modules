# Security-baseline pin — the family's documented THIRD VARIANT
# (DESIGN-0028). This file is EXCLUDED from the byte-identical diff
# guard (bucket/events-bucket remain the guarded pair;
# access-logs-bucket is the AES256 variant, evidence-bucket the
# versioning variant). Divergence from the canonical suite, exactly:
#   1. sse_algorithm asserts "AES256" (not "aws:kms"),
#      bucket_key_enabled false, kms_key_arn null — the pinned
#      SSE-S3 serving posture (anonymous readers cannot decrypt
#      SSE-KMS).
#   2. versioning_status asserts "Enabled", not "Suspended" — the
#      pinned mirror posture (immutable release artifacts).
#   3. vpce_restricted asserts true — the mirror always wires
#      vpc_endpoint_ids into the core's DenyOutsideVpce (OQ 1a),
#      so the deny renders on every invocation.
#   4. No override_data block — this module performs no
#      remote-state read; logging defaults to null (off).
# Everything else asserts the same F2 baseline.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name                        = "baseline-test"
  vpc_endpoint_ids            = ["vpce-0123456789abcdef0"]
  policy_admin_principal_arns = ["arn:aws:iam::000000000000:role/admin"]
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
    error_message = "ownership must be BucketOwnerEnforced (ACLs disabled, fixed family baseline)"
  }

  assert {
    condition     = output.security_baseline.tls_deny_sids_present == true
    error_message = "both TLS deny statements must render (fixed family baseline)"
  }

  assert {
    condition     = output.security_baseline.versioning_status == "Enabled"
    error_message = "versioning must be pinned Enabled — mirror artifacts are immutable releases (variant divergence 2)"
  }

  assert {
    condition     = output.security_baseline.mpu_abort_days == 7
    error_message = "the MPU-abort hygiene rule must hold at the family default"
  }

  assert {
    condition     = output.security_baseline.vpce_restricted == true
    error_message = "DenyOutsideVpce must render on every invocation — vpc_endpoint_ids always wires through (variant divergence 3)"
  }

  assert {
    condition = alltrue([
      output.security_baseline.sse_algorithm == "AES256",
      output.security_baseline.kms_key_arn == null,
      output.security_baseline.bucket_key_enabled == false,
    ])
    error_message = "the mirror posture must be SSE-S3 (AES256, no CMK, no bucket key) — anonymous readers cannot decrypt SSE-KMS (variant divergence 1)"
  }
}
