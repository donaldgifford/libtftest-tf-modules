# Apply against LocalStack — notifications + the tri-state, for real.
#
# Community-safe (S3 + STS + SQS + SNS + EventBridge, token-free
# `localstack/localstack:4.4`, OQ 5a). The fixture stands up the fleet
# state bucket, the REAL access-logs sink seeded at the reserved
# ADR-0020 key, and the notification destinations *including the SQS
# queue policy* — which this module deliberately does not own.
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
    s3     = "http://localhost:4566"
    sts    = "http://localhost:4566"
    sqs    = "http://localhost:4566"
    sns    = "http://localhost:4566"
    events = "http://localhost:4566"
  }
}

variables {
  name          = "app-events"
  force_destroy = true
}

variable "account_name" {
  type = string
}

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "remote_state_bucket" {
  type = string
}

run "setup" {
  command = apply

  variables {
    account_name        = var.account_name
    account_id          = var.account_id
    region              = var.region
    remote_state_bucket = var.remote_state_bucket

    # The composed name the module under test will produce — the queue
    # policy must be scoped to it before the bucket exists.
    source_bucket_name = "app-events-${var.account_id}-${var.region}"
  }

  module {
    source = "./tests-localstack/fixtures/destinations"
  }
}

# SQS destination + the default access-logging tri-state.
run "apply_with_sqs" {
  command = apply

  variables {
    sqs_queues = [{
      id            = "object-created"
      arn           = run.setup.queue_arn
      events        = ["s3:ObjectCreated:*"]
      filter_prefix = "incoming/"
    }]
  }

  assert {
    condition     = output.notification_queue_arns["object-created"] == run.setup.queue_arn
    error_message = "the applied notification configuration must carry the real queue ARN"
  }

  assert {
    condition     = output.notification_id == output.bucket_name
    error_message = "the notification configuration is a per-bucket singleton keyed by the bucket"
  }

  assert {
    condition     = output.eventbridge_enabled == false
    error_message = "EventBridge must stay off unless asked for"
  }

  assert {
    condition     = output.logging_target == run.setup.sink_bucket_name
    error_message = "the default tri-state must resolve the sink through the reserved ADR-0020 key on a real apply"
  }

  assert {
    condition = alltrue([
      output.security_baseline.block_public_acls,
      output.security_baseline.block_public_policy,
      output.security_baseline.ignore_public_acls,
      output.security_baseline.restrict_public_buckets,
      output.security_baseline.object_ownership == "BucketOwnerEnforced",
      output.security_baseline.tls_deny_sids_present,
    ])
    error_message = "the F2 baseline must hold end-to-end after a real apply"
  }
}

# All three destination kinds at once, on the log-less path.
run "apply_with_all_destinations" {
  command = apply

  variables {
    access_logging = {
      enabled = false
    }
    sqs_queues = [{
      id     = "object-created"
      arn    = run.setup.queue_arn
      events = ["s3:ObjectCreated:*"]
    }]
    sns_topics = [{
      id     = "fanout"
      arn    = run.setup.topic_arn
      events = ["s3:ObjectRemoved:*"]
    }]
    eventbridge_enabled = true
  }

  assert {
    condition     = output.notification_topic_arns["fanout"] == run.setup.topic_arn
    error_message = "the SNS destination must apply alongside the queue on the one singleton resource"
  }

  assert {
    condition     = output.eventbridge_enabled == true
    error_message = "EventBridge forwarding must apply when enabled"
  }

  assert {
    condition     = output.logging_target == null
    error_message = "the disabled tri-state must configure no logging on a real apply"
  }
}
