# S3 mirror bucket (modules/s3/mirror-bucket)
#
# The fleet's provider-network-mirror serving bucket (DESIGN-0028 /
# gh-121, sluice workstream 2): a thin wrapper over the internal core
# with the mirror posture composed in root locals and injected through
# the core's additive internal_policy_statements channel.
#
# Guard placement (DESIGN-0028 OQ 2, settled at build): the mirror
# sids are reserved at THIS root (var.additional_policy_statements'
# validation), not in the core. The core cannot hold that guard —
# the mirror's own composed statements travel through
# internal_policy_statements, so a core-side rejection of those sids
# would fail the mirror itself. The merge below (mirror statements
# first, operator statements after) is collision-free by
# construction: the validation rejects any operator reuse.
#
# Pinned, no variable: versioning on, SSE-S3, COMPLIANCE mode when
# lock is enabled. No remote-state read anywhere in this module —
# logging names its sink explicitly.

locals {
  allow_mirror_read = [{
    sid               = "AllowMirrorReadFromVPCE"
    effect            = "Allow"
    principals        = { "*" = ["*"] }
    actions           = ["s3:GetObject"]
    resource_suffixes = ["/*"]
    conditions = [{
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = var.vpc_endpoint_ids
    }]
  }]

  # Count-gated: an empty condition-values list is invalid IAM, so an
  # empty break-glass list renders the statement with NO condition
  # block (absolute deny) instead.
  deny_object_deletion = [{
    sid               = "DenyObjectDeletion"
    effect            = "Deny"
    principals        = { "*" = ["*"] }
    actions           = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resource_suffixes = ["/*"]
    conditions = (length(var.break_glass_principal_arns) > 0 ? [{
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = var.break_glass_principal_arns
    }] : [])
  }]

  deny_policy_mutation = (var.enable_policy_mutation_guard ? [{
    sid               = "DenyPolicyMutation"
    effect            = "Deny"
    principals        = { "*" = ["*"] }
    actions           = ["s3:PutBucketPolicy", "s3:DeleteBucketPolicy"]
    resource_suffixes = [""]
    conditions = [{
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = var.policy_admin_principal_arns
    }]
  }] : [])

  # Rendered only for cross-account publishers (same-account needs no
  # grant). One statement over both suffixes: PutObject on the bucket
  # ARN itself matches nothing, so the ["", "/*"] span over-grants
  # vacuously while keeping the publisher grant a single sid.
  allow_cross_account_publisher = (length(var.cross_account_publisher_principal_arns) > 0 ? [{
    sid        = "AllowCrossAccountPublisherWrite"
    effect     = "Allow"
    principals = { AWS = var.cross_account_publisher_principal_arns }
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resource_suffixes = ["", "/*"]
    conditions        = []
  }] : [])

  # Mirror statements first, operator statements after — the merge is
  # additive-only; the root validation above rejects any operator sid
  # colliding with the seven reserved sids.
  mirror_policy_statements = concat(
    local.allow_mirror_read,
    local.deny_object_deletion,
    local.deny_policy_mutation,
    local.allow_cross_account_publisher,
    var.additional_policy_statements
  )

  # One fixed-id rule (the access-logs-bucket log_retention_days
  # precedent); null disables. Never expiration — the absence of an
  # expiration variable IS the guarantee.
  ia_lifecycle_rules = (var.noncurrent_version_ia_days != null ? [{
    id      = "noncurrent-versions-to-ia"
    enabled = true
    prefix  = null
    noncurrent_version_transitions = [{
      noncurrent_days = var.noncurrent_version_ia_days
      storage_class   = "STANDARD_IA"
    }]
  }] : [])

  # Explicit target or off — no remote-state read. prefix stays
  # caller-null-able: the core resolves null to "<composed-name>/".
  logging = (var.access_log_bucket != null ? {
    target_bucket = var.access_log_bucket
    prefix        = var.access_log_prefix
  } : null)
}

module "core" {
  source = "../internal/core"

  name                 = var.name
  name_override        = var.name_override
  shard_prefix_enabled = var.shard_prefix_enabled
  account_id           = var.account_id
  region               = var.region

  # Pinned SSE-S3: anonymous readers cannot decrypt SSE-KMS objects,
  # so the serving requirement dictates the mode (a kms_key_arn here
  # fails at plan via the core's precondition).
  encryption = { mode = "s3" }

  # Pinned on: mirror artifacts are immutable releases; noncurrent
  # versions are the forensics record.
  versioning_enabled = true

  # OQ 5a: opt-in lock, COMPLIANCE pinned. The core's versioning
  # coupling is satisfied above; its days-xor-years and
  # retention-set-but-disabled coherence guards cover this shape.
  object_lock = {
    enabled = var.enable_object_lock
    mode    = "COMPLIANCE"
    days    = var.object_lock_retention_days
  }

  force_destroy                   = var.force_destroy
  abort_incomplete_multipart_days = var.abort_incomplete_multipart_days
  extra_lifecycle_rules           = local.ia_lifecycle_rules
  tags                            = var.tags

  logging = local.logging

  # OQ 1a: one list drives both the allow (above) and the core's
  # DenyOutsideVpce — the two can never contradict.
  allowed_vpc_endpoint_ids = var.vpc_endpoint_ids

  internal_policy_statements = local.mirror_policy_statements
}
