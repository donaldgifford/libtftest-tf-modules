#--------------------------------------------------------------
# Outputs (consumer contract per DESIGN-0005)
#--------------------------------------------------------------
#
# Per IMPL-0005 Q3 (schema verification at implementation time):
# the v6 provider exposes id (not arn) as the canonical identifier
# on both aws_ecr_pull_through_cache_rule and
# aws_ecr_repository_creation_template. Outputs reflect the schema
# (named *_ids rather than *_arns) — DESIGN-0005's naming was
# speculative.

output "cache_rule_ids" {
  description = "Map of upstream name → ECR pull-through cache rule ID. The id is the canonical identifier (the resource type does not expose an arn attribute in hashicorp/aws ~> 6.2)."
  value       = { for k, r in aws_ecr_pull_through_cache_rule.this : k => r.id }
}

output "cache_url_prefixes" {
  description = "Map of upstream name → fully-qualified ECR cache URL prefix (<account_id>.dkr.ecr.<region>.amazonaws.com/<prefix>). Public-AWS-only assumption per IMPL-0005 Q4 — partition-aware construction is future work when a GovCloud consumer materializes."
  value       = { for k, r in aws_ecr_pull_through_cache_rule.this : k => "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com/${r.ecr_repository_prefix}" }
}

output "credential_secret_arns" {
  description = "Map of upstream name → Secrets Manager secret ARN holding that upstream's pull-through credentials. Empty for instantiations whose upstream_registries contain only open upstreams."
  value       = { for k, s in aws_secretsmanager_secret.upstream : k => s.arn }
}

output "node_pull_through_policy_arn" {
  description = "ARN of the IAM policy carrying ecr:CreateRepository + ecr:BatchImportUpstreamImage scoped to this account's ECR repositories. Consumers wire this into managed-node-group's var.extra_node_policies per ADR-0015. Null when var.enable_node_pull_through_policy = false (emission gate (a) closed)."
  value       = var.enable_node_pull_through_policy ? aws_iam_policy.node_pull_through[0].arn : null
}

output "repository_creation_template_id" {
  description = "ID of the aws_ecr_repository_creation_template (the prefix this template applies to). Renamed from _arn per IMPL-0005 Q3 — the v6 provider exposes id, not arn."
  value       = aws_ecr_repository_creation_template.pull_through.id
}
