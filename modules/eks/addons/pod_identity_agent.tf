#--------------------------------------------------------------
# eks-pod-identity-agent addon (ADR-0003)
#--------------------------------------------------------------
#
# The agent is the foundation every other addon in this module
# depends_on. It is installed FIRST, with no depends_on of its own,
# no IAM role, and no pod_identity_association block:
#
#   - No IAM role: the agent authenticates to the EKS Pod Identity
#     API using eks-auth:AssumeRoleForPodIdentity carried by the
#     node role's AmazonEKSWorkerNodePolicy (ADR-0002).
#   - No PIA block: the agent IS the PIA delivery mechanism — it
#     can't depend on itself.
#
# Every subsequent addon in this module (VPC CNI, kube-proxy,
# CoreDNS, EBS CSI, optional EFS CSI) names this resource in its
# depends_on list per DESIGN-0003 §Operational order.

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name  = data.terraform_remote_state.eks.outputs.cluster_name
  addon_name    = "eks-pod-identity-agent"
  addon_version = coalesce(var.pod_identity_agent_version, data.aws_eks_addon_version.pod_identity_agent.version)

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags
}
