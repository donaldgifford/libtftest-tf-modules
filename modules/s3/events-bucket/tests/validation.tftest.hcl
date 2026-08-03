# Guardrails (IMPL-0018 4.2): the destination requirement plus the
# inherited tri-state / policy / naming guards.

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

# The defining guardrail: an events bucket with nowhere to send events.
run "no_destination_rejected" {
  command = plan

  variables {
    access_logging = {
      enabled = false
    }
    sqs_queues          = []
    sns_topics          = []
    eventbridge_enabled = false
  }

  expect_failures = [aws_s3_bucket_notification.this]
}

run "duplicate_queue_ids_rejected" {
  command = plan

  variables {
    access_logging = {
      enabled = false
    }
    sqs_queues = [
      {
        id     = "dupe"
        arn    = "arn:aws:sqs:us-east-1:000000000000:a"
        events = ["s3:ObjectCreated:*"]
      },
      {
        id     = "dupe"
        arn    = "arn:aws:sqs:us-east-1:000000000000:b"
        events = ["s3:ObjectRemoved:*"]
      },
    ]
  }

  expect_failures = [var.sqs_queues]
}

run "empty_event_list_rejected" {
  command = plan

  variables {
    access_logging = {
      enabled = false
    }
    sns_topics = [{
      id     = "no-events"
      arn    = "arn:aws:sns:us-east-1:000000000000:fanout"
      events = []
    }]
  }

  expect_failures = [var.sns_topics]
}

run "disabled_with_target_rejected" {
  command = plan

  variables {
    access_logging = {
      enabled       = false
      target_bucket = "some-sink"
    }
  }

  expect_failures = [var.access_logging]
}

run "reserved_sid_rejected" {
  command = plan

  variables {
    access_logging = {
      enabled = false
    }
    additional_policy_statements = [{
      sid     = "DenyOldTls"
      actions = ["s3:GetObject"]
    }]
  }

  expect_failures = [var.additional_policy_statements]
}

run "name_bad_charset_rejected" {
  command = plan

  variables {
    name = "App_Events"

    # A variable-validation failure does NOT short-circuit data-source
    # evaluation, so the default tri-state would still attempt a real
    # S3 read here.
    access_logging = {
      enabled = false
    }
  }

  expect_failures = [var.name]
}
