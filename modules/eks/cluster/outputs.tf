#--------------------------------------------------------------
# Outputs (remote-state contract per ADR-0001)
#--------------------------------------------------------------
#
# Stable contract — downstream modules (managed-node-group, addons,
# pod-identity-access) read these via data.terraform_remote_state.eks.
# Renaming or removing one is a breaking change to every consumer.

output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_version" {
  description = "EKS cluster Kubernetes version. Consumed by the addons module for data.aws_eks_addon_version lookups; consumed by the managed-node-group module to choose a matching AL2023 AMI."
  value       = aws_eks_cluster.this.version
}

output "cluster_endpoint" {
  description = "EKS API server endpoint URL. Consumed by node group user data."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_data" {
  description = "Cluster CA certificate (base64). Consumed by node group user data and kubeconfig generation."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL. Escape hatch for third-party tooling that does not yet support Pod Identity (ADR-0002 keeps Pod Identity as the primary credential model)."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group ID. Useful to downstream stacks that need to peer with the cluster control plane."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_security_group_id" {
  description = "Shared node security group ID. Node group launch templates attach to this SG."
  value       = aws_security_group.nodes.id
}

output "kms_key_arn" {
  description = "KMS CMK ARN used for cluster secret envelope encryption. Non-null in both module-managed and external-key modes. Also exported for managed-node-group EBS encryption."
  value       = local.kms_key_arn
}
