#--------------------------------------------------------------
# Module outputs (consumer contract)
#
# Stable surface; renaming or removing an output breaks downstream
# remote-state consumers — notably the future developer-onboarding
# stack that reads aip_arns to populate Claude Code's settings.json
# (ANTHROPIC_MODEL / ANTHROPIC_SMALL_FAST_MODEL) per DESIGN-0009.
#
# Deliberately NO credential output. The bearer token (the IAM
# service-specific credential's one-time secret) is never produced by
# Terraform — it is minted out-of-band by the bedrock-keyctl Go tool
# and written to a secret sink. There is no bedrock_api_key / secret /
# credential output here, by design (DESIGN-0009 §1).
#--------------------------------------------------------------

output "iam_user_name" {
  description = "Name of the backing IAM user. Pass to the bedrock-keyctl tool's --user flag to mint/rotate/revoke the bearer token (the service-specific credential for bedrock.amazonaws.com)."
  value       = aws_iam_user.this.name
}

output "iam_user_arn" {
  description = "ARN of the backing IAM user — the IAM-principal pivot for cost allocation and for scoping cross-account trust policies."
  value       = aws_iam_user.this.arn
}

output "aip_arns" {
  description = "Map of var.models logical name -> application inference profile ARN. The load-bearing output: the developer-onboarding stack reads this to populate Claude Code's settings.json (ANTHROPIC_MODEL / ANTHROPIC_SMALL_FAST_MODEL) and the IAM policy scopes invoke permissions to these ARNs."
  value       = local.aip_arns
}

output "sns_topic_arn" {
  description = "ARN of the alert SNS topic. Consumers wanting to attach their own subscriber type (PagerDuty, a custom Lambda, a second Slack workspace) reference this directly rather than re-deriving it."
  value       = aws_sns_topic.alerts.arn
}

output "budget_name" {
  description = "Name of the tag-filtered AWS Budget. Useful for cross-stack references and for operators inspecting budget state via the AWS CLI."
  value       = aws_budgets_budget.this.name
}

output "cost_tag_key" {
  description = "The cost-allocation tag key (var.cost_tag.key). Passthrough for the payer-account component: when cost_allocation_tag_activation = 'payer', the operator runs `aws ce update-cost-allocation-tags-status` in the management account with this key (README documents the recipe)."
  value       = var.cost_tag.key
}

output "cost_tag_value" {
  description = "The cost-allocation tag value (var.cost_tag.value). Passthrough surfacing the attribution dimension's value alongside cost_tag_key for the payer-account activation recipe and for downstream cost-report tooling."
  value       = var.cost_tag.value
}

output "key_expiry_days" {
  description = "Expected bearer-token rotation cadence in days (var.key_expiry_days, default 90 per DESIGN-0009 Q11). Passthrough only — Terraform does not mint the credential; this co-locates the operator-facing contract so the bedrock-keyctl tool / onboarding stack can read the intended --expiry-days from remote state."
  value       = var.key_expiry_days
}
