# Setup fixture for terraform test `apply_localstack.tftest.hcl`.
#
# At apply time the pod-identity-access module references AWS API
# resources via remote state (cluster_name) and applies an
# aws_eks_pod_identity_association to a real EKS cluster.
#
# This fixture builds the minimum prerequisites:
#   1. VPC + 2 private subnets (aws_eks_cluster requires ≥ 2 AZs).
#   2. Cluster IAM role + AmazonEKSClusterPolicy attachment.
#   3. Real aws_eks_cluster (LocalStack accepts this — verified by
#      the addons + managed-node-group module fixtures).
#   4. A pre-existing Pod-Identity-trusting IAM role (for the Mode B
#      apply run, whose existing_role_arn input points at this).
#   5. S3 bucket holding the cluster's stub state file at the
#      <region>/eks/<cluster_name>/terraform.tfstate key the module's
#      data.terraform_remote_state.eks reads.

terraform {
  required_version = ">= 1.1"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}

variable "remote_state_bucket" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "region" {
  type = string
}

#--------------------------------------------------------------
# VPC + subnets
#--------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "tftest-pia-fixture-vpc"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = "${var.region}${["a", "b"][count.index]}"
  tags = {
    Name = "tftest-pia-fixture-private-${count.index}"
    Tier = "private"
  }
}

#--------------------------------------------------------------
# EKS cluster
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
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  vpc_config {
    subnet_ids = aws_subnet.private[*].id
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

#--------------------------------------------------------------
# Pre-existing Pod-Identity-trusting role (for Mode B apply run)
#--------------------------------------------------------------

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

resource "aws_iam_role" "preexisting" {
  name               = "${var.cluster_name}-preexisting-pia-role"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

#--------------------------------------------------------------
# S3 bucket + stub EKS state
#--------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket        = var.remote_state_bucket
  force_destroy = true
}

resource "aws_s3_object" "eks_state" {
  bucket       = aws_s3_bucket.state.id
  key          = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
  content_type = "application/json"

  content = jsonencode({
    version           = 4
    terraform_version = "1.14.7"
    serial            = 1
    lineage           = "tftest-pia-fixture-stub-eks"
    outputs = {
      cluster_name = {
        value = aws_eks_cluster.this.name
        type  = "string"
      }
    }
    resources = []
  })
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "preexisting_role_arn" {
  value = aws_iam_role.preexisting.arn
}
