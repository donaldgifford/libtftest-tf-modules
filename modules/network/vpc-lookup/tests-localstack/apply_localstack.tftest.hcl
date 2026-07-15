# Apply against LocalStack — real discovery of a fixtured VPC.
#
# The vpc-lookup module is data-source-only and Community-safe (pure
# EC2/VPC API, no Pro tier). This suite:
#   1. run "setup"        — stands up a tagged VPC + subnets + gateways.
#   2. run "discover_by_tag" — applies the module with tag-based
#      discovery (vpc_id = null) and asserts the outputs match the
#      fixture.
#   3. run "discover_by_id"  — applies the module pinned to the
#      fixture's explicit vpc_id.
#
# Required env vars (the `just tf test-localstack` recipe wires these):
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = "http://localhost:4566"
    sts = "http://localhost:4566"
  }
}

variables {
  name   = "tftest-vpc-lookup"
  region = "us-east-1"
}

# Stand up the VPC the module will discover.
run "setup" {
  command = apply

  variables {
    name   = var.name
    region = var.region
  }

  module {
    source = "./tests-localstack/fixtures/setup"
  }
}

# Tag-based discovery (default path): find the VPC by tag:Name = var.name.
run "discover_by_tag" {
  command = apply

  assert {
    condition     = output.vpc_id == run.setup.vpc_id
    error_message = "Discovered vpc_id must match the fixture's VPC"
  }

  assert {
    condition     = output.vpc_cidr_block == "10.0.0.0/16"
    error_message = "vpc_cidr_block must be the fixture VPC CIDR"
  }

  assert {
    condition     = length(output.private_subnet_ids) == 3
    error_message = "Must discover all 3 private (Tier=private) subnets"
  }

  assert {
    condition     = length(output.availability_zones) == 3
    error_message = "Private subnets must span 3 distinct AZs"
  }

  assert {
    condition     = length(output.public_subnet_ids) == 2
    error_message = "Must discover both public (Tier=public) subnets"
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 1
    error_message = "Must discover the fixture's single NAT gateway"
  }

  assert {
    condition     = output.internet_gateway_id != null && startswith(output.internet_gateway_id, "igw-")
    error_message = "Must discover the attached internet gateway"
  }

  assert {
    condition     = length(output.route_table_ids) >= 1
    error_message = "Must discover at least the VPC main route table"
  }
}

# Explicit-ID discovery: pin the VPC by ID instead of tag lookup.
run "discover_by_id" {
  command = apply

  variables {
    vpc_id = run.setup.vpc_id
  }

  assert {
    condition     = output.vpc_id == run.setup.vpc_id
    error_message = "Explicit vpc_id path must resolve the same VPC"
  }

  assert {
    condition     = length(output.private_subnet_ids) == 3
    error_message = "Explicit-ID path must still discover all 3 private subnets"
  }
}
