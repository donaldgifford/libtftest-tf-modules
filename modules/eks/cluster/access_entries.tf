#--------------------------------------------------------------
# EKS Access Entries (SSO)
#--------------------------------------------------------------
#
# Resolves the SSO permission-set role (AWSReservedSSO_<name>_*) and
# wires it to the cluster as an Access Entry. Gated on
# var.sso_access_enabled. Requires the cluster's authentication_mode to
# include "API" — set to API_AND_CONFIG_MAP in main.tf.

data "aws_iam_roles" "sso" {
  count = var.sso_access_enabled ? 1 : 0

  name_regex = "AWSReservedSSO_${var.sso_role_name}_.*"
}

resource "aws_eks_access_entry" "sso" {
  count = var.sso_access_enabled ? 1 : 0

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = one(data.aws_iam_roles.sso[0].arns)
  kubernetes_groups = var.sso_eks_access_entry.kubernetes_groups
  user_name         = var.sso_eks_access_entry.user_name
  type              = var.sso_eks_access_entry.type
  tags              = var.tags
}

resource "aws_eks_access_policy_association" "sso" {
  count = var.sso_access_enabled ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = one(data.aws_iam_roles.sso[0].arns)
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/${var.sso_cluster_policy}"

  access_scope {
    type = var.sso_cluster_policy_access_scope
  }
}
