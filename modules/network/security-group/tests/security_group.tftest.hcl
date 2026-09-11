# The security group itself and the egress posture (IMPL-0023 task 1.7).

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name     = "gateway-frontend-public"
  vpc_name = "libtftest-vpc"
}

override_data {
  target = data.terraform_remote_state.vpc
  values = {
    outputs = {
      vpc_id                 = "vpc-0123456789abcdef0"
      private_subnet_ids     = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
      private_eks_subnet_ids = ["subnet-eks-aaa", "subnet-eks-bbb", "subnet-eks-ccc"]
      public_subnet_ids      = ["subnet-pub-aaa", "subnet-pub-bbb", "subnet-pub-ccc"]
      vpc_cidr_block         = "10.0.0.0/16"
      availability_zones     = ["us-east-1a", "us-east-1b", "us-east-1c"]
      nat_gateway_ids        = ["nat-0123456789abcdef0"]
      route_table_ids        = ["rtb-public0", "rtb-private0"]
      internet_gateway_id    = "igw-0123456789abcdef0"
    }
  }
}

# THE BARE CALL. Pins every default in one place, so a default that
# changes has to change this run — the gap that let IMPL-0022's
# empty-string permissions_boundary defect stay invisible was exactly
# the absence of a run like this.
run "bare_call_pins_defaults" {
  command = plan

  # name_prefix, NOT name. A fixed name makes a forced replacement of an
  # ALB-attached SG deadlock on DependencyViolation and makes
  # create_before_destroy impossible (the successor collides on the
  # name). If this assertion is ever "simplified" to `name`, that is the
  # bug it reintroduces.
  assert {
    condition     = aws_security_group.this.name_prefix == "gateway-frontend-public-"
    error_message = "the SG must use name_prefix = \"<name>-\", never a fixed name (DESIGN-0026 OQ 2a)"
  }

  # No assertion on `name`: it is Optional+Computed, so the provider
  # fills it FROM name_prefix and it reads as unknown at plan. The
  # name_prefix pin above is what carries the intent; asserting the
  # generated name would only encode provider representation.

  # The friendly name rides the Name tag, since the physical name carries
  # a generated suffix.
  assert {
    condition     = aws_security_group.this.tags["Name"] == "gateway-frontend-public"
    error_message = "the friendly name must ride the Name tag"
  }

  assert {
    condition     = aws_security_group.this.description == "Managed by Terraform — gateway-frontend-public"
    error_message = "description must default from var.name"
  }

  assert {
    condition     = aws_security_group.this.vpc_id == "vpc-0123456789abcdef0"
    error_message = "the SG must land in the VPC named by the remote-state contract"
  }

  # The default egress posture: one explicit all-protocols rule. Present
  # by DEFAULT, because the provider revokes AWS's own default egress at
  # create and a silent no-egress SG breaks ALB health checks in the
  # worst discovery mode — live, not at plan.
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.all) == 1
    error_message = "allow_all_egress must default to true and emit exactly one all-egress rule"
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.all[0].cidr_ipv4 == "0.0.0.0/0" &&
      aws_vpc_security_group_egress_rule.all[0].ip_protocol == "-1" &&
      aws_vpc_security_group_egress_rule.all[0].from_port == null
    )
    error_message = "the all-egress rule must be the eks/cluster nodes_all shape: 0.0.0.0/0, protocol -1, no ports"
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.this) == 0
    error_message = "the typed egress map must default empty"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 0
    error_message = "the ingress allowlist must default empty — fail-closed"
  }

  # ADR-0020 key-template pin: the vpc read must compose the contract key
  # <account_name>/<region>/vpc/<vpc_name>/terraform.tfstate. The
  # producer's live-repo directory must match.
  assert {
    condition     = data.terraform_remote_state.vpc.config.key == "sandbox/us-east-1/vpc/libtftest-vpc/terraform.tfstate"
    error_message = "vpc remote-state read must compose <account_name>/<region>/vpc/<vpc_name>/terraform.tfstate (ADR-0020 remote-state key contract)"
  }

  # The cross-account read must assume the deploy role — dropping this
  # block is how a consumer silently starts reading its OWN account.
  assert {
    condition     = data.terraform_remote_state.vpc.config.assume_role.role_arn == "arn:aws:iam::000000000000:role/Deploy-Tf-Role"
    error_message = "the vpc read must assume arn:aws:iam::<account_id>:role/<deploy_role_name> (IMPL-0015)"
  }
}

run "restricted_egress_replaces_the_default" {
  command = plan

  variables {
    allow_all_egress = false
    egress_rules = {
      targets-https = {
        description = "HTTPS to the backend target group subnets"
        from_port   = 443
        cidr_ipv4   = "10.0.0.0/16"
      }
      dns = {
        description = "DNS to the VPC resolver"
        from_port   = 53
        ip_protocol = "udp"
        cidr_ipv4   = "10.0.0.2/32"
      }
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.all) == 0
    error_message = "allow_all_egress = false must emit NO all-egress rule"
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_egress_rule.this)) == toset(["targets-https", "dns"])
    error_message = "the typed egress map must drive rule addresses the same way ingress does"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.this["dns"].ip_protocol == "udp"
    error_message = "egress rules must honour a non-default ip_protocol"
  }
}

# allow_all_egress and egress_rules are ADDITIVE, not exclusive. Worth
# pinning because the variable descriptions say so and a reader could
# reasonably assume the typed map replaces the default.
run "typed_egress_is_additive_to_the_default" {
  command = plan

  variables {
    egress_rules = {
      targets-https = {
        description = "HTTPS to the backend target group subnets"
        from_port   = 443
        cidr_ipv4   = "10.0.0.0/16"
      }
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.all) == 1 && length(aws_vpc_security_group_egress_rule.this) == 1
    error_message = "the typed egress map must be additive to the all-egress default, not a replacement for it"
  }
}

run "caller_tags_ride_every_resource" {
  command = plan

  variables {
    tags = { ManagedBy = "terraform", Component = "gateway" }
    ingress_rules = {
      corp = { description = "corp", from_port = 443, cidr_ipv4 = "203.0.113.0/24" }
    }
  }

  assert {
    condition     = aws_security_group.this.tags["ManagedBy"] == "terraform" && aws_security_group.this.tags["Component"] == "gateway"
    error_message = "caller tags must reach the security group"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.this["corp"].tags["Component"] == "gateway"
    error_message = "caller tags must reach every rule, not just the SG"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.all[0].tags["Component"] == "gateway"
    error_message = "caller tags must reach the all-egress rule too"
  }
}

run "custom_description_overrides_the_default" {
  command = plan

  variables {
    description = "Public Gateway frontend — webhooks and corp hairpin"
  }

  assert {
    condition     = aws_security_group.this.description == "Public Gateway frontend — webhooks and corp hairpin"
    error_message = "an explicit description must override the composed default"
  }
}
