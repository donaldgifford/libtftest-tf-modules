#--------------------------------------------------------------
# Per-AIP CloudWatch token-count alarm
#
# Near-real-time tripwire that fires well ahead of the ~24h Cost
# Explorer billing lag (DESIGN-0009 §1, Q3). One alarm per AIP, scoped
# via the inference-profile-ARN dimension on the AWS/Bedrock namespace
# (Q4: finest-grained signal, matching the per-AIP cost-attribution
# story).
#
# The alarm watches InputTokenCount as the leading indicator of runaway
# usage — every invocation sends context, so an out-of-control agent
# loop spikes input tokens first and fastest. It is deliberately a
# single-metric, single-period (5 min), single-evaluation tripwire:
# earlier signal beats false-positive avoidance here, and the
# tag-filtered AWS Budget (budget.tf) remains the authoritative cost
# guardrail. If AWS does not expose InferenceProfileArn as a valid
# dimension for this metric, the alarm still ships; only the dimension
# scope degrades (Q4 follow-up).
#--------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "token_count" {
  for_each = aws_bedrock_inference_profile.this

  alarm_name          = "${aws_iam_user.this.name}-${each.key}-tokens"
  alarm_description   = "Per-5-minute input-token burn for Bedrock AIP ${each.key} exceeded ${var.token_alarm_threshold} tokens — near-real-time tripwire ahead of the ~24h Cost Explorer billing lag."
  namespace           = "AWS/Bedrock"
  metric_name         = "InputTokenCount"
  dimensions          = { InferenceProfileArn = each.value.arn }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.token_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  tags = merge(var.tags, local.cost_tag_map)
}
