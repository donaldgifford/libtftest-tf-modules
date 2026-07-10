#--------------------------------------------------------------
# DB-tier networking
#
# Subnet group lives in private subnets from the VPC remote state
# (per IMPL-0007 Q1 — reuses the EKS-cluster private_subnet_ids
# contract). Security group's ingress is the SG-source-list contract
# per DESIGN-0007 Q5 / IMPL-0012 Phase 4: callers pass consumer SG
# IDs via var.allowed_consumer_sg_ids; the module emits one granular
# aws_vpc_security_group_ingress_rule per entry on the engine's
# default port. Empty list leaves the cluster reachable from nowhere.
#--------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name        = "${var.identifier_prefix}-rds-cluster"
  description = "Aurora provisioned cluster ${var.identifier_prefix} subnet group"
  subnet_ids  = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  tags        = var.tags
}

resource "aws_security_group" "this" {
  name        = "${var.identifier_prefix}-rds-cluster"
  description = "Aurora provisioned cluster ${var.identifier_prefix} security group"
  vpc_id      = data.terraform_remote_state.vpc.outputs.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "consumer" {
  for_each = toset(var.allowed_consumer_sg_ids)

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  from_port                    = local.engine_default_port
  to_port                      = local.engine_default_port
  ip_protocol                  = "tcp"
  description                  = "Ingress from consumer SG ${each.value} on the engine default port"
  tags                         = var.tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All-outbound egress for AWS API endpoints (Secrets Manager, KMS, CloudWatch metrics)"
  tags              = var.tags
}
