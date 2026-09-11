# The rules surface (IMPL-0023 task 1.7).
#
# The Gateway-shaped map is the module's reference call: all FOUR source
# types in one plan, because each takes a different provider argument and
# a suite exercising only CIDRs would prove nothing about the other three
# — the prefix-list one least of all, and that is the whole live-reference
# point of the module.
#
# override_data is file-level: every run reads the same vpc state, and a
# validation failure does NOT short-circuit data-source evaluation, so a
# rejection run without a stub attempts a real S3 read and dies on
# credentials rather than on the rule under test.

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

# THE REFERENCE CALL. One rule per source type, keyed by logical name.
run "gateway_shaped_rules_all_four_source_types" {
  command = plan

  variables {
    ingress_rules = {
      # The live prefix-list reference — the module's headline behavior.
      github-webhooks = {
        description    = "GitHub webhook delivery to the public Gateway"
        from_port      = 443
        prefix_list_id = "pl-0123456789abcdef0"
      }
      # The hairpin rule: corp traffic egresses the corp network and
      # re-enters through the public ALB.
      corp-egress = {
        description = "Corp public egress IPs (hairpin posture)"
        from_port   = 443
        cidr_ipv4   = "203.0.113.0/24"
      }
      corp-egress-v6 = {
        description = "Corp public egress IPv6 (hairpin posture)"
        from_port   = 443
        cidr_ipv6   = "2001:db8::/32"
      }
      # A sibling stack's SG, taken cross-stack.
      internal-mesh = {
        description                  = "Service mesh sidecar traffic from the mesh SG"
        from_port                    = 15021
        referenced_security_group_id = "sg-0fedcba9876543210"
      }
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 4
    error_message = "all four ingress rules must plan"
  }

  # STABLE ADDRESSES. The keys are the addresses — this is what makes
  # removing one allowlist entry a single destroy rather than a
  # renumbering that churns every sibling.
  assert {
    condition = toset(keys(aws_vpc_security_group_ingress_rule.this)) == toset([
      "github-webhooks", "corp-egress", "corp-egress-v6", "internal-mesh",
    ])
    error_message = "ingress rule addresses must be the logical map keys, so a removal never churns a sibling"
  }

  # Each source type lands on its OWN provider argument, and the other
  # three stay null. A rule that set two would be an API error at apply;
  # asserting only the populated field would not catch it.
  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.this["github-webhooks"].prefix_list_id == "pl-0123456789abcdef0" &&
      aws_vpc_security_group_ingress_rule.this["github-webhooks"].cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.this["github-webhooks"].cidr_ipv6 == null &&
      aws_vpc_security_group_ingress_rule.this["github-webhooks"].referenced_security_group_id == null
    )
    error_message = "the prefix-list rule must set prefix_list_id and nothing else — this is the LIVE reference the module exists for"
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.this["corp-egress"].cidr_ipv4 == "203.0.113.0/24" &&
      aws_vpc_security_group_ingress_rule.this["corp-egress"].prefix_list_id == null
    )
    error_message = "the IPv4 rule must set cidr_ipv4 and nothing else"
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.this["corp-egress-v6"].cidr_ipv6 == "2001:db8::/32" &&
      aws_vpc_security_group_ingress_rule.this["corp-egress-v6"].cidr_ipv4 == null
    )
    error_message = "the IPv6 rule must set cidr_ipv6 and nothing else"
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.this["internal-mesh"].referenced_security_group_id == "sg-0fedcba9876543210" &&
      aws_vpc_security_group_ingress_rule.this["internal-mesh"].cidr_ipv4 == null
    )
    error_message = "the referenced-SG rule must set referenced_security_group_id and nothing else"
  }

  # to_port NULL-COLLAPSE: unset to_port becomes from_port, which is the
  # single-port case nearly every allowlist entry is.
  assert {
    condition = alltrue([
      for k in ["github-webhooks", "corp-egress", "corp-egress-v6"] :
      aws_vpc_security_group_ingress_rule.this[k].to_port == 443
    ])
    error_message = "an unset to_port must collapse to from_port"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.this["internal-mesh"].to_port == 15021
    error_message = "the collapse must use each rule's OWN from_port, not a shared one"
  }

  # Default protocol.
  assert {
    condition     = alltrue([for r in values(aws_vpc_security_group_ingress_rule.this) : r.ip_protocol == "tcp"])
    error_message = "ip_protocol must default to tcp"
  }

  # Every rule carries the caller tags plus a per-rule Name, so the
  # console shows which logical rule a live sgr-... is.
  assert {
    condition     = aws_vpc_security_group_ingress_rule.this["corp-egress"].tags["Name"] == "gateway-frontend-public-corp-egress"
    error_message = "each rule must carry a per-rule Name tag composed from the SG name and the logical rule key"
  }
}

# An explicit to_port makes a RANGE rather than collapsing.
run "explicit_to_port_makes_a_range" {
  command = plan

  variables {
    ingress_rules = {
      ephemeral = {
        description = "NodePort range from the corp range"
        from_port   = 30000
        to_port     = 32767
        cidr_ipv4   = "203.0.113.0/24"
      }
    }
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.this["ephemeral"].from_port == 30000 &&
      aws_vpc_security_group_ingress_rule.this["ephemeral"].to_port == 32767
    )
    error_message = "an explicit to_port must be preserved as a range, not collapsed"
  }
}

# ip_protocol "-1" with NO ports — the shape DESIGN-0026's literal object
# spec made unrepresentable (from_port was required there), which is why
# this module types from_port as optional. If this run ever goes red, the
# 1.4 deviation has been reverted.
run "all_protocols_rule_omits_ports" {
  command = plan

  variables {
    ingress_rules = {
      mesh-all = {
        description                  = "All protocols from the mesh SG"
        ip_protocol                  = "-1"
        referenced_security_group_id = "sg-0fedcba9876543210"
      }
    }
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.this["mesh-all"].ip_protocol == "-1" &&
      aws_vpc_security_group_ingress_rule.this["mesh-all"].from_port == null &&
      aws_vpc_security_group_ingress_rule.this["mesh-all"].to_port == null
    )
    error_message = "an all-protocols rule must plan with both ports null — the EC2 API rejects ports with -1"
  }
}

# An empty allowlist is legal: useless but harmless, and a legitimate
# bring-up intermediate (DESIGN-0026 — no at-least-one-rule floor).
run "empty_allowlist_is_legal" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.this) == 0
    error_message = "an empty ingress_rules map must plan zero rules, not fail"
  }

  # .id is unknown at plan (computed), so pin a known attribute instead —
  # the point is that the SG still plans, not what its id will be.
  assert {
    condition     = aws_security_group.this.name_prefix == "gateway-frontend-public-"
    error_message = "the security group itself must still plan with no rules"
  }
}
