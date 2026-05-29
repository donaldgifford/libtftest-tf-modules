#--------------------------------------------------------------
# Mount targets — one per VPC private subnet
#
# Iterates over data.terraform_remote_state.vpc.outputs.private_subnet_ids
# (per DESIGN-0008 Q9 — all subnets, maximum AZ availability). The
# CSI driver picks whichever mount target sits in the same AZ as
# the pod; missing a mount target for an AZ silently breaks NFS
# mounts for pods in that AZ.
#
# security_groups is a single-element list per IMPL-0008 Q7 — the
# module emits exactly one mount-target SG; additional consumer
# access is layered as ingress rules on that SG (see network.tf).
#--------------------------------------------------------------

resource "aws_efs_mount_target" "this" {
  for_each = toset(data.terraform_remote_state.vpc.outputs.private_subnet_ids)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [aws_security_group.this.id]
}
