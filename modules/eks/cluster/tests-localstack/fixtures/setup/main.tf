# Setup fixture for terraform test `apply_localstack.tftest.hcl`.
#
# Creates the LocalStack-side fixtures the cluster module needs at
# apply time:
#   1. A real VPC + 2 private + 2 public subnets (aws_eks_cluster
#      validates that subnets exist).
#   2. An S3 bucket and a terraform.tfstate object at the key the
#      cluster's data.terraform_remote_state.vpc reads from
#      (<region>/vpc/<vpc_name>/terraform.tfstate). State file body
#      contains the real LocalStack-generated subnet IDs.
#
# This is the same seeding pattern libtftest uses in
# modules/eks/cluster/test/helpers_test.go — implemented in HCL here.
# It's a real data point for RFC-0001's gap-discovery framing:
# terraform test's override_data shortcut can't reference run.* outputs,
# so apply-mode cross-run fixturing falls back to actually writing the
# state file, which is what libtftest does.

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

resource "aws_s3_bucket" "state" {
  bucket        = var.remote_state_bucket
  force_destroy = true
}

# Stub terraform state file matching v4 schema. The cluster module reads
# only `outputs.vpc_id`, `outputs.private_subnet_ids`, and
# `outputs.public_subnet_ids` — those are all that need to be populated.
resource "aws_s3_object" "vpc_state" {
  bucket       = aws_s3_bucket.state.id
  key          = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
  content_type = "application/json"

  content = jsonencode({
    version           = 4
    terraform_version = "1.14.7"
    serial            = 1
    lineage           = "tftest-fixture-stub"
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

output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}
