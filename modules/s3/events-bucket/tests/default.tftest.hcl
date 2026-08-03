# Tri-state + notification pins (IMPL-0018 4.2). The tri-state and
# ADR-0020 assertions mirror s3/bucket (same inherited surface); the
# notification runs are this module's own. account_name/account_id/
# region come from the shared var-file (sandbox / 000000000000 /
# us-east-1).

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name = "app-events"

  sqs_queues = [{
    id     = "object-created"
    arn    = "arn:aws:sqs:us-east-1:000000000000:app-events"
    events = ["s3:ObjectCreated:*"]
  }]
}

# Path 1 (default {}): the reserved-key lookup wires the fleet sink.
run "default_lookup" {
  command = plan

  override_data {
    target = data.terraform_remote_state.access_logs
    values = {
      outputs = {
        bucket_name = "access-logs-000000000000-us-east-1"
      }
    }
  }

  # ADR-0020: the composed key IS the contract.
  assert {
    condition     = data.terraform_remote_state.access_logs[0].config.key == "sandbox/us-east-1/s3/access-logs/terraform.tfstate"
    error_message = "the reserved-key composition must match ADR-0020: <account_name>/<region>/s3/access-logs/terraform.tfstate (flat — no <name> segment)"
  }

  assert {
    condition     = output.logging_target == "access-logs-000000000000-us-east-1"
    error_message = "the default path must wire logging to the looked-up fleet sink"
  }

  assert {
    condition     = output.logging_prefix == "app-events-000000000000-us-east-1/"
    error_message = "a null prefix must resolve to \"<composed-name>/\" in the core"
  }
}

# Path 2 (explicit target_bucket): no remote-state read is created.
run "explicit_override" {
  command = plan

  variables {
    access_logging = {
      target_bucket = "my-nondefault-sink"
    }
  }

  assert {
    condition     = length(data.terraform_remote_state.access_logs) == 0
    error_message = "an explicit target_bucket must not create the remote-state read"
  }

  assert {
    condition     = output.logging_target == "my-nondefault-sink"
    error_message = "the override path must wire logging to the explicit sink verbatim"
  }
}

# Path 3 (enabled = false): no read, no logging.
run "disabled" {
  command = plan

  variables {
    access_logging = {
      enabled = false
    }
  }

  assert {
    condition     = length(data.terraform_remote_state.access_logs) == 0
    error_message = "the disabled path must not create the remote-state read"
  }

  assert {
    condition     = output.logging_target == null && output.logging_prefix == null
    error_message = "the disabled path must configure no logging at all"
  }
}

#--------------------------------------------------------------
# Notification surface (DESIGN-0019 OQ 5a)
#--------------------------------------------------------------

run "sqs_destination" {
  command = plan

  variables {
    access_logging = {
      enabled = false
    }
  }

  assert {
    condition     = length(aws_s3_bucket_notification.this.queue) == 1
    error_message = "the SQS destination must register on the singleton notification resource"
  }

  assert {
    condition     = one(aws_s3_bucket_notification.this.queue).queue_arn == "arn:aws:sqs:us-east-1:000000000000:app-events"
    error_message = "the queue ARN must pass through verbatim"
  }

  assert {
    condition     = one(aws_s3_bucket_notification.this.queue).events == toset(["s3:ObjectCreated:*"])
    error_message = "the event-type list must pass through verbatim"
  }

  assert {
    condition     = length(aws_s3_bucket_notification.this.topic) == 0 && aws_s3_bucket_notification.this.eventbridge == false
    error_message = "unused destination kinds must stay empty/off"
  }
}

run "all_destination_kinds" {
  command = plan

  variables {
    access_logging = {
      enabled = false
    }
    sqs_queues = [
      {
        id            = "raw-uploads"
        arn           = "arn:aws:sqs:us-east-1:000000000000:raw"
        events        = ["s3:ObjectCreated:Put"]
        filter_prefix = "raw/"
        filter_suffix = ".json"
      },
      {
        id     = "deletions"
        arn    = "arn:aws:sqs:us-east-1:000000000000:deletions"
        events = ["s3:ObjectRemoved:*"]
      },
    ]
    sns_topics = [{
      id     = "fanout"
      arn    = "arn:aws:sns:us-east-1:000000000000:fanout"
      events = ["s3:ObjectCreated:*"]
    }]
    eventbridge_enabled = true
  }

  assert {
    condition     = length(aws_s3_bucket_notification.this.queue) == 2
    error_message = "both queue destinations must register on the one singleton resource"
  }

  assert {
    condition     = length(aws_s3_bucket_notification.this.topic) == 1
    error_message = "the topic destination must register alongside the queues"
  }

  assert {
    condition     = aws_s3_bucket_notification.this.eventbridge == true
    error_message = "EventBridge forwarding must be on when enabled"
  }

  # Filters are per-entry, not global.
  assert {
    condition = alltrue([
      one([for q in aws_s3_bucket_notification.this.queue : q if q.id == "raw-uploads"]).filter_prefix == "raw/",
      one([for q in aws_s3_bucket_notification.this.queue : q if q.id == "raw-uploads"]).filter_suffix == ".json",
      one([for q in aws_s3_bucket_notification.this.queue : q if q.id == "deletions"]).filter_prefix == null,
    ])
    error_message = "prefix/suffix filters must apply per destination entry, not globally"
  }
}

run "eventbridge_only" {
  command = plan

  variables {
    access_logging = {
      enabled = false
    }
    sqs_queues          = []
    eventbridge_enabled = true
  }

  assert {
    condition     = aws_s3_bucket_notification.this.eventbridge == true
    error_message = "EventBridge alone must satisfy the destination requirement"
  }

  assert {
    condition     = length(aws_s3_bucket_notification.this.queue) == 0 && length(aws_s3_bucket_notification.this.topic) == 0
    error_message = "no queue/topic entries should render on the EventBridge-only path"
  }
}
