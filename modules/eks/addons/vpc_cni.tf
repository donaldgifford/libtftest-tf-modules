#--------------------------------------------------------------
# VPC CNI addon (ADR-0002, ADR-0004)
#--------------------------------------------------------------
#
# First instance of the per-addon Pod Identity role pattern:
# AmazonEKS_CNI_Policy re-homes off the node role onto a
# dedicated role assumed only by the aws-node service account
# in kube-system, delivered through aws_eks_addon's
# pod_identity_association block (ADR-0004).
#
# depends_on the pod_identity_agent — the PIA registration is
# meaningless until the agent is running.

resource "aws_iam_role" "vpc_cni" {
  name               = local.vpc_cni_role_name
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name         = data.terraform_remote_state.eks.outputs.cluster_name
  addon_name           = "vpc-cni"
  addon_version        = coalesce(var.vpc_cni_version, data.aws_eks_addon_version.vpc_cni.version)
  configuration_values = var.vpc_cni_configuration_values

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags

  pod_identity_association {
    service_account = "aws-node"
    role_arn        = aws_iam_role.vpc_cni.arn
  }

  depends_on = [aws_eks_addon.pod_identity_agent]
}
