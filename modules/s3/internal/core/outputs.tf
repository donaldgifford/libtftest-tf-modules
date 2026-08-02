#--------------------------------------------------------------
# Outputs
#
# security_baseline is the family's drift tripwire (DESIGN-0019): every
# value is derived from ACTUAL resource attributes (never echoed
# inputs), the purpose modules re-export it verbatim, and one identical
# security_baseline.tftest.hcl per purpose module pins it — because
# terraform test assertions cannot address a child module's resources,
# this output is the only window their suites have into the core.
#--------------------------------------------------------------

locals {
  sse_rule    = one(aws_s3_bucket_server_side_encryption_configuration.this.rule)
  sse_default = one(local.sse_rule.apply_server_side_encryption_by_default)

  mpu_abort_rule = one([
    for r in aws_s3_bucket_lifecycle_configuration.this.rule :
    r if r.id == "abort-incomplete-multipart-upload"
  ])

  policy_sids = [for s in jsondecode(data.aws_iam_policy_document.bucket.json).Statement : s.Sid]
}

output "bucket_id" {
  description = "The bucket's ID (its name, as the provider returns it)."
  value       = aws_s3_bucket.this.id
}

output "bucket_name" {
  description = "The bucket's final name — composed <shard->-<name>-<account_id>-<region> or the name_override verbatim."
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "The bucket's ARN."
  value       = aws_s3_bucket.this.arn
}

output "bucket_policy_json" {
  description = "The composed bucket policy document (baseline denies + opt-in VPCE + injected statements) — assertable via jsondecode in plan suites."
  value       = data.aws_iam_policy_document.bucket.json
}

output "logging_target" {
  description = "Resolved server-access-logging target bucket, or null when logging is off."
  value       = try(aws_s3_bucket_logging.this[0].target_bucket, null)
}

output "logging_prefix" {
  description = "Resolved server-access-logging prefix (caller value or the '<composed-name>/' default), or null when logging is off."
  value       = try(aws_s3_bucket_logging.this[0].target_prefix, null)
}

output "security_baseline" {
  description = "The composed security baseline, derived from actual resource attributes — re-exported verbatim by every purpose module and pinned by the shared security_baseline.tftest.hcl (DESIGN-0019)."
  value = {
    block_public_acls       = aws_s3_bucket_public_access_block.this.block_public_acls
    block_public_policy     = aws_s3_bucket_public_access_block.this.block_public_policy
    ignore_public_acls      = aws_s3_bucket_public_access_block.this.ignore_public_acls
    restrict_public_buckets = aws_s3_bucket_public_access_block.this.restrict_public_buckets
    object_ownership        = one(aws_s3_bucket_ownership_controls.this.rule).object_ownership
    sse_algorithm           = local.sse_default.sse_algorithm
    kms_key_arn             = local.sse_default.kms_master_key_id
    bucket_key_enabled      = local.sse_rule.bucket_key_enabled
    versioning_status       = one(aws_s3_bucket_versioning.this.versioning_configuration).status
    mpu_abort_days          = one(local.mpu_abort_rule.abort_incomplete_multipart_upload).days_after_initiation
    tls_deny_sids_present = alltrue([
      contains(local.policy_sids, "DenyInsecureTransport"),
      contains(local.policy_sids, "DenyOldTls"),
    ])
    vpce_restricted = contains(local.policy_sids, "DenyOutsideVpce")
  }
}
