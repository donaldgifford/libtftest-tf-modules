# Naming: override + shard prefix (IMPL-0018 1.8 / INV-0009 OQ 7).
# With the shard prefix the composed name is unknown until apply
# (random_string), so that run asserts the generator's shape, not the
# final name.

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

run "name_override_verbatim" {
  command = plan

  variables {
    name_override = "externally-dictated-name"
  }

  assert {
    condition     = aws_s3_bucket.this.bucket == "externally-dictated-name"
    error_message = "name_override must be used verbatim (no composition)"
  }

  assert {
    condition     = length(random_string.shard_prefix) == 0
    error_message = "no shard-prefix generator unless shard_prefix_enabled"
  }
}

run "shard_prefix_generator" {
  command = plan

  variables {
    shard_prefix_enabled = true
  }

  assert {
    condition     = length(random_string.shard_prefix) == 1
    error_message = "shard_prefix_enabled must create exactly one generator"
  }

  assert {
    condition = alltrue([
      random_string.shard_prefix[0].length == 5,
      random_string.shard_prefix[0].lower,
      !random_string.shard_prefix[0].upper,
      !random_string.shard_prefix[0].special,
    ])
    error_message = "shard prefix must be 5 chars, lowercase alphanumeric only"
  }
}
