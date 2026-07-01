#--------------------------------------------------------------
# Proxy security group
#
# The proxy gets its own SG in the target's VPC (vpc_id from remote
# state). Ingress: one granular aws_vpc_security_group_ingress_rule
# per var.allowed_consumer_sg_ids entry on the engine listener port
# (clients → proxy), matching the serverless module's SG-source-list
# style. Egress: a single rule to the target DB's SG on the DB port
# (proxy → DB) — DESIGN-0010 Q3 — tighter than the serverless
# all-outbound default because the proxy only needs to reach its one
# target. The reciprocal DB-side ingress is wired outside this module
# by passing this SG's id (the proxy_security_group_id output) into
# the DB module's allowed_consumer_sg_ids on a subsequent apply.
#--------------------------------------------------------------

resource "aws_security_group" "proxy" {
  name        = "${var.name}-rds-proxy"
  description = "RDS Proxy ${var.name} security group"
  vpc_id      = local.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "consumer" {
  for_each = toset(var.allowed_consumer_sg_ids)

  security_group_id            = aws_security_group.proxy.id
  referenced_security_group_id = each.value
  from_port                    = local.port
  to_port                      = local.port
  ip_protocol                  = "tcp"
  description                  = "Ingress from consumer SG ${each.value} on the engine listener port"
  tags                         = var.tags
}

resource "aws_vpc_security_group_egress_rule" "to_db" {
  security_group_id            = aws_security_group.proxy.id
  referenced_security_group_id = local.db_security_group_id
  from_port                    = local.port
  to_port                      = local.port
  ip_protocol                  = "tcp"
  description                  = "Egress to the target DB security group on the engine port (proxy → DB, DESIGN-0010 Q3)"
  tags                         = var.tags
}
