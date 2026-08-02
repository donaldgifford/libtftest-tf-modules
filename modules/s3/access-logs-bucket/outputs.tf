#--------------------------------------------------------------
# Outputs — the ADR-0020 contract surface.
#
# Consumer set (what the family's tri-state lookup reads): bucket_name.
# bucket_arn / bucket_id are additive; security_baseline +
# bucket_policy_json are re-exports for the plan suites (child-module
# resources are not assertable in terraform test).
#--------------------------------------------------------------

output "bucket_name" {
  description = "The sink's bucket name — THE contract output every family bucket's default access-logging lookup consumes (ADR-0020 key <account_name>/<region>/s3/access-logs/terraform.tfstate)."
  value       = module.core.bucket_name
}

output "bucket_arn" {
  description = "The sink's ARN (additive contract output)."
  value       = module.core.bucket_arn
}

output "bucket_id" {
  description = "The sink's bucket ID (additive contract output)."
  value       = module.core.bucket_id
}

output "security_baseline" {
  description = "The composed security baseline, re-exported verbatim from the internal core — pinned by this module's security_baseline.tftest.hcl (F3 variant: AES256)."
  value       = module.core.security_baseline
}

output "bucket_policy_json" {
  description = "The composed bucket policy (baseline denies + the log-delivery grant) — re-exported so the plan suites can assert the grant's shape."
  value       = module.core.bucket_policy_json
}
