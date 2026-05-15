#--------------------------------------------------------------
# Node IAM role — minimal per ADR-0002 + opt-in ADR-0012 / ADR-0015
#--------------------------------------------------------------
#
# End state: exactly two managed-policy attachments by default
# (AmazonEKSWorkerNodePolicy + AmazonEC2ContainerRegistryPullOnly),
# zero inline policies. var.enable_ssm adds AmazonSSMManagedInstanceCore
# (ADR-0012). var.extra_node_policies attaches one customer-managed
# pull-through cache policy when wired by the consumer's Terragrunt
# config (ADR-0015, two-stages-of-consent opt-in).
#
# CNI / EBS CSI / EFS CSI / CW Agent / GuardDuty / workload controller
# policies are deliberately NOT attached here — they move to Pod
# Identity Associations on workload service accounts per ADR-0002.

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.nodegroup_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "worker_node" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_pull_only" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

# SSM Session Manager break-glass — opt-in per ADR-0012. Off by default.
resource "aws_iam_role_policy_attachment" "ssm" {
  count = var.enable_ssm ? 1 : 0

  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Opt-in additional policies per ADR-0015 — currently scoped to the
# ECR pull-through cache module's emitted node_pull_through_policy_arn.
# Default var.extra_node_policies = [] means zero extra attachments;
# consumers' Terragrunt configs wire specific ARNs to opt in.
resource "aws_iam_role_policy_attachment" "extra" {
  for_each = toset(var.extra_node_policies)

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.nodegroup_name}-node"
  role = aws_iam_role.node.name
  tags = var.tags
}
