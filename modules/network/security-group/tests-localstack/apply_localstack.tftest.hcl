# Real apply against LocalStack — Community tier (IMPL-0023 Phase 3).
#
# Pure EC2 + STS + S3 (the latter only for the fixture's seeded remote
# state), so this needs NO Pro tier, NO auth token and NO named volume —
# the network/vpc-lookup precedent. The Community tier stays tokenless
# by policy; never wire LOCALSTACK_AUTH_TOKEN into this suite.
#
# Required env vars (the `just tf test-localstack` recipe wires these):
#
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1
#
# What this suite is FOR: proving each of the four source types
# round-trips through a real EC2 API, not re-testing composition. The
# plan suite owns composition; this one owns "the emulator accepted it
# and served it back."

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = "http://localhost:4566"
    s3  = "http://s3.localhost.localstack.cloud:4566"
    sts = "http://localhost:4566"
  }
}

# Declarations for the Terragrunt globals referenced via var.* in the
# setup run. Values come from the shared var-file via the recipe.
variable "region" {
  type = string
}

variable "remote_state_bucket" {
  type = string
}

variable "remote_state_bucket_region" {
  type = string
}

variable "account_name" {
  type = string
}

variable "vpc_name" {
  type    = string
  default = "libtftest-vpc"
}

run "setup" {
  command = apply

  variables {
    remote_state_bucket        = var.remote_state_bucket
    remote_state_bucket_region = var.remote_state_bucket_region
    vpc_name                   = var.vpc_name
    account_name               = var.account_name
    region                     = var.region
  }

  module {
    source = "./tests-localstack/fixtures/setup"
  }
}

run "apply_security_group_with_all_source_types" {
  command = apply

  variables {
    name     = "gateway-frontend-public"
    vpc_name = var.vpc_name

    ingress_rules = {
      # The live prefix-list reference, pointed at the fixture's
      # POPULATED list. This is the run that answers whether token-free
      # 4.4 serves managed prefix lists at all.
      corp-prefix = {
        description    = "Corp egress ranges via managed prefix list"
        from_port      = 443
        prefix_list_id = run.setup.prefix_list_id
      }
      corp-cidr = {
        description = "A literal corp range"
        from_port   = 443
        cidr_ipv4   = "203.0.113.0/24"
      }
      corp-cidr-v6 = {
        description = "A literal corp IPv6 range"
        from_port   = 443
        cidr_ipv6   = "2001:db8::/32"
      }
      peer-mesh = {
        description                  = "All protocols from the peer SG"
        ip_protocol                  = "-1"
        referenced_security_group_id = run.setup.peer_security_group_id
      }
      port-range = {
        description = "NodePort range, to exercise an explicit to_port"
        from_port   = 30000
        to_port     = 32767
        cidr_ipv4   = "203.0.113.0/24"
      }
    }

    tags = { ManagedBy = "terraform", Component = "gateway" }
  }

  # The SG landed in the CONTRACT VPC — i.e. the remote-state read
  # resolved through the account-scoped key and the assume_role, against
  # a real S3 object the fixture seeded. That is the end-to-end proof
  # the plan suite's override_data stub cannot give.
  assert {
    condition     = aws_security_group.this.vpc_id == run.setup.vpc_id
    error_message = "the SG must be created in the VPC the remote-state contract names"
  }

  # The provider-generated suffix is real: name_prefix produced a
  # physical name longer than the prefix itself.
  assert {
    condition     = startswith(aws_security_group.this.name, "gateway-frontend-public-") && length(aws_security_group.this.name) > length("gateway-frontend-public-")
    error_message = "name_prefix must yield a suffixed physical name from the real API"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 5
    error_message = "all five ingress rules must apply"
  }

  # Every rule got a real sgr-... id back from EC2. The provider cannot
  # fabricate these, so this is the strongest single signal the rules
  # actually landed rather than merely planning.
  assert {
    condition = alltrue([
      for id in values(output.ingress_rule_ids) : startswith(id, "sgr-")
    ])
    error_message = "every ingress rule must come back with a real sgr-... id from EC2"
  }

  assert {
    condition     = startswith(output.all_egress_rule_id, "sgr-")
    error_message = "the all-egress rule must apply and return a real sgr-... id"
  }

  assert {
    condition     = startswith(output.security_group_id, "sg-")
    error_message = "security_group_id must be a real sg-... id"
  }
}

# READ-BACK through data sources in a separate fixture — an independent
# check of what the API serves, rather than of what the provider
# recorded in state.
run "verify_readback" {
  command = apply

  variables {
    security_group_id   = run.apply_security_group_with_all_source_types.security_group_id
    vpc_id              = run.setup.vpc_id
    prefix_list_rule_id = run.apply_security_group_with_all_source_types.ingress_rule_ids["corp-prefix"]
  }

  module {
    source = "./tests-localstack/fixtures/verify"
  }

  assert {
    condition     = output.vpc_id == run.setup.vpc_id
    error_message = "reading the SG back must show it in the contract VPC"
  }

  # THE LIVE-REFERENCE PROOF. The module's headline behavior is that a
  # prefix-list rule references the list rather than expanding it, so
  # what has to survive the apply is the prefix list ID itself. The
  # earlier run asserts the rule got an sgr-... id, which would pass
  # even if the list id had been dropped on the way in.
  assert {
    condition     = output.prefix_list_rule_prefix_list_id == run.setup.prefix_list_id
    error_message = "the prefix-list rule must read back carrying the prefix list id — the live reference, not an expansion"
  }

  assert {
    condition     = output.prefix_list_rule_description == "Corp egress ranges via managed prefix list"
    error_message = "the per-rule description must survive a real apply — it is the audit surface the guard exists for"
  }

  assert {
    condition     = output.description == "Managed by Terraform - gateway-frontend-public"
    error_message = "the composed description must survive a real apply and read back"
  }

  assert {
    condition     = output.name_tag == "gateway-frontend-public"
    error_message = "the friendly Name tag must read back"
  }
}

# The restricted-egress posture applied for real: no all-egress rule,
# and the typed map is the whole posture.
run "apply_restricted_egress" {
  command = apply

  variables {
    name             = "gateway-frontend-restricted"
    vpc_name         = var.vpc_name
    allow_all_egress = false

    egress_rules = {
      targets-https = {
        description = "HTTPS to the backend target subnets"
        from_port   = 443
        cidr_ipv4   = "10.0.0.0/16"
      }
    }
  }

  assert {
    condition     = output.all_egress_rule_id == null
    error_message = "allow_all_egress = false must apply with NO all-egress rule"
  }

  assert {
    condition     = startswith(output.egress_rule_ids["targets-https"], "sgr-")
    error_message = "the typed egress rule must apply and return a real sgr-... id"
  }
}
