#--------------------------------------------------------------
# Outputs — the consumer contract (DESIGN-0030 § The consumer contract)
#--------------------------------------------------------------

output "registry_id" {
  description = "The registry's account ID."
  value       = local.account_id
}

output "registry_url" {
  description = "The registry hostname consumers put in image references: <registry_url>/<prefix>/<path>@sha256:<digest>."
  value       = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
}

output "consumer_account_ids" {
  description = "The allow-listed account IDs, sorted."
  value       = local.consumer_ids
}

output "pull_repository_prefixes" {
  description = "The prefixes consumer accounts may pull, sorted."
  value       = local.pull_prefixes
}

output "pull_repository_arns" {
  description = "The repository ARN patterns the pull grant covers."
  value       = local.pull_repository_arns
}

output "registry_policy_json" {
  description = "The composed registry policy document, or null when none renders (no consumer accounts and no additional statements)."
  value       = local.registry_policy_json
}

output "consumer_identity_policy_json" {
  description = "The minimal identity policy a consumer principal needs (ecr:GetAuthorizationToken on *, plus the pull actions on pull_repository_arns), or null with no prefixes. The AWS-managed AmazonEC2ContainerRegistryReadOnly / PullOnly policies already cover it; this is for hand-scoped roles."
  value       = local.consumer_identity_policy_json
}

output "registry_policy_scope" {
  description = "\"V2\" when this module manages the REGISTRY_POLICY_SCOPE setting, otherwise null."
  value       = var.manage_registry_policy_scope ? "V2" : null
}
