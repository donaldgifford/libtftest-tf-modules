# Fail-closed rejections (IMPL-0023 tasks 1.7 / 1.8).
#
# VERIFICATION DISCIPLINE. `expect_failures` asserts only that the named
# object errored — NOT which of the rules on it fired. Four validations
# stack on var.ingress_rules alone, so every run below could in
# principle be passing off a neighbouring rule and look identically
# green.
#
# Each was therefore verified by MESSAGE PROBE before this file existed:
# the case was run in isolation with no expect_failures and the real
# error read. All seven fired their own rule at their own variables.tf
# line, and each named only the offending map keys. Task 1.8 records the
# full transcript.
#
# The world-open pair is the one that matters most. A fail-case-only
# probe cannot distinguish a working cross-variable reference from a
# rule that rejects everything — so the toggled-ON run below is a
# `pass`, not an expect_failures, and it is load-bearing.

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

# A variable-validation failure does NOT short-circuit data-source
# evaluation, so without this stub every rejection run below would
# attempt a real S3 read and die on credentials instead of on the rule
# under test.
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

#--------------------------------------------------------------
# Exactly-one-source
#--------------------------------------------------------------

run "ingress_rule_with_no_source_rejected" {
  command = plan

  variables {
    ingress_rules = {
      webhook = { description = "names no source at all", from_port = 443 }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "ingress_rule_with_two_sources_rejected" {
  command = plan

  variables {
    ingress_rules = {
      corp = {
        description    = "names both a CIDR and a prefix list"
        from_port      = 443
        cidr_ipv4      = "203.0.113.0/24"
        prefix_list_id = "pl-0123456789abcdef0"
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "egress_rule_with_two_destinations_rejected" {
  command = plan

  variables {
    egress_rules = {
      out = {
        description    = "names both a CIDR and a prefix list"
        from_port      = 443
        cidr_ipv4      = "10.0.0.0/16"
        prefix_list_id = "pl-0123456789abcdef0"
      }
    }
  }

  expect_failures = [var.egress_rules]
}

#--------------------------------------------------------------
# Description required — the allowlist is an audit surface
#--------------------------------------------------------------

run "ingress_rule_with_blank_description_rejected" {
  command = plan

  # Whitespace, not "". An empty string would be caught by a naive
  # != "" check too; "   " is what proves the rule trims.
  variables {
    ingress_rules = {
      blank = { description = "   ", from_port = 443, cidr_ipv4 = "203.0.113.0/24" }
    }
  }

  expect_failures = [var.ingress_rules]
}

#--------------------------------------------------------------
# Port coherence
#--------------------------------------------------------------

run "ports_with_all_protocols_rejected" {
  command = plan

  variables {
    ingress_rules = {
      allproto = {
        description = "ports alongside ip_protocol -1"
        from_port   = 443
        ip_protocol = "-1"
        cidr_ipv4   = "203.0.113.0/24"
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "tcp_rule_without_a_port_rejected" {
  command = plan

  variables {
    ingress_rules = {
      noport = { description = "tcp with no from_port", cidr_ipv4 = "203.0.113.0/24" }
    }
  }

  expect_failures = [var.ingress_rules]
}

#--------------------------------------------------------------
# The world-open guard — the cross-variable rule (>= 1.9)
#--------------------------------------------------------------

run "world_open_ipv4_rejected" {
  command = plan

  variables {
    ingress_rules = {
      public = { description = "pasted wide open", from_port = 443, cidr_ipv4 = "0.0.0.0/0" }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "world_open_ipv6_rejected" {
  command = plan

  variables {
    ingress_rules = {
      public-v6 = { description = "pasted wide open, v6", from_port = 443, cidr_ipv6 = "::/0" }
    }
  }

  expect_failures = [var.ingress_rules]
}

# THE POSITIVE HALF OF THE CROSS-VARIABLE GUARD. Load-bearing: if the
# reference to var.allow_world_open_ingress ever stops resolving — a
# floor lowered below 1.9, the guard rewritten — this run goes red while
# every rejection above stays green, because a rule that rejects
# everything still satisfies an expect_failures.
run "world_open_permitted_by_explicit_toggle" {
  command = plan

  variables {
    allow_world_open_ingress = true
    ingress_rules = {
      public = {
        description = "deliberately public Gateway frontend"
        from_port   = 443
        cidr_ipv4   = "0.0.0.0/0"
      }
    }
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.this["public"].cidr_ipv4 == "0.0.0.0/0"
    error_message = "with the toggle on, a world-open rule must plan"
  }
}

# Egress deliberately has NO world-open guard (DESIGN-0026 OQ 2a): world
# egress IS the default posture, so rejecting it in the typed map would
# reject a shape allow_all_egress already grants. Pinned as a PASS so
# that adding a symmetric guard later is a deliberate, visible change.
run "world_open_egress_is_permitted_by_design" {
  command = plan

  variables {
    allow_all_egress = false
    egress_rules = {
      out = {
        description = "restricted egress that re-creates the default, visibly"
        from_port   = 443
        cidr_ipv4   = "0.0.0.0/0"
      }
    }
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.this["out"].cidr_ipv4 == "0.0.0.0/0"
    error_message = "world-open EGRESS must remain permitted — it is the module's default posture (OQ 2a)"
  }
}

#--------------------------------------------------------------
# Identity
#--------------------------------------------------------------

run "caller_supplied_name_tag_rejected" {
  command = plan

  variables {
    tags = { Name = "hand-set-name" }
  }

  expect_failures = [var.tags]
}

run "malformed_name_rejected" {
  command = plan

  variables {
    name = "has spaces and/slashes"
  }

  expect_failures = [var.name]
}
