# Plan-only suite for modules/network/vpc-lookup.
#
# The module is data-source-only, so every lookup is mocked via
# mock_provider + override_data. These runs assert output wiring +
# shape without a live AWS/LocalStack backend. Real value assertions
# against a fixtured VPC live in tests-localstack/.
#
# Collection outputs are asserted by length + positional index (the
# lists are sorted, so index is order-stable) rather than whole-list
# `==` against a literal — an `list(string)` vs `tuple` comparison
# raises a spurious "different types" warning and fails.

mock_provider "aws" {}

variables {
  name = "platform-prod"
}

# All lookups resolve → every output is wired through correctly.
run "discovers_and_wires_all_outputs" {
  command = plan

  override_data {
    target = data.aws_vpc.this
    values = {
      id         = "vpc-0aaaa1111bbbb2222"
      cidr_block = "10.0.0.0/16"
    }
  }

  override_data {
    target = data.aws_subnets.private
    values = {
      ids = ["subnet-priv-a", "subnet-priv-b"]
    }
  }

  override_data {
    target = data.aws_subnets.public
    values = {
      ids = ["subnet-pub-a", "subnet-pub-b"]
    }
  }

  override_data {
    target = data.aws_subnets.private_eks
    values = {
      ids = ["subnet-eks-a", "subnet-eks-b", "subnet-eks-c"]
    }
  }

  override_data {
    target = data.aws_subnet.private["subnet-priv-a"]
    values = {
      availability_zone = "us-east-1a"
    }
  }

  override_data {
    target = data.aws_subnet.private["subnet-priv-b"]
    values = {
      availability_zone = "us-east-1b"
    }
  }

  override_data {
    target = data.aws_nat_gateways.this
    values = {
      ids = ["nat-0aaaa"]
    }
  }

  override_data {
    target = data.aws_route_tables.this
    values = {
      ids = ["rtb-0main", "rtb-0priv"]
    }
  }

  override_data {
    target = data.aws_internet_gateway.this[0]
    values = {
      id = "igw-0aaaa"
    }
  }

  assert {
    condition     = output.vpc_id == "vpc-0aaaa1111bbbb2222"
    error_message = "vpc_id must pass through data.aws_vpc.this.id"
  }

  assert {
    condition     = output.vpc_cidr_block == "10.0.0.0/16"
    error_message = "vpc_cidr_block must pass through the discovered VPC CIDR"
  }

  assert {
    condition     = length(output.private_subnet_ids) == 2 && output.private_subnet_ids[0] == "subnet-priv-a" && output.private_subnet_ids[1] == "subnet-priv-b"
    error_message = "private_subnet_ids must be the sorted private subnet IDs"
  }

  assert {
    condition     = length(output.public_subnet_ids) == 2 && output.public_subnet_ids[0] == "subnet-pub-a"
    error_message = "public_subnet_ids must be the sorted public subnet IDs"
  }

  assert {
    condition     = length(output.private_eks_subnet_ids) == 3 && output.private_eks_subnet_ids[0] == "subnet-eks-a"
    error_message = "private_eks_subnet_ids must be the sorted private EKS subnet IDs (distinct from private_subnet_ids)"
  }

  assert {
    condition     = length(output.availability_zones) == 2 && output.availability_zones[0] == "us-east-1a" && output.availability_zones[1] == "us-east-1b"
    error_message = "availability_zones must be the sorted distinct private-subnet AZs"
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 1 && output.nat_gateway_ids[0] == "nat-0aaaa"
    error_message = "nat_gateway_ids must pass through the NAT gateway IDs"
  }

  assert {
    condition     = length(output.route_table_ids) == 2 && output.route_table_ids[0] == "rtb-0main"
    error_message = "route_table_ids must be the sorted VPC route-table IDs"
  }

  assert {
    condition     = output.internet_gateway_id == "igw-0aaaa"
    error_message = "internet_gateway_id must pass through the attached IGW ID"
  }
}

# lookup_internet_gateway = false → the IGW data source is not read and
# internet_gateway_id collapses to null; empty public tier → empty list.
run "igw_lookup_disabled_and_no_public_subnets" {
  command = plan

  variables {
    lookup_internet_gateway = false
  }

  override_data {
    target = data.aws_vpc.this
    values = {
      id         = "vpc-0ccc"
      cidr_block = "10.1.0.0/16"
    }
  }

  override_data {
    target = data.aws_subnets.private
    values = {
      ids = ["subnet-x", "subnet-y"]
    }
  }

  override_data {
    target = data.aws_subnets.public
    values = {
      ids = []
    }
  }

  override_data {
    target = data.aws_subnets.private_eks
    values = {
      ids = ["subnet-eks-x"]
    }
  }

  override_data {
    target = data.aws_subnet.private["subnet-x"]
    values = {
      availability_zone = "us-east-1a"
    }
  }

  override_data {
    target = data.aws_subnet.private["subnet-y"]
    values = {
      availability_zone = "us-east-1b"
    }
  }

  override_data {
    target = data.aws_nat_gateways.this
    values = {
      ids = []
    }
  }

  override_data {
    target = data.aws_route_tables.this
    values = {
      ids = ["rtb-0main"]
    }
  }

  assert {
    condition     = output.internet_gateway_id == null
    error_message = "internet_gateway_id must be null when lookup_internet_gateway = false"
  }

  assert {
    condition     = length(output.public_subnet_ids) == 0
    error_message = "public_subnet_ids must be empty when no public subnets match"
  }
}
