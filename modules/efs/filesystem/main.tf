#--------------------------------------------------------------
# Data sources — VPC + EKS remote state
#
# The module reads two remote states per DESIGN-0008 Q1:
#
#   * VPC state for vpc_id (security group placement) and
#     private_subnet_ids (mount target topology — one mount
#     target per private subnet for max AZ availability per
#     DESIGN-0008 Q9).
#   * EKS cluster state for node_security_group_id — the
#     module pre-wires NFS ingress from EKS worker nodes
#     to the mount-target SG so EFS CSI driver mounts work
#     out of the box.
#
# Both reads target the same S3 backend (var.remote_state_bucket)
# with use_path_style = true (LocalStack-compatible). The
# filesystem.tf / network.tf / mount_targets.tf files reference
# these outputs at the use site — no aliasing locals for plain
# passthroughs per ADR-0001 / CLAUDE.md.
#--------------------------------------------------------------

data "terraform_remote_state" "vpc" {
  backend = "s3"

  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}

data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}
