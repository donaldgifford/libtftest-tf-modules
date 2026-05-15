# Setup fixture for terraform test `apply_localstack.tftest.hcl`.
#
# At apply time the managed-node-group module references real AWS API
# resources via remote state:
#   - aws_eks_node_group requires a real EKS cluster.
#   - aws_launch_template references a real node security group ID +
#     KMS key ARN from the cluster module's stubbed state.
#
# This fixture builds everything in one apply:
#   1. VPC + 2 private + 2 public subnets.
#   2. KMS key (for EBS envelope encryption).
#   3. Cluster IAM role + AmazonEKSClusterPolicy attachment.
#   4. Minimal aws_eks_cluster (control plane that AWS will accept).
#   5. Node security group.
#   6. S3 bucket holding two state files: the VPC stack's and the
#      cluster module's, at the key conventions the managed-node-group
#      module reads from.

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

variable "vpc_name" {
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
    Name = "tftest-fixture-vpc"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = "${var.region}${["a", "b"][count.index]}"
  tags = {
    Name = "tftest-fixture-private-${count.index}"
    Tier = "private"
  }
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = "${var.region}${["a", "b"][count.index]}"
  tags = {
    Name = "tftest-fixture-public-${count.index}"
    Tier = "public"
  }
}

#--------------------------------------------------------------
# KMS key (cluster module produces this; mirror for the fixture)
#--------------------------------------------------------------

resource "aws_kms_key" "cluster" {
  description             = "tftest-fixture cluster KMS key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

#--------------------------------------------------------------
# EKS cluster (real — node group requires a real control plane)
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

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.cluster.arn
    }
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

#--------------------------------------------------------------
# Node security group (cluster module produces this; mirror)
#--------------------------------------------------------------

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes"
  description = "tftest-fixture shared node SG"
  vpc_id      = aws_vpc.this.id
}

#--------------------------------------------------------------
# S3 bucket + stub state files
#--------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket        = var.remote_state_bucket
  force_destroy = true
}

resource "aws_s3_object" "vpc_state" {
  bucket       = aws_s3_bucket.state.id
  key          = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
  content_type = "application/json"

  content = jsonencode({
    version           = 4
    terraform_version = "1.14.7"
    serial            = 1
    lineage           = "tftest-fixture-stub-vpc"
    outputs = {
      vpc_id = {
        value = aws_vpc.this.id
        type  = "string"
      }
      private_subnet_ids = {
        value = aws_subnet.private[*].id
        type  = ["list", "string"]
      }
      public_subnet_ids = {
        value = aws_subnet.public[*].id
        type  = ["list", "string"]
      }
    }
    resources = []
  })
}

resource "aws_s3_object" "eks_state" {
  bucket       = aws_s3_bucket.state.id
  key          = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
  content_type = "application/json"

  content = jsonencode({
    version           = 4
    terraform_version = "1.14.7"
    serial            = 1
    lineage           = "tftest-fixture-stub-eks"
    outputs = {
      cluster_name = {
        value = aws_eks_cluster.this.name
        type  = "string"
      }
      cluster_version = {
        value = aws_eks_cluster.this.version
        type  = "string"
      }
      cluster_endpoint = {
        value = aws_eks_cluster.this.endpoint
        type  = "string"
      }
      cluster_ca_data = {
        value = aws_eks_cluster.this.certificate_authority[0].data
        type  = "string"
      }
      cluster_oidc_issuer_url = {
        value = aws_eks_cluster.this.identity[0].oidc[0].issuer
        type  = "string"
      }
      cluster_security_group_id = {
        value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
        type  = "string"
      }
      node_security_group_id = {
        value = aws_security_group.nodes.id
        type  = "string"
      }
      kms_key_arn = {
        value = aws_kms_key.cluster.arn
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
