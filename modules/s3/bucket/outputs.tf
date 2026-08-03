#--------------------------------------------------------------
# Outputs — contract surface + the plan suites' test windows
# (child-module resources aren't assertable in terraform test).
#--------------------------------------------------------------

output "bucket_name" {
  description = "The bucket's final composed name."
  value       = module.core.bucket_name
}

output "bucket_arn" {
  description = "The bucket's ARN."
  value       = module.core.bucket_arn
}

output "bucket_id" {
  description = "The bucket's ID (its name, as the provider returns it)."
  value       = module.core.bucket_id
}

output "security_baseline" {
  description = "The composed security baseline, re-exported verbatim from the internal core — pinned by this module's security_baseline.tftest.hcl (the family's byte-identical copy, Phase-5 diff guard)."
  value       = module.core.security_baseline
}

output "bucket_policy_json" {
  description = "The composed bucket policy (baseline denies + opt-in VPCE + additional_policy_statements) — re-exported so plan suites can assert the additive merge."
  value       = module.core.bucket_policy_json
}

output "logging_target" {
  description = "Resolved server-access-logging target bucket (the looked-up fleet sink, the explicit override, or null when disabled) — the plan suites' window on the tri-state resolution."
  value       = module.core.logging_target
}

output "logging_prefix" {
  description = "Resolved server-access-logging prefix, or null when logging is off."
  value       = module.core.logging_prefix
}
