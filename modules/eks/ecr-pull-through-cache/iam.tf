#--------------------------------------------------------------
# Node IAM policy (gated; ADR-0015 emission side)
#--------------------------------------------------------------
#
# Phase 6 lands aws_iam_policy.node_pull_through (count-gated on
# var.enable_node_pull_through_policy) here. Two-stages-of-consent
# per ADR-0015: this is gate (a) — emission. Gate (b) is the
# consumer's Terragrunt config wiring the policy ARN into
# managed-node-group's var.extra_node_policies.
