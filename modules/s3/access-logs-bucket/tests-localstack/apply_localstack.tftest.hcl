# Apply against LocalStack — a real create of the access-logs sink.
#
# Community-safe (pure S3 API, no Pro tier / no token): the full
# resource chain — bucket, Public Access Block, ownership controls,
# SSE-S3 encryption, versioning, lifecycle, bucket policy — applies
# against the token-free `localstack/localstack:4.4` pin (OQ 5a,
# SERVICES=s3,sts). No fixture needed: the sink is a pure producer
# with no remote-state reads.
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

# Zero-configuration create: every default, the singleton shape.
run "apply_sink" {
  command = apply

  assert {
    condition     = output.bucket_name == "access-logs-000000000000-us-east-1"
    error_message = "applied sink must carry the composed default name"
  }

  assert {
    condition     = output.bucket_arn == "arn:aws:s3:::access-logs-000000000000-us-east-1"
    error_message = "applied ARN must match the composed name"
  }

  assert {
    condition = alltrue([
      output.security_baseline.block_public_acls,
      output.security_baseline.block_public_policy,
      output.security_baseline.ignore_public_acls,
      output.security_baseline.restrict_public_buckets,
    ])
    error_message = "Block Public Access must apply fully on"
  }

  assert {
    condition = alltrue([
      output.security_baseline.object_ownership == "BucketOwnerEnforced",
      output.security_baseline.sse_algorithm == "AES256",
      output.security_baseline.versioning_status == "Suspended",
      output.security_baseline.mpu_abort_days == 7,
      output.security_baseline.tls_deny_sids_present,
    ])
    error_message = "the applied baseline must hold end-to-end (ownership, SSE-S3, versioning off, MPU hygiene, TLS denies)"
  }

  assert {
    condition     = contains(output.lifecycle_rule_ids, "expire-access-logs")
    error_message = "the default 90-day retention rule must apply"
  }

  assert {
    condition     = contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], "AllowS3ServerAccessLogDelivery")
    error_message = "the log-delivery grant must be in the applied policy"
  }
}
