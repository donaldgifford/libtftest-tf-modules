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

variable "account_name" {
  description = "Terragrunt account name — the <account_name> prefix of the account-scoped VPC state key the cluster module reads (IMPL-0015)."
  type        = string
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

#--------------------------------------------------------------
# Managed prefix lists for the endpoint fence (DESIGN-0024 part 2)
#--------------------------------------------------------------

# The corp egress list. The module expands this at PLAN time through
# data.aws_ec2_managed_prefix_list, so the apply suite can prove the
# expansion against a real EC2 prefix list rather than an override_data
# stub — including whether LocalStack populates `entries` at all.
#
# One entry deliberately duplicates a CIDR the suite also passes
# literally, so the union's de-duplication is proven end to end.
resource "aws_ec2_managed_prefix_list" "corp" {
  name           = "tftest-fixture-corp-egress"
  address_family = "IPv4"
  max_entries    = 5

  entry {
    cidr        = "192.0.2.0/24"
    description = "corp egress a"
  }

  entry {
    cidr        = "198.51.100.0/24"
    description = "corp egress b — also passed literally by the suite"
  }
}

# An EMPTY prefix list: max_entries is required, but no entries exist.
# This is the live shape of the fence-expands-to-nothing hazard — a list
# emptied out-of-band, or simply not populated yet. The module must fail
# the plan rather than fall through to 0.0.0.0/0.
resource "aws_ec2_managed_prefix_list" "empty" {
  name           = "tftest-fixture-empty"
  address_family = "IPv4"
  max_entries    = 1
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
  key          = "${var.account_name}/${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
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

output "corp_prefix_list_id" {
  value = aws_ec2_managed_prefix_list.corp.id
}

output "empty_prefix_list_id" {
  value = aws_ec2_managed_prefix_list.empty.id
}
