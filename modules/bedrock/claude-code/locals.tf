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
}
