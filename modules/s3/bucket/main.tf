# S3 bucket (modules/s3/bucket)
#
# The family's general-purpose secure bucket (DESIGN-0019 Phase 3 /
# INV-0009 F1) and its reference consumer: the fleet's first
# count-gated remote-state read. The F2 security baseline (PAB,
# BucketOwnerEnforced, SSE-KMS + bucket key, TLS policy denies,
# MPU-abort hygiene) comes verbatim from the internal core; this
# module's type-specific surface is exactly the F4 access-logging
# tri-state plus the six Terragrunt globals and the additive
# operator policy statements (OQ 4b).
#
# The tri-state (var.access_logging):
#   1. default {}            — look the fleet sink up at the reserved
#      ADR-0020 key and log to it.
#   2. target_bucket set     — log to an explicit sink (e.g. a
#      non-default sink stack); the remote-state read is not created.
#   3. enabled = false       — no logging (deliberately log-less
#      stacks); the read is not created.
#
# The read lives HERE, not in the core (DESIGN-0019): the fleet reads
# at the use site, the six globals stay out of the core's interface,
# and ADR-0020's config.key plan assertion can only address a
# root-module data source.

data "terraform_remote_state" "access_logs" {
  count = var.access_logging.enabled && var.access_logging.target_bucket == null ? 1 : 0

  backend = "s3"

  # Terragrunt multi-account shape (IMPL-0015): account-scoped key, the
  # remote-state bucket's own region, and a cross-account assume_role.
  # The key is the FLAT reserved sink path — no <name> segment
  # (ADR-0020 reserved stack name: s3/access-logs).
  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.account_name}/${var.region}/s3/access-logs/terraform.tfstate"
    region         = var.remote_state_bucket_region
    use_path_style = true

    assume_role = {
      role_arn     = "arn:aws:iam::${var.account_id}:role/${var.deploy_role_name}"
      session_name = "Deploy-Tf"
    }
  }
}

locals {
  # null on both no-read paths (count = 0); the sink's contract output
  # on the default path.
  looked_up_sink = one(data.terraform_remote_state.access_logs[*].outputs.bucket_name)

  # The resolved F4 wiring the core consumes. prefix stays
  # caller-null-able: the core resolves null to "<composed-name>/"
  # (only it knows the final name — the shard prefix is unknown until
  # apply).
  logging = (var.access_logging.enabled ? {
    target_bucket = coalesce(var.access_logging.target_bucket, local.looked_up_sink)
    prefix        = var.access_logging.prefix
  } : null)
}

module "core" {
  source = "../internal/core"

  name                 = var.name
  name_override        = var.name_override
  shard_prefix_enabled = var.shard_prefix_enabled
  account_id           = var.account_id
  region               = var.region

  # SSE-KMS is the F2 baseline; kms_key_arn null = the AWS-managed
  # aws/s3 key + bucket key, a CMK otherwise.
  encryption = { kms_key_arn = var.kms_key_arn }

  versioning_enabled              = var.versioning_enabled
  force_destroy                   = var.force_destroy
  abort_incomplete_multipart_days = var.abort_incomplete_multipart_days
  tags                            = var.tags

  logging = local.logging

  allowed_vpc_endpoint_ids = var.allowed_vpc_endpoint_ids

  # OQ 4b: operator statements pass through additively — the core's
  # reserved-sid validation is the guard; the baseline denies always
  # render.
  internal_policy_statements = var.additional_policy_statements
}
