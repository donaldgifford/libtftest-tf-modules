#--------------------------------------------------------------
# Mount-target networking
#
# Module-managed SG sits in the VPC pulled from VPC remote state.
# Three ingress rule resources:
#
#   * from_nodes — NFS (TCP 2049) ingress from the EKS node SG
#     resolved via cluster remote state. Wires EFS CSI driver pods
#     to the filesystem out of the box.
#   * from_extra — for_each over var.additional_allowed_consumer_sg_ids
#     for non-EKS consumers (EC2, batch jobs, peer-VPC SGs).
#   * all egress — opens outbound for SG-attached interfaces; the
#     mount-target ENI itself never initiates traffic but the SG
#     spec still requires an egress rule for symmetry.
#
# Single SG only (per IMPL-0008 Q7) — additional consumer SGs are
# expressed as ingress rules on this SG, not as additional SGs
# attached to the mount target.
#--------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${var.identifier_prefix}-efs"
  description = "EFS filesystem ${var.identifier_prefix} mount-target security group"
  vpc_id      = data.terraform_remote_state.vpc.outputs.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "from_nodes" {
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = data.terraform_remote_state.eks.outputs.node_security_group_id
  from_port                    = local.nfs_port
  to_port                      = local.nfs_port
  ip_protocol                  = "tcp"
  description                  = "NFS ingress from EKS node SG (EFS CSI driver pods)"
  tags                         = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "from_extra" {
  for_each = toset(var.additional_allowed_consumer_sg_ids)

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  from_port                    = local.nfs_port
  to_port                      = local.nfs_port
  ip_protocol                  = "tcp"
  description                  = "NFS ingress from additional consumer SG ${each.value}"
  tags                         = var.tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All-outbound egress (SG spec symmetry; mount-target ENIs never initiate)"
  tags              = var.tags
}
