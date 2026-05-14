#--------------------------------------------------------------
# EKS Cluster
#--------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Managed log group. EKS will create one implicitly with no retention if
# the group does not pre-exist; managing it here pins retention and keeps
# the group under Terraform's lifecycle.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.cluster_log_retention_in_days
  tags              = var.tags
}

resource "aws_eks_cluster" "this" {
  name                      = var.name
  version                   = var.eks_version
  role_arn                  = aws_iam_role.cluster.arn
  enabled_cluster_log_types = var.enabled_cluster_log_types
  tags                      = var.tags

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  vpc_config {
    subnet_ids              = data.terraform_remote_state.vpc.outputs.private_subnet_ids
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = local.kms_key_arn
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.cluster,
    aws_iam_role_policy_attachment.cluster,
  ]
}
