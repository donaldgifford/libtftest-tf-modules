#--------------------------------------------------------------
# ECR Pull-Through Cache Module — entrypoint
#--------------------------------------------------------------
#
# Provisions ECR pull-through cache rules for the six DESIGN-0005
# upstreams (ECR Public, Quay, Docker Hub, GHCR, Kubernetes, MCR).
# Authenticated upstreams (Docker Hub, GHCR) attach their per-
# upstream Secrets Manager secret ARN as credential_arn.
#
# This module reads NO remote state — it is fleet-shared and
# cluster-agnostic (IMPL-0005 Q7). The only data source is
# data.aws_caller_identity.current (ADR-0001 identity carve-out)
# used to scope the IAM policy's Resource ARN to this account.
#
# Phase 4 lands aws_ecr_pull_through_cache_rule.this here.

# Identity-class carve-out per ADR-0001. The account ID is identity
# (does not drift), the sts:GetCallerIdentity call is effectively
# free, and the value scopes the node IAM policy's Resource ARN to
# this account's ECR repositories — meaningful compositional work,
# not a remote-state alias.
data "aws_caller_identity" "current" {}
