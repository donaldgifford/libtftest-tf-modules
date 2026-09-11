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

#--------------------------------------------------------------
# Rules
#--------------------------------------------------------------

# for_each by LOGICAL rule name, so every rule has its own address and
# its own lifecycle. Removing one allowlist entry plans as exactly one
# destroy; it never churns a sibling.
#
# to_port null-collapses to from_port (the single-port case, which is
# most of them). An explicit ternary rather than coalesce(): coalesce
# ERRORS when every argument is null, which is exactly the legal
# all-protocols shape where both ports are absent.
resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = var.ingress_rules

  security_group_id = aws_security_group.this.id

  description = each.value.description
  ip_protocol = each.value.ip_protocol
  from_port   = each.value.from_port
  to_port     = each.value.to_port != null ? each.value.to_port : each.value.from_port

  # Exactly one of these is non-null, enforced at validation.
  cidr_ipv4                    = each.value.cidr_ipv4
  cidr_ipv6                    = each.value.cidr_ipv6
  prefix_list_id               = each.value.prefix_list_id
  referenced_security_group_id = each.value.referenced_security_group_id

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_vpc_security_group_egress_rule" "this" {
  for_each = var.egress_rules

  security_group_id = aws_security_group.this.id

  description = each.value.description
  ip_protocol = each.value.ip_protocol
  from_port   = each.value.from_port
  to_port     = each.value.to_port != null ? each.value.to_port : each.value.from_port

  cidr_ipv4                    = each.value.cidr_ipv4
  cidr_ipv6                    = each.value.cidr_ipv6
  prefix_list_id               = each.value.prefix_list_id
  referenced_security_group_id = each.value.referenced_security_group_id

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

# The visible all-egress default — byte-for-byte the eks/cluster
# `nodes_all` shape. Count-gated rather than folded into egress_rules so
# that turning it off is one boolean in the plan, not the absence of a
# map entry nobody remembers was there.
resource "aws_vpc_security_group_egress_rule" "all" {
  count = var.allow_all_egress ? 1 : 0

  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress"

  tags = merge(var.tags, { Name = "${var.name}-all-egress" })
}
