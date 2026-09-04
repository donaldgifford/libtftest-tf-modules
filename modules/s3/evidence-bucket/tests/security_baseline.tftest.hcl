# Security-baseline pin — the family's documented VERSIONING VARIANT
# (DESIGN-0022 OQ 7a). This file is EXCLUDED from the byte-identical
# diff guard (bucket/events-bucket remain the guarded pair;
# access-logs-bucket is the F3 AES256 variant). Divergence from the
# canonical suite, exactly:
#   1. variables carry `retention` — the evidence module's one
#      required input (no default duration, OQ 1a).
#   2. versioning_status asserts "Enabled", not "Suspended" — the
#      pinned evidence posture (Object Lock requires versioning).
# Everything else asserts the same F2 baseline. Lock facts are NOT
# asserted here — they ride the evidence-only object_lock output
# (retention.tftest.hcl), keeping the shared baseline shape untouched.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name = "baseline-test"

  retention = {
    days = 1
  }
}

run "baseline_pin" {
  command = plan

  override_data {
    target = data.terraform_remote_state.access_logs
    values = {
      outputs = {
        bucket_name = "access-logs-000000000000-us-east-1"
      }
    }
  }

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

  # THE variant assertion: the pinned evidence posture.
  assert {
    condition     = output.security_baseline.versioning_status == "Enabled"
    error_message = "versioning must be pinned Enabled — Object Lock requires it (the documented variant divergence, DESIGN-0022 OQ 7a)"
  }

  assert {
    condition     = output.security_baseline.mpu_abort_days == 7
    error_message = "the MPU-abort hygiene rule must hold at the family default"
  }

  assert {
    condition     = output.security_baseline.vpce_restricted == false
    error_message = "no VPCE restriction by default"
  }

  assert {
    condition = alltrue([
      output.security_baseline.sse_algorithm == "aws:kms",
      output.security_baseline.kms_key_arn == null,
      output.security_baseline.bucket_key_enabled == true,
    ])
    error_message = "the F2 default must be SSE-KMS with the AWS-managed key + bucket key on"
  }
}
