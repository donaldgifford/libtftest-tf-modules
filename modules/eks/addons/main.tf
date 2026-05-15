#--------------------------------------------------------------
# Addons Module — entrypoint
#--------------------------------------------------------------
#
# Installs the five mandatory EKS managed addons + optional EFS
# CSI per DESIGN-0003. The eks-pod-identity-agent addon is
# installed FIRST per ADR-0003 (in pod_identity_agent.tf); every
# other addon explicitly depends_on it.
#
# AWS-credentialed addons (VPC CNI, EBS CSI, optional EFS CSI)
# use the addon-managed pod_identity_association block per
# ADR-0004 — the PIA lifecycle is tied to the addon, not a
# separate resource.
#
# kube-proxy and CoreDNS operate against the Kubernetes API only
# and need no AWS credentials, but still depends_on the agent to
# keep the dependency graph regular per DESIGN-0003.

resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = data.terraform_remote_state.eks.outputs.cluster_name
  addon_name    = "kube-proxy"
  addon_version = var.kube_proxy_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags

  depends_on = [aws_eks_addon.pod_identity_agent]
}

resource "aws_eks_addon" "coredns" {
  cluster_name         = data.terraform_remote_state.eks.outputs.cluster_name
  addon_name           = "coredns"
  addon_version        = var.coredns_version
  configuration_values = var.coredns_configuration_values

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags

  depends_on = [aws_eks_addon.pod_identity_agent]
}
