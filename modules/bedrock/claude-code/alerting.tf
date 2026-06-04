#--------------------------------------------------------------
# Alerting fan-out — SNS topic + email (always) + optional Slack
#
# Budget threshold notifications (budget.tf) and per-AIP token alarms
# (cloudwatch.tf) both publish to this topic. Email subscriptions are
# always created (one per var.alert_emails entry); the Slack
# subscription is opt-in via var.slack_enabled and delivered per
# var.slack_delivery (DESIGN-0009 §1, Q6).
#--------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${aws_iam_user.this.name}-alerts"
  tags = merge(var.tags, local.cost_tag_map)
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# Slack delivery: 'chatbot' fronts an AWS Chatbot HTTPS endpoint (https
# protocol); 'lambda' points the subscription at a relay Lambda ARN
# (lambda protocol). The precondition enforces the cross-variable
# invariant that terraform 1.1 variable.validation cannot express
# (DESIGN-0009 Q10).
resource "aws_sns_topic_subscription" "slack" {
  count = var.slack_enabled ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = var.slack_delivery == "lambda" ? "lambda" : "https"
  endpoint  = var.slack_target

  lifecycle {
    precondition {
      condition     = !var.slack_enabled || var.slack_target != null
      error_message = "slack_target must be set (non-null) when slack_enabled = true. Provide an AWS Chatbot HTTPS endpoint URL (slack_delivery = 'chatbot') or a relay Lambda ARN (slack_delivery = 'lambda')."
    }
  }
}
