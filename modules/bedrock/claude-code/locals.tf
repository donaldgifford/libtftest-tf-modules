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

  # Backing IAM user name — explicit override or derived from the cost
  # tag value. Seeds the IAM policy, SNS topic, budget, and alarm names.
  user_name = coalesce(var.user_name, "${var.cost_tag.value}-claude-code")

  # AIP ARNs keyed by the models logical name. Single source for the IAM
  # policy's AllowAipInvoke resource list — read at the use site in
  # iam.tf, no second alias (ADR-0001 / CLAUDE.md).
  aip_arns = { for k, v in aws_bedrock_inference_profile.this : k => v.arn }

  # Foundation-model ARNs backing each AIP. Bedrock evaluates IAM
  # against BOTH the AIP and the wrapped foundation model at invoke
  # time, so the policy lists both. model_id is normally a full FM ARN;
  # a bare model ID is expanded to the regional foundation-model ARN as
  # a convenience.
  model_fm_arns = [
    for k, v in var.models :
    startswith(v.model_id, "arn:") ? v.model_id : "arn:aws:bedrock:${var.region}::foundation-model/${v.model_id}"
  ]
}
