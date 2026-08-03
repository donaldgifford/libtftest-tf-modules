# Destination + sink fixture for the events-bucket Community apply
# suite (IMPL-0018 4.3). Three jobs:
#
#   1. Fleet state bucket + the REAL access-logs-bucket module, with
#      its contract output seeded at the reserved ADR-0020 key (the
#      s3/bucket fixture pattern) so the tri-state's default path is
#      exercised for real.
#   2. An SQS queue AND its queue policy — the policy is deliberately
#      HERE and not in the module: destination resource policies are
#      owned by the destination stack. This is the shape a real
#      consumer must provide (Service principal s3.amazonaws.com,
#      conditioned on the source bucket ARN + account).
#   3. An SNS topic, for the mixed-destination run.

terraform {
  required_version = ">= 1.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}

variable "account_name" {
  description = "Terragrunt account name — the <account_name> prefix of the reserved sink state key."
  type        = string
}

variable "account_id" {
  description = "AWS account ID — composed into bucket names and the queue-policy condition."
  type        = string
}

variable "region" {
  description = "AWS region — composed into bucket names and the state key."
  type        = string
}

variable "remote_state_bucket" {
  description = "Name of the fleet state bucket this fixture creates and seeds."
  type        = string
}

variable "source_bucket_name" {
  description = "Composed name of the events bucket under test — the queue policy is scoped to its ARN (computed here rather than read back, to avoid a fixture/consumer cycle)."
  type        = string
}

#--------------------------------------------------------------
# State bucket + the real access-logs sink
#--------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket        = var.remote_state_bucket
  force_destroy = true
}

module "access_logs" {
  source = "../../../../access-logs-bucket"

  account_id    = var.account_id
  region        = var.region
  force_destroy = true
}

resource "aws_s3_object" "sink_state" {
  bucket       = aws_s3_bucket.state.id
  key          = "${var.account_name}/${var.region}/s3/access-logs/terraform.tfstate"
  content_type = "application/json"

  content = jsonencode({
    version           = 4
    terraform_version = "1.14.7"
    serial            = 1
    lineage           = "tftest-s3-access-logs-sink"
    outputs = {
      bucket_name = {
        value = module.access_logs.bucket_name
        type  = "string"
      }
    }
    resources = []
  })
}

#--------------------------------------------------------------
# Notification destinations (owned by the destination stack, not the
# events-bucket module)
#--------------------------------------------------------------

resource "aws_sqs_queue" "events" {
  name = "${var.source_bucket_name}-events"
}

# The grant S3 needs to deliver notifications. THIS is the shape a
# real consumer's queue stack must provide — the events-bucket module
# never writes it.
resource "aws_sqs_queue_policy" "events" {
  queue_url = aws_sqs_queue.events.id
  policy    = data.aws_iam_policy_document.queue.json
}

data "aws_iam_policy_document" "queue" {
  statement {
    sid    = "AllowS3BucketNotifications"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.events.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:s3:::${var.source_bucket_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_sns_topic" "events" {
  name = "${var.source_bucket_name}-events"
}

output "sink_bucket_name" {
  description = "The real sink's composed bucket name."
  value       = module.access_logs.bucket_name
}

output "queue_arn" {
  description = "ARN of the notification destination queue."
  value       = aws_sqs_queue.events.arn
}

output "queue_url" {
  description = "URL of the destination queue (for the F6 probe)."
  value       = aws_sqs_queue.events.id
}

output "topic_arn" {
  description = "ARN of the notification destination topic."
  value       = aws_sns_topic.events.arn
}
