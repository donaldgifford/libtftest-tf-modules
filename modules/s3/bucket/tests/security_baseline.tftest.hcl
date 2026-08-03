# Security-baseline pin — the family's CANONICAL shared baseline suite
# (DESIGN-0019 / IMPL-0018 OQ 3a). This file and events-bucket's copy
# must stay byte-identical (the Phase-5 diff guard compares them);
# access-logs-bucket carries the documented F3 variant (AES256, no
# tri-state). The override_data stub satisfies the default tri-state's
# reserved-key lookup — plan tests read no real state.

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

  assert {
    condition     = output.security_baseline.versioning_status == "Suspended"
    error_message = "versioning must default off (INV-0009 F2 — explicit operator opt-in)"
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
