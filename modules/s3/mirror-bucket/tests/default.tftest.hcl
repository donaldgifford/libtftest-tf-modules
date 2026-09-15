# Default wiring pins (IMPL-0025 2.4): composed naming (both
# paths), mirror_url exact shape, the IA lifecycle rule's presence /
# absence via lifecycle_rule_ids, and the explicit-target logging
# wiring (on with prefix default, off with nulls). No remote-state
# read exists anywhere here — no override_data, no ADR-0020 key
# assertion (there is no key to pin).

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name                        = "mirror"
  vpc_endpoint_ids            = ["vpce-0123456789abcdef0"]
  policy_admin_principal_arns = ["arn:aws:iam::000000000000:role/admin"]
}

# Composed naming + mirror_url exact shape (trailing slash pinned —
# both missing-slash and double-slash break provider_installation
# parsing silently).
run "composed_name_and_mirror_url" {
  command = plan

  assert {
    condition     = output.bucket_name == "mirror-000000000000-us-east-1"
    error_message = "the composed name must be <name>-<account_id>-<region>"
  }

  assert {
    condition     = output.mirror_url == "https://mirror-000000000000-us-east-1.s3.us-east-1.amazonaws.com/"
    error_message = "mirror_url must be the REST endpoint with exactly one trailing slash"
  }
}

# Externally-dictated name via the override hatch.
run "name_override" {
  command = plan

  variables {
    name_override = "sluice-mirror-prod"
  }

  assert {
    condition = alltrue([
      output.bucket_name == "sluice-mirror-prod",
      output.mirror_url == "https://sluice-mirror-prod.s3.us-east-1.amazonaws.com/",
    ])
    error_message = "name_override must flow verbatim into both the bucket name and mirror_url"
  }
}

# IA lifecycle: one fixed-id rule after the baseline MPU-abort rule.
run "ia_lifecycle_enabled" {
  command = plan

  variables {
    noncurrent_version_ia_days = 30
  }

  assert {
    condition     = output.lifecycle_rule_ids == ["abort-incomplete-multipart-upload", "noncurrent-versions-to-ia"]
    error_message = "the IA rule must render second, after the baseline MPU-abort rule"
  }
}

# IA lifecycle: null disables — baseline rule only.
run "ia_lifecycle_disabled" {
  command = plan

  assert {
    condition     = output.lifecycle_rule_ids == ["abort-incomplete-multipart-upload"]
    error_message = "null noncurrent_version_ia_days must render no extra lifecycle rule"
  }
}

# Explicit logging target: wired verbatim.
run "logging_explicit_target" {
  command = plan

  variables {
    access_log_bucket = "access-logs-000000000000-us-east-1"
  }

  assert {
    condition = alltrue([
      output.logging_target == "access-logs-000000000000-us-east-1",
      output.logging_prefix == "mirror-000000000000-us-east-1/",
    ])
    error_message = "an explicit target must wire verbatim with the <composed-name>/ prefix default"
  }
}

# Explicit prefix passes through verbatim.
run "logging_explicit_prefix" {
  command = plan

  variables {
    access_log_bucket = "access-logs-000000000000-us-east-1"
    access_log_prefix = "mirror/"
  }

  assert {
    condition     = output.logging_prefix == "mirror/"
    error_message = "an explicit prefix must pass through verbatim"
  }
}

# Default (null target): no logging resource at all.
run "logging_disabled" {
  command = plan

  assert {
    condition     = output.logging_target == null && output.logging_prefix == null
    error_message = "the default null target must configure no logging at all"
  }
}
