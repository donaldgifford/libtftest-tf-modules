#--------------------------------------------------------------
# Managed Node Group — secure node group with gVisor
#--------------------------------------------------------------
#
# Implements DESIGN-0001 in phases per IMPL-0002. Currently scaffolded
# at Phase 1 — variable surface, remote-state composition, and locals
# only. aws_iam_role.node, aws_launch_template.node, and
# aws_eks_node_group.this land in Phases 2 / 3 / 5.
