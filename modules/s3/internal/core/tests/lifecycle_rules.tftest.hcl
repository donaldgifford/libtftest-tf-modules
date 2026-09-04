# Lifecycle rule surface (DESIGN-0022 core change 2 / IMPL-0021 1.4):
# the new transition rendering plus the F5 coverage-gap closures —
# noncurrent_version_expiration_days, enabled = false, and prefix all
# shipped in IMPL-0018 with zero test coverage (INV-0011 F5).
#
# rule[0] is always the baseline MPU-abort rule; caller rules append
# after it (pinned via lifecycle_rule_ids ordering). transition /
# noncurrent_version_transition are SET blocks, so assertions use the
# filtered-for-expression idiom, never indexing.

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

run "transitions_render" {
  command = plan

  variables {
    versioning_enabled = true
    extra_lifecycle_rules = [{
      id                                 = "tier-and-expire"
      noncurrent_version_expiration_days = 730
      transitions = [
        { days = 90, storage_class = "GLACIER_IR" },
        { days = 365, storage_class = "DEEP_ARCHIVE" },
      ]
      noncurrent_version_transitions = [
        { noncurrent_days = 30, storage_class = "STANDARD_IA" },
      ]
    }]
  }

  assert {
    condition     = join(",", output.lifecycle_rule_ids) == "abort-incomplete-multipart-upload,tier-and-expire"
    error_message = "caller rules must append after the baseline MPU-abort rule"
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.this.rule[1].transition) == 2
    error_message = "both current-version transitions must render"
  }

  assert {
    condition = length([
      for t in aws_s3_bucket_lifecycle_configuration.this.rule[1].transition :
      t if t.days == 90 && t.storage_class == "GLACIER_IR"
    ]) == 1
    error_message = "the 90-day GLACIER_IR transition must render as given"
  }

  assert {
    condition = length([
      for t in aws_s3_bucket_lifecycle_configuration.this.rule[1].transition :
      t if t.days == 365 && t.storage_class == "DEEP_ARCHIVE"
    ]) == 1
    error_message = "the 365-day DEEP_ARCHIVE transition must render as given"
  }

  assert {
    condition = length([
      for t in aws_s3_bucket_lifecycle_configuration.this.rule[1].noncurrent_version_transition :
      t if t.noncurrent_days == 30 && t.storage_class == "STANDARD_IA"
    ]) == 1
    error_message = "the noncurrent-version transition must render as given"
  }

  # F5 closure: noncurrent expiration was shipped untested. Riding the
  # same rule proves expiration and transitions compose.
  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.this.rule[1].noncurrent_version_expiration).noncurrent_days == 730
    error_message = "noncurrent_version_expiration_days must render (F5 gap closure)"
  }
}

# F5 closure: enabled = false renders Disabled — the rule stays in the
# configuration (removable by rule edit, not silently dropped).
run "disabled_rule_renders_disabled" {
  command = plan

  variables {
    extra_lifecycle_rules = [{
      id              = "paused-expiry"
      enabled         = false
      expiration_days = 30
    }]
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.this.rule[1].status == "Disabled"
    error_message = "enabled = false must render status Disabled (F5 gap closure)"
  }

  assert {
    condition     = join(",", output.lifecycle_rule_ids) == "abort-incomplete-multipart-upload,paused-expiry"
    error_message = "a disabled rule must still appear in lifecycle_rule_ids"
  }
}

# F5 closure: prefix scopes the rule; null prefix = whole bucket.
run "prefix_filter_renders" {
  command = plan

  variables {
    extra_lifecycle_rules = [{
      id              = "staging-expiry"
      prefix          = "staging/"
      expiration_days = 7
    }]
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.this.rule[1].filter).prefix == "staging/"
    error_message = "prefix must scope the caller rule's filter (F5 gap closure)"
  }

  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.this.rule[1].expiration).days == 7
    error_message = "expiration_days must render alongside the prefix filter"
  }
}
