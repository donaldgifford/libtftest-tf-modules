#--------------------------------------------------------------
# Bucket name composition (DESIGN-0019 / INV-0009 OQ 7)
#
# Default composed name: <name>-<account_id>-<region> — S3 bucket names
# are a global namespace, so the account+region suffix makes fleet
# collisions structurally impossible and encodes provenance. Opt-in
# shard prefix (shard_prefix_enabled) prepends a stable 5-char random
# string: <shard>-<name>-<account_id>-<region>. name_override bypasses
# composition entirely (externally-dictated names).
#
# The composed-name length/charset check is a lifecycle.precondition on
# aws_s3_bucket.this (bucket.tf) — it spans several variables, and
# cross-variable references are not allowed in variable validations at
# the fleet's terraform floor (validation-split doctrine).
#
# NB: toggling shard_prefix_enabled after creation changes the bucket
# name and therefore REPLACES the bucket (destructive). The random
# string itself is stable across applies (no keepers wired to mutable
# inputs).
#--------------------------------------------------------------

resource "random_string" "shard_prefix" {
  count = var.shard_prefix_enabled ? 1 : 0

  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  composed_name = join("-", concat(
    var.shard_prefix_enabled ? [random_string.shard_prefix[0].result] : [],
    [var.name, var.account_id, var.region],
  ))

  # The name the bucket actually gets: override verbatim, else composed.
  bucket_name = coalesce(var.name_override, local.composed_name)

  # Plan-knowable ARN for policy composition. aws_s3_bucket.this.arn is
  # unknown until apply, which would defer data.aws_iam_policy_document
  # and make the composed json (and every sid assertion in the plan
  # suites, plus security_baseline's policy-derived fields) unknowable
  # at plan. S3 bucket ARNs are deterministic (arn:aws:s3:::<name>);
  # the fleet is aws-partition-only, like the role_arn compositions in
  # every remote-state read.
  bucket_arn = "arn:aws:s3:::${local.bucket_name}"
}
