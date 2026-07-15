#--------------------------------------------------------------
# modules/network/vpc-lookup
#
# Read-only discovery of an EXISTING VPC and its subnets, gateways,
# and route tables. This module manages no AWS resources — it looks
# the network up via data sources and re-publishes the downstream
# remote-state contract (vpc_id + private_subnet_ids) plus additive
# network facts, so the RDS / EKS / EFS modules can consume a VPC that
# Terraform does not own.
#
# Stand-in for the create-or-adopt modules/network/vpc (INV-0004): it
# exercises the remote-state consumption contract before the full VPC
# module lands, and permanently serves environments where Terraform
# must never own the network.
#--------------------------------------------------------------

data "aws_vpc" "this" {
  id   = var.vpc_id
  tags = local.vpc_lookup_tags
}

data "aws_subnets" "private" {
  tags = var.private_subnet_tags

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
}

data "aws_subnets" "public" {
  tags = var.public_subnet_tags

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
}

# The private EKS tier — the internal cluster IP range, a distinct set
# of subnets from the data-tier private subnets above.
data "aws_subnets" "private_eks" {
  tags = var.private_eks_subnet_tags

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
}

# Per-subnet detail (availability_zone) for the private subnets — the
# aws_subnets plural data source returns IDs only.
data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)

  id = each.value
}

data "aws_nat_gateways" "this" {
  vpc_id = data.aws_vpc.this.id
}

data "aws_route_tables" "this" {
  vpc_id = data.aws_vpc.this.id
}

data "aws_internet_gateway" "this" {
  count = var.lookup_internet_gateway ? 1 : 0

  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.this.id]
  }
}
