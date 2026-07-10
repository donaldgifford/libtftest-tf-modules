# Setup fixture for the Pro apply suite `apply_pro.tftest.hcl`.
#
# The cluster module reads vpc_id + private_subnet_ids from a
# remote-state file in S3 (data.terraform_remote_state.vpc per
# IMPL-0007 Q1). This fixture builds:
#   1. A VPC + 3 private subnets in three AZs (Aurora requires
#      subnets in at least 2 AZs for the db subnet group).
#   2. An S3 bucket holding the stub VPC state file at the key
#      <region>/vpc/<vpc_name>/terraform.tfstate, with outputs
#      shaped to match the EKS-cluster remote-state contract.
#
# Apply this fixture before the module's apply_default run.

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

variable "region" {
  type = string
}

#--------------------------------------------------------------
# VPC + private subnets
#--------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "tftest-rds-cluster-vpc"
  }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = "${var.region}${["a", "b", "c"][count.index]}"
  tags = {
    Name = "tftest-rds-cluster-private-${count.index}"
    Tier = "private"
  }
}

#--------------------------------------------------------------
# S3 bucket + stub VPC state file
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
    lineage           = "tftest-rds-cluster-stub-vpc"
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

output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
