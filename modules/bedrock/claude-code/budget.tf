#--------------------------------------------------------------
# AWS Budget — scoped to the cost-allocation tag
#
# A monthly COST budget filtered to the var.cost_tag pair, so spend is
# tracked per team rather than account-wide. ACTUAL-spend notifications
# fire at each var.budget_thresholds_percent (default 50/80/100); a
# single FORECASTED notification fires at var.budget_forecast_threshold_percent
# (default 100). All notifications fan out to the SNS topic (DESIGN-0009 §1).
#
# The budget carries no module-set tags: it inherits only the provider
# default_tags (DESIGN-0029). Its attribution is the cost-tag filter,
# not a tag on the budget object, so local.cost_tag_map is deliberately
# not applied here (IMPL-0026 OQ 6a).
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
