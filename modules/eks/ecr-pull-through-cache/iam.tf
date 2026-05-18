#--------------------------------------------------------------
# Node IAM policy (gated; ADR-0015 emission side)
#--------------------------------------------------------------
#
# Two-stages-of-consent per ADR-0015. This is gate (a): emission.
# Off by default? No — emission default is ON (var.enable_node
# _pull_through_policy = true). The actual reach to a node role
# requires gate (b): the consumer's Terragrunt config explicitly
# wires this output ARN into managed-node-group's var.extra
# _node_policies. Either consent alone is a no-op.
#
# Resource ARN is scoped to this account's ECR repositories in
# var.region (account_id from data.aws_caller_identity.current).

data "aws_iam_policy_document" "node_pull_through" {
  count = var.enable_node_pull_through_policy ? 1 : 0

  statement {
    effect = "Allow"

    actions = [
      "ecr:CreateRepository",
      "ecr:BatchImportUpstreamImage",
    ]

    resources = [
      "arn:aws:ecr:${var.region}:${local.account_id}:repository/*",
    ]
  }
}

resource "aws_iam_policy" "node_pull_through" {
  count = var.enable_node_pull_through_policy ? 1 : 0

  name        = "${var.name_prefix}-ecr-pull-through"
  description = "Permissions for EKS nodes to use ECR pull-through cache (consumed by managed-node-group var.extra_node_policies per ADR-0015)."
  policy      = data.aws_iam_policy_document.node_pull_through[0].json

  tags = var.tags
}
