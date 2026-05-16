#--------------------------------------------------------------
# EFS CSI driver addon — gated on var.efs_csi_enabled
#--------------------------------------------------------------
#
# Off by default — most clusters don't need EFS-backed PVs. When
# enabled, mirrors the EBS CSI shape: dedicated Pod Identity role
# carrying AmazonEFSCSIDriverPolicy, attached to the efs-csi-
# controller-sa service account, depends_on the agent.

resource "aws_iam_role" "efs_csi" {
  count = var.efs_csi_enabled ? 1 : 0

  name               = local.efs_csi_role_name
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  count = var.efs_csi_enabled ? 1 : 0

  role       = aws_iam_role.efs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_eks_addon" "efs_csi_driver" {
  count = var.efs_csi_enabled ? 1 : 0

  cluster_name  = data.terraform_remote_state.eks.outputs.cluster_name
  addon_name    = "aws-efs-csi-driver"
  addon_version = coalesce(var.efs_csi_version, data.aws_eks_addon_version.efs_csi[0].version)

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags

  pod_identity_association {
    service_account = "efs-csi-controller-sa"
    role_arn        = aws_iam_role.efs_csi[0].arn
  }

  depends_on = [aws_eks_addon.pod_identity_agent]
}
