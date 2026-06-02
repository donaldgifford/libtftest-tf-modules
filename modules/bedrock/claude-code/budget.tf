#--------------------------------------------------------------
# AWS Budget — scoped to the cost-allocation tag
#
# A monthly COST budget filtered to the var.cost_tag pair, so spend is
# tracked per team rather than account-wide. ACTUAL-spend notifications
# fire at each var.budget_thresholds_percent (default 50/80/100); a
# single FORECASTED notification fires at var.budget_forecast_threshold_percent
# (default 100). All notifications fan out to the SNS topic (DESIGN-0009 §1).
#
# The budget is intentionally not tagged — var.tags covers the IAM,
# AIP, SNS, and alarm resources; the budget's attribution is the
# filter, not a tag on the budget object itself.
#--------------------------------------------------------------

resource "aws_budgets_budget" "this" {
  name         = "${aws_iam_user.this.name}-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_amount)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # AWS Cost Explorer user-defined tag filter shape: user:<key>$<value>.
  # format() keeps the literal "$" separator out of HCL interpolation
  # (a "$${...}" template escape would render a literal "${...}", not a
  # "$" followed by the value).
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:%s$%s", var.cost_tag.key, var.cost_tag.value)]
  }

  dynamic "notification" {
    for_each = local.budget_notifications

    content {
      comparison_operator       = "GREATER_THAN"
      notification_type         = notification.value.type
      threshold                 = notification.value.threshold
      threshold_type            = "PERCENTAGE"
      subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
    }
  }
}
