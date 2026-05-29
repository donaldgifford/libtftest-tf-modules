#--------------------------------------------------------------
# EFS filesystem
#
# creation_token = var.identifier_prefix per DESIGN-0008 Q10 —
# deterministic, no random suffix. README Operational gotchas
# documents the destroy + immediate re-apply collision window
# (rare; AWS returns a clear TokenAlreadyExists error when it
# happens).
#
# Dynamic lifecycle_policy blocks emit one block per non-null
# transition attribute on var.lifecycle_policy. var.lifecycle_policy
# = null disables all three transitions; partial overrides flow
# through the optional() defaults (IMPL-0008 Q2 resolution).
#
# Cross-variable invariant — throughput_mode = "provisioned" iff
# provisioned_throughput_in_mibps != null — is enforced via
# lifecycle.precondition (terraform 1.1 variable.validation cannot
# reference other variables; precondition fires at plan).
#--------------------------------------------------------------

resource "aws_efs_file_system" "this" {
  creation_token                  = var.identifier_prefix
  encrypted                       = true
  kms_key_id                      = local.kms_key_arn
  performance_mode                = var.performance_mode
  throughput_mode                 = var.throughput_mode
  provisioned_throughput_in_mibps = var.provisioned_throughput_in_mibps
  tags                            = var.tags

  dynamic "lifecycle_policy" {
    for_each = var.lifecycle_policy != null && try(var.lifecycle_policy.transition_to_ia, null) != null ? [var.lifecycle_policy.transition_to_ia] : []

    content {
      transition_to_ia = lifecycle_policy.value
    }
  }

  dynamic "lifecycle_policy" {
    for_each = var.lifecycle_policy != null && try(var.lifecycle_policy.transition_to_archive, null) != null ? [var.lifecycle_policy.transition_to_archive] : []

    content {
      transition_to_archive = lifecycle_policy.value
    }
  }

  dynamic "lifecycle_policy" {
    for_each = var.lifecycle_policy != null && try(var.lifecycle_policy.transition_to_primary_storage_class, null) != null ? [var.lifecycle_policy.transition_to_primary_storage_class] : []

    content {
      transition_to_primary_storage_class = lifecycle_policy.value
    }
  }

  lifecycle {
    precondition {
      condition     = (var.throughput_mode == "provisioned") == (var.provisioned_throughput_in_mibps != null)
      error_message = "throughput_mode = \"provisioned\" requires provisioned_throughput_in_mibps to be non-null; the other two modes require it to be null."
    }
  }
}
