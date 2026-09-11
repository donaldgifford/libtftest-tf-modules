# Generic security group — the standalone ingress-allowlist SG producer
# (DESIGN-0026 / IMPL-0023).
#
# Scope guardrail: frontend-style STANDALONE security groups only.
# Resource-owning modules keep their own SGs (eks/cluster's node SG, the
# RDS SGs, the EFS mount-target SGs), and the AWS Load Balancer
# Controller keeps backend + node-SG rules. This module must never
# become the fleet's SG-of-everything.
#
# Rules are granular aws_vpc_security_group_{ingress,egress}_rule
# resources keyed by logical name — the eks/cluster idiom productized.
# Never inline ingress/egress blocks: mixing inline and granular rules
# is the known drift pathology, and inline blocks churn the whole SG on
# a single-rule edit.

#--------------------------------------------------------------
# The security group
#--------------------------------------------------------------

# name_prefix + create_before_destroy, NOT a fixed name (DESIGN-0026
# OQ 2a). SG name and description are create-time on AWS, so editing
# either forces a replacement — and with a fixed name a destroy-first
# replacement of an SG that is attached to a live ALB deadlocks on
# DependencyViolation, while CBD is outright impossible because the
# successor would collide on the name.
#
# What this does NOT fix, and the README says so: a replacement still
# mints a new security group id. CBD removes the deadlock and the
# collision; the chart-side value update is still the caller's.
resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = coalesce(var.description, "Managed by Terraform — ${var.name}")
  vpc_id      = data.terraform_remote_state.vpc.outputs.vpc_id

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}
