# Setup fixture for terraform test `apply_localstack.tftest.hcl`.
#
# The EFS filesystem module reads TWO remote states per DESIGN-0008 Q1:
#
#   * VPC state for vpc_id + private_subnet_ids.
#   * EKS state for node_security_group_id.
#
# Per IMPL-0008 Q8, the fixture does NOT provision a real
# aws_eks_cluster — it just creates a standalone
# aws_security_group.node_stub whose ID is stubbed into the EKS state
# file as node_security_group_id. The EFS module only needs the SG ID
# (to gate NFS ingress from the node SG), not the cluster control
# plane — and skipping the cluster sidesteps LocalStack EKS API edge
# cases.
#
# Two stub state files land in S3:
#
#   <region>/vpc/<vpc_name>/terraform.tfstate
#     outputs: vpc_id + private_subnet_ids
#
#   <region>/eks/<cluster_name>/terraform.tfstate
#     outputs: node_security_group_id

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
# VPC + private subnets (3 AZs)
#--------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "tftest-efs-filesystem-vpc"
  }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = "${var.region}${["a", "b", "c"][count.index]}"
  tags = {
    Name = "tftest-efs-filesystem-private-${count.index}"
    Tier = "private"
  }
}

#--------------------------------------------------------------
# Standalone node-SG stub (no real EKS cluster per IMPL-0008 Q8)
#--------------------------------------------------------------

resource "aws_security_group" "node_stub" {
  name        = "tftest-efs-node-stub"
  description = "Stub EKS node SG for tests-localstack fixture (no real EKS cluster)"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "tftest-efs-node-stub"
  }
}

#--------------------------------------------------------------
# S3 bucket + two stub state files (VPC + EKS)
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
    lineage           = "tftest-efs-filesystem-stub-vpc"
    outputs = {
      vpc_id = {
        value = aws_vpc.this.id
        type  = "string"
      }
      private_subnet_ids = {
        value = aws_subnet.private[*].id
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
    lineage           = "tftest-efs-filesystem-stub-eks"
    outputs = {
      node_security_group_id = {
        value = aws_security_group.node_stub.id
        type  = "string"
      }
    }
    resources = []
  })
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "node_security_group_id" {
  value = aws_security_group.node_stub.id
}
