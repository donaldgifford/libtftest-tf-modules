#--------------------------------------------------------------
# EBS CSI driver addon (ADR-0002, ADR-0004)
#--------------------------------------------------------------
#
# Mirror of vpc_cni.tf for the EBS CSI driver. AmazonEBSCSIDriver
# Policy re-homes off the node role onto a dedicated role assumed
# only by the ebs-csi-controller-sa service account in kube-system,
# delivered through the addon-managed pod_identity_association
# block per ADR-0004.

resource "aws_iam_role" "ebs_csi" {
  name               = local.ebs_csi_role_name
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name  = data.terraform_remote_state.eks.outputs.cluster_name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = var.ebs_csi_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = var.tags

  pod_identity_association {
    service_account = "ebs-csi-controller-sa"
    role_arn        = aws_iam_role.ebs_csi.arn
  }

  depends_on = [aws_eks_addon.pod_identity_agent]
}
