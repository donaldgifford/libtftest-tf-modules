# Setup fixture for terraform test `apply_localstack.tftest.hcl`.
#
# The vpc-lookup module discovers an EXISTING VPC via data sources, so
# this fixture stands up the reference 3-tier topology for it to find:
#   - a VPC tagged Name = var.name (the module's default discovery key)
#   - 3 public subnets across 3 AZs — Network = "Public" +
#     kubernetes.io/role/elb = "1"
#   - 3 private (data-tier) subnets across 3 AZs — Network = "Private" +
#     kubernetes.io/role/internal-elb = "1"
#   - 3 private EKS subnets across 3 AZs — Network = "Private EKS"
#     (the internal cluster IP range)
#   - an internet gateway + one NAT gateway (with its EIP)
#
# Applied first (run "setup") so the module's data sources resolve.

terraform {
  required_version = ">= 1.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}

variable "name" {
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
    Name = var.name
  }
}

resource "aws_subnet" "public" {
  count = 3

  vpc_id            = aws_vpc.this.id
  availability_zone = "${var.region}${["a", "b", "c"][count.index]}"
  cidr_block        = "10.0.${count.index}.0/24"

  tags = {
    Name                     = "${var.name}-public-${count.index}"
    Network                  = "Public"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = 3

  vpc_id            = aws_vpc.this.id
  availability_zone = "${var.region}${["a", "b", "c"][count.index]}"
  cidr_block        = "10.0.${count.index + 10}.0/24"

  tags = {
    Name                              = "${var.name}-private-${count.index}"
    Network                           = "Private"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "private_eks" {
  count = 3

  vpc_id            = aws_vpc.this.id
  availability_zone = "${var.region}${["a", "b", "c"][count.index]}"
  cidr_block        = "10.0.${count.index + 20}.0/24"

  tags = {
    Name    = "${var.name}-private-eks-${count.index}"
    Network = "Private EKS"
  }
}

#--------------------------------------------------------------
# Gateways
#--------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = var.name
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name}-nat"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = var.name
  }

  depends_on = [aws_internet_gateway.this]
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

output "private_eks_subnet_ids" {
  value = aws_subnet.private_eks[*].id
}
