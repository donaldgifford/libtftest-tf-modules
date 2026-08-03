# Bucket notifications (DESIGN-0019 OQ 5a).
#
# aws_s3_bucket_notification is a PER-BUCKET SINGLETON — the AWS API
# replaces the whole notification configuration on every write, so two
# resources pointing at one bucket silently clobber each other. All
# destinations therefore live in this one resource, and it lives in
# the purpose module's root (not the core) so plan suites can assert
# the wiring directly.

resource "aws_s3_bucket_notification" "this" {
  bucket      = module.core.bucket_id
  eventbridge = var.eventbridge_enabled

  dynamic "queue" {
    for_each = var.sqs_queues

    content {
      id            = queue.value.id
      queue_arn     = queue.value.arn
      events        = queue.value.events
      filter_prefix = queue.value.filter_prefix
      filter_suffix = queue.value.filter_suffix
    }
  }

  dynamic "topic" {
    for_each = var.sns_topics

    content {
      id            = topic.value.id
      topic_arn     = topic.value.arn
      events        = topic.value.events
      filter_prefix = topic.value.filter_prefix
      filter_suffix = topic.value.filter_suffix
    }
  }

  lifecycle {
    # An events bucket with nowhere to send events is a
    # misconfiguration, not a valid intermediate state (DESIGN-0019).
    # Cross-variable, so it is a precondition rather than three
    # variable validations (house doctrine).
    precondition {
      condition     = length(var.sqs_queues) > 0 || length(var.sns_topics) > 0 || var.eventbridge_enabled
      error_message = "events-bucket requires at least one destination: a queue in sqs_queues, a topic in sns_topics, or eventbridge_enabled = true. Use modules/s3/bucket for a bucket that emits no events."
    }
  }
}
