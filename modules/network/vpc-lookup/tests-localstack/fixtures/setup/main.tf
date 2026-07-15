# Setup fixture for terraform test `apply_localstack.tftest.hcl`.
#
# The vpc-lookup module discovers an EXISTING VPC via data sources, so
# this fixture stands up a realistic network for it to find:
#   - a VPC tagged Name = var.name (the module's default discovery key)
#   - 3 private subnets across 3 AZs, tagged Tier = "private"
#   - 2 public subnets across 2 AZs, tagged Tier = "public"
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

resource "aws_subnet" "private" {
  count = 3

  vpc_id            = aws_vpc.this.id
  availability_zone = "${var.region}${["a", "b", "c"][count.index]}"
  cidr_block        = "10.0.${count.index}.0/24"

  tags = {
    Name = "${var.name}-private-${count.index}"
    Tier = "private"
  }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id            = aws_vpc.this.id
  availability_zone = "${var.region}${["a", "b"][count.index]}"
  cidr_block        = "10.0.${count.index + 100}.0/24"

  tags = {
    Name = "${var.name}-public-${count.index}"
    Tier = "public"
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
