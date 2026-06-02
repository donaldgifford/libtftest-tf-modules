#--------------------------------------------------------------
# Computed locals
#
# Populated across phases:
#   * account_id    — caller account (cost_allocation.tf, Phase 2);
#                     IAM policy scopes off this.
#   * cost_tag_map  — the single-source { key = value } attribution
#                     pair re-used by IAM user/policy tags, AIP tags,
#                     and the budget filter (cost_allocation.tf, Phase 2).
#   * user_name     — derived IAM user name (iam.tf, Phase 3).
#   * aip_arns      — map of models key -> AIP ARN
#                     (inference_profiles.tf, Phase 4); the IAM policy
#                     resource list reads this at its use site.
#--------------------------------------------------------------

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Single source-of-truth for the attribution tag pair. Re-used by the
  # IAM user/policy tags (Phase 3), AIP tags (Phase 4), the CloudWatch
  # alarm tags (Phase 7), and (indirectly) the budget filter (Phase 6).
  # Kept separate from var.tags — this is a load-bearing dimension, not
  # a generic tag.
  cost_tag_map = { (var.cost_tag.key) = var.cost_tag.value }
}
