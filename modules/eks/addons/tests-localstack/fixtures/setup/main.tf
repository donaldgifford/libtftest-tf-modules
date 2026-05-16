# Setup fixture for terraform test `apply_localstack.tftest.hcl`.
#
# At apply time the addons module references AWS API resources via
# remote state (cluster_name + cluster_version) and applies six
# aws_eks_addon resources to a real EKS cluster.
#
# This fixture builds the minimum prerequisites:
#   1. VPC + 2 private subnets (aws_eks_cluster requires ≥ 2 AZs).
#   2. KMS key for control-plane envelope encryption.
#   3. Cluster IAM role + AmazonEKSClusterPolicy attachment.
#   4. Real aws_eks_cluster (LocalStack accepts this — verified by the
#      managed-node-group module's fixture).
#   5. S3 bucket holding the cluster's stub state file at the
#      <region>/eks/<cluster_name>/terraform.tfstate key the addons
#      module's data.terraform_remote_state.eks reads.

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
    Name = "tftest-addons-fixture-vpc"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = "${var.region}${["a", "b"][count.index]}"
  tags = {
    Name = "tftest-addons-fixture-private-${count.index}"
    Tier = "private"
  }
}

#--------------------------------------------------------------
# KMS key
#--------------------------------------------------------------

resource "aws_kms_key" "cluster" {
  description             = "tftest-addons-fixture cluster KMS key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

#--------------------------------------------------------------
# EKS cluster (real — addons require a real control plane)
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
  version  = "1.35"

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  vpc_config {
    subnet_ids = aws_subnet.private[*].id
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.cluster.arn
    }
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
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
    lineage           = "tftest-addons-fixture-stub-eks"
    outputs = {
      cluster_name = {
        value = aws_eks_cluster.this.name
        type  = "string"
      }
      cluster_version = {
        value = aws_eks_cluster.this.version
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

output "cluster_version" {
  value = aws_eks_cluster.this.version
}
