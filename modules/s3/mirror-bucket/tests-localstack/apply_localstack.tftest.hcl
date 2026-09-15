# Apply against LocalStack — the explicit-target logging posture
# end to end, plus the pinned serving posture after a real apply.
#
# Community-safe (pure S3 + STS, token-free `localstack/localstack:4.4`).
# The fixture owns a PLAIN target bucket: the mirror module names its
# sink explicitly and performs no remote-state read, so there is no
# sink module to apply and no ADR-0020 key to seed (the s3/bucket
# fixture's composing-fixture shape does not apply here).
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
  name                        = "mirror"
  vpc_endpoint_ids            = ["vpce-0123456789abcdef0"]
  policy_admin_principal_arns = ["arn:aws:iam::000000000000:role/admin"]
  force_destroy               = true
}

# Top-level declarations so the setup run can thread the shared
# var-file globals into the fixture module.
variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

run "setup" {
  command = apply

  variables {
    account_id = var.account_id
    region     = var.region
  }

  module {
    source = "./tests-localstack/fixtures/target"
  }
}

# Full shape: explicit logging target, IA rule, conditional
# delete-deny (break-glass set), publisher allow.
run "apply_full_shape" {
  command = apply

  variables {
    access_log_bucket                      = run.setup.target_bucket_name
    noncurrent_version_ia_days             = 30
    break_glass_principal_arns             = ["arn:aws:iam::000000000000:role/break-glass"]
    cross_account_publisher_principal_arns = ["arn:aws:iam::111122223333:role/publisher"]
  }

  assert {
    condition = alltrue([
      output.logging_target == run.setup.target_bucket_name,
      output.logging_prefix == "mirror-000000000000-us-east-1/",
    ])
    error_message = "the explicit target must wire verbatim with the <composed-name>/ prefix default after a real apply"
  }

  assert {
    condition     = output.lifecycle_rule_ids == ["abort-incomplete-multipart-upload", "noncurrent-versions-to-ia"]
    error_message = "both lifecycle rules must exist after a real apply"
  }

  assert {
    condition = alltrue([
      for sid in ["DenyInsecureTransport", "DenyOldTls", "DenyOutsideVpce", "AllowMirrorReadFromVPCE", "DenyObjectDeletion", "DenyPolicyMutation", "AllowCrossAccountPublisherWrite"] :
      contains([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid], sid)
    ])
    error_message = "all seven statements must be stored on the applied bucket policy"
  }

  assert {
    condition = alltrue([
      output.security_baseline.sse_algorithm == "AES256",
      output.security_baseline.versioning_status == "Enabled",
      output.security_baseline.vpce_restricted,
      output.mirror_url == "https://mirror-000000000000-us-east-1.s3.us-east-1.amazonaws.com/",
    ])
    error_message = "the pinned serving posture (SSE-S3, versioning on, VPCE deny, mirror_url) must hold after a real apply"
  }
}

# Minimal shape: logging off, no IA rule, absolute delete-deny.
run "apply_minimal" {
  command = apply

  assert {
    condition     = output.logging_target == null && output.logging_prefix == null
    error_message = "the default null target must configure no logging on a real apply"
  }

  assert {
    condition     = output.lifecycle_rule_ids == ["abort-incomplete-multipart-upload"]
    error_message = "no IA rule may exist when noncurrent_version_ia_days is null"
  }

  assert {
    condition     = !can(one([for s in jsondecode(output.bucket_policy_json).Statement : s if s.Sid == "DenyObjectDeletion"]).Condition)
    error_message = "the stored delete-deny must be unconditional with an empty break-glass list"
  }
}
