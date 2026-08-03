# S3 access-logs bucket (modules/s3/access-logs-bucket)
#
# The per-region server-access-logging sink of the s3 family
# (DESIGN-0019 Phase 2 / INV-0009 F3) and the producer of the reserved
# ADR-0020 contract: deployed at the live-repo stack path
# s3/access-logs, its state lands at
# <account_name>/<region>/s3/access-logs/terraform.tfstate — the key
# every family bucket's default tri-state lookup composes. A
# non-default sink is this same module at another s3/<stack-name> with
# overridden vars, reached via the consumers' target_bucket override.
#
# Deliberate F3 asymmetries with its consumers:
#   - SSE-S3 pinned (log delivery does not write to SSE-KMS targets;
#     no CMK override exists here).
#   - No access_logging surface (self-logging loops log deliveries
#     into themselves).
#   - Versioning pinned off (log objects are append-only noise to
#     version) + a default 90-day retention expiration (OQ 1a).
#   - Log delivery is granted via the bucket policy
#     (logging.s3.amazonaws.com conditioned on aws:SourceAccount —
#     OQ 2a: any bucket in the account may point here with zero
#     per-source edits), NOT ACLs — BucketOwnerEnforced stays on.

module "core" {
  source = "../internal/core"

  name                 = var.name
  name_override        = var.name_override
  shard_prefix_enabled = var.shard_prefix_enabled
  account_id           = var.account_id
  region               = var.region

  # F3 exception: the one bucket in the family that cannot take the
  # SSE-KMS default.
  encryption = { mode = "s3" }

  force_destroy = var.force_destroy
  tags          = var.tags

  # OQ 1a: bounded growth by default; null disables.
  extra_lifecycle_rules = var.log_retention_days == null ? [] : [{
    id              = "expire-access-logs"
    expiration_days = var.log_retention_days
  }]

  # OQ 2a: the log-delivery service principal, account-scoped.
  internal_policy_statements = [{
    sid               = "AllowS3ServerAccessLogDelivery"
    principals        = { Service = ["logging.s3.amazonaws.com"] }
    actions           = ["s3:PutObject"]
    resource_suffixes = ["/*"]
    conditions = [{
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }]
  }]
}
