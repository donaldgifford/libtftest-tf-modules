#--------------------------------------------------------------
# Shared node security group
#--------------------------------------------------------------
#
# Every downstream node-group module attaches its launch template to
# this SG. Exported as output.node_security_group_id in Phase 7.
#
# Rules use granular aws_vpc_security_group_*_rule resources so each
# rule has its own lifecycle (no full-SG churn on a single-rule edit).

resource "aws_security_group" "nodes" {
  name        = "${var.name}-nodes"
  description = "Shared node SG for EKS cluster ${var.name}"
  vpc_id      = data.terraform_remote_state.vpc.outputs.vpc_id
  tags        = var.tags
}

# Cluster SG → nodes. EKS uses ephemeral ports for kubelet + webhook
# traffic; the cluster-to-nodes path must be wide open at L4.
resource "aws_vpc_security_group_ingress_rule" "nodes_from_cluster" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "-1"
  description                  = "All traffic from the EKS-managed cluster SG"
  tags                         = var.tags
}

# Pod ↔ pod traffic within the node fleet.
resource "aws_vpc_security_group_ingress_rule" "nodes_from_self" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  description                  = "Node-to-node pod traffic"
  tags                         = var.tags
}

# Outbound for workloads (pulls, external APIs, log shipping).
resource "aws_vpc_security_group_egress_rule" "nodes_all" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress for workloads"
  tags              = var.tags
}
