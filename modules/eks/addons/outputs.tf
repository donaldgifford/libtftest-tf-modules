#--------------------------------------------------------------
# Outputs (consumer contract)
#--------------------------------------------------------------

output "pod_identity_agent_addon_arn" {
  description = "ARN of the eks-pod-identity-agent addon. Foundation every other addon in this module depends_on per ADR-0003."
  value       = aws_eks_addon.pod_identity_agent.arn
}

output "pod_identity_agent_addon_id" {
  description = "ID of the eks-pod-identity-agent addon."
  value       = aws_eks_addon.pod_identity_agent.id
}

output "vpc_cni_role_arn" {
  description = "ARN of the VPC CNI Pod Identity role (assumed by aws-node in kube-system)."
  value       = aws_iam_role.vpc_cni.arn
}

output "ebs_csi_role_arn" {
  description = "ARN of the EBS CSI Pod Identity role (assumed by ebs-csi-controller-sa in kube-system)."
  value       = aws_iam_role.ebs_csi.arn
}

output "efs_csi_role_arn" {
  description = "ARN of the EFS CSI Pod Identity role. null when var.efs_csi_enabled is false."
  value       = var.efs_csi_enabled ? aws_iam_role.efs_csi[0].arn : null
}

output "addon_versions" {
  description = "Resolved addon versions, keyed by addon_name. Useful for drift detection in downstream observability."
  value = {
    eks-pod-identity-agent = aws_eks_addon.pod_identity_agent.addon_version
    vpc-cni                = aws_eks_addon.vpc_cni.addon_version
    kube-proxy             = aws_eks_addon.kube_proxy.addon_version
    coredns                = aws_eks_addon.coredns.addon_version
    aws-ebs-csi-driver     = aws_eks_addon.ebs_csi_driver.addon_version
    aws-efs-csi-driver     = var.efs_csi_enabled ? aws_eks_addon.efs_csi_driver[0].addon_version : null
  }
}
