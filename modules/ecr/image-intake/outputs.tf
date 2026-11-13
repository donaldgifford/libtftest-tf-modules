#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------

output "quarantine_prefix" {
  description = "The quarantine prefix. Keep it in ecr/registry's protected_prefixes, never in pull_repository_prefixes."
  value       = var.quarantine_prefix
}

output "promoted_prefixes" {
  description = "Promoted prefixes, sorted: shaped to feed ecr/registry's pull_repository_prefixes directly."
  value       = local.promoted_keys
}

output "writer_policy_json" {
  description = "Identity policy for writer roles: the ECR auth token plus push and create-on-push on the quarantine prefix only. Compose into iam/role or eks/pod-identity-access inline_policies."
  value       = local.writer_policy_json
}

output "intake_policy_json" {
  description = "Identity policy for intake roles: read and scan findings on quarantine; pull, push and create-on-push on the promoted prefixes. Signing comes from the signing key's own key policy, not this document."
  value       = local.intake_policy_json
}

output "intake_event_pattern_json" {
  description = "EventBridge pattern matching successful pushes to the quarantine prefix. Always exported, for callers who wire their own rule."
  value       = jsonencode(local.intake_event_pattern)
}

output "intake_event_rule_arn" {
  description = "ARN of the intake event rule, or null when intake_event_target is null."
  value       = one(aws_cloudwatch_event_rule.quarantine_push[*].arn)
}

output "template_role_arn" {
  description = "ARN of the role ECR assumes when it creates repositories from these templates."
  value       = aws_iam_role.template.arn
}
