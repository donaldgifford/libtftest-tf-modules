#--------------------------------------------------------------
# test/fixtures/reference-vpc
#
# Shared LocalStack test fixture: a vpc-lookup-faithful reference
# VPC (three-tier Network-tagged topology) plus the full nine-output
# remote-state contract, seeded into S3 at the key downstream module
# tests read (<region>/vpc/<vpc_name>/terraform.tfstate).
#
# Consumer module tests source this instead of hand-rolling a
# Tier-tagged, two-output stub (DESIGN-0016 / IMPL-0014). It maps to
# what modules/network/vpc-lookup publishes WITHOUT instantiating the
# producer — each seeded output is computed from this fixture's own
# resources.
#--------------------------------------------------------------

locals {
  azs = [for letter in var.az_letters : "${var.region}${letter}"]
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  tags = {
    Name = var.vpc_name
  }
}

#--------------------------------------------------------------
# Subnets — three tiers x N AZs, discriminated by the Network tag.
# The kubernetes.io/role/* tags are passive (LB-controller
# auto-discovery), matching vpc-lookup's reference topology.
#--------------------------------------------------------------

resource "aws_subnet" "public" {
  count = length(var.az_letters)

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)

  tags = {
    Name                     = "${var.vpc_name}-public-${count.index}"
    Network                  = "Public"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = length(var.az_letters)

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)

  tags = {
    Name                              = "${var.vpc_name}-private-${count.index}"
    Network                           = "Private"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "private_eks" {
  count = length(var.az_letters)

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 20)

  tags = {
    Name    = "${var.vpc_name}-private-eks-${count.index}"
    Network = "Private EKS"
  }
}

#--------------------------------------------------------------
# Gateways + routing, so the nat_gateway_ids / route_table_ids /
# internet_gateway_id outputs are backed by real resources.
#--------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = var.vpc_name
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.vpc_name}-nat"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = var.vpc_name
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.vpc_name}-public"
  }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.vpc_name}-private"
  }

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
}

resource "aws_route_table_association" "public" {
  count = length(var.az_letters)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = length(var.az_letters)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_eks" {
  count = length(var.az_letters)

  subnet_id      = aws_subnet.private_eks[count.index].id
  route_table_id = aws_route_table.private.id
}

#--------------------------------------------------------------
# S3 bucket + the seeded VPC remote state (full nine-output
# contract) at the key downstream module tests read. Values are
# computed from the resources above — a faithful mirror of what
# vpc-lookup would publish for this topology.
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
    lineage           = "reference-vpc-stub"
    outputs = {
      vpc_id = {
        value = aws_vpc.this.id
        type  = "string"
      }
      private_subnet_ids = {
        value = aws_subnet.private[*].id
        type  = ["list", "string"]
      }
      private_eks_subnet_ids = {
        value = aws_subnet.private_eks[*].id
        type  = ["list", "string"]
      }
      public_subnet_ids = {
        value = aws_subnet.public[*].id
        type  = ["list", "string"]
      }
      vpc_cidr_block = {
        value = aws_vpc.this.cidr_block
        type  = "string"
      }
      availability_zones = {
        value = local.azs
        type  = ["list", "string"]
      }
      nat_gateway_ids = {
        value = [aws_nat_gateway.this.id]
        type  = ["list", "string"]
      }
      route_table_ids = {
        value = [aws_route_table.public.id, aws_route_table.private.id]
        type  = ["list", "string"]
      }
      internet_gateway_id = {
        value = aws_internet_gateway.this.id
        type  = "string"
      }
    }
    resources = []
  })
}
