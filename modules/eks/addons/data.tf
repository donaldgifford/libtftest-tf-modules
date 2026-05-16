#--------------------------------------------------------------
# Data sources
#--------------------------------------------------------------
#
# Cross-module composition per ADR-0001: the cluster state file
# is the last-known-good ground truth for cluster_name, K8s
# version, and OIDC issuer. Read at the use site rather than
# re-aliased through locals.
#
# use_path_style = true keeps S3 addressing as bucket-in-path
# so the data source works against any S3 endpoint (production,
# LocalStack, etc.) without virtual-host DNS dependence.

data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}

#--------------------------------------------------------------
# Addon-version data sources (IMPL-0003 Q3)
#--------------------------------------------------------------
#
# Per addon: if var.<name>_version is non-null, the literal pin
# wins; if null, the addon resource consumes the latest version
# AWS publishes as compatible with the cluster's K8s version.
# Each addon's addon_version is set via
# coalesce(var, data.<>.version) at the use site.
#
# most_recent = true makes the data source pick the latest
# release rather than the oldest. The "compatible with K8s
# version X" filter is what cluster_version (from remote state)
# applies.

data "aws_eks_addon_version" "pod_identity_agent" {
  addon_name         = "eks-pod-identity-agent"
  kubernetes_version = data.terraform_remote_state.eks.outputs.cluster_version
  most_recent        = true
}

data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = data.terraform_remote_state.eks.outputs.cluster_version
  most_recent        = true
}

data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = data.terraform_remote_state.eks.outputs.cluster_version
  most_recent        = true
}

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = data.terraform_remote_state.eks.outputs.cluster_version
  most_recent        = true
}

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = data.terraform_remote_state.eks.outputs.cluster_version
  most_recent        = true
}

data "aws_eks_addon_version" "efs_csi" {
  count = var.efs_csi_enabled ? 1 : 0

  addon_name         = "aws-efs-csi-driver"
  kubernetes_version = data.terraform_remote_state.eks.outputs.cluster_version
  most_recent        = true
}
