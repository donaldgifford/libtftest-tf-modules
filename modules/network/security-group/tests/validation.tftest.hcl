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

  # allow_all_egress = false in EVERY egress rejection run below. Without
  # it the coherence guard (allow_all_egress + non-empty egress_rules)
  # fires first and the run passes off THAT rule instead of the one it
  # names — the expect_failures trap, reintroduced by adding a guard to
  # a variable that already had several.
  variables {
    allow_all_egress = false
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

# The two egress guards that had NO coverage at either tier — found by
# mutation: neutering both left the suite 21/21 green.
run "egress_rule_with_blank_description_rejected" {
  command = plan

  variables {
    allow_all_egress = false
    egress_rules = {
      blank = { description = "   ", from_port = 443, cidr_ipv4 = "10.0.0.0/16" }
    }
  }

  expect_failures = [var.egress_rules]
}

run "egress_ports_with_all_protocols_rejected" {
  command = plan

  variables {
    allow_all_egress = false
    egress_rules = {
      allproto = {
        description = "ports alongside ip_protocol -1"
        from_port   = 443
        ip_protocol = "-1"
        cidr_ipv4   = "10.0.0.0/16"
      }
    }
  }

  expect_failures = [var.egress_rules]
}

run "reserved_all_egress_key_rejected" {
  command = plan

  variables {
    allow_all_egress = false
    egress_rules = {
      all-egress = { description = "collides with the module rule Name tag", from_port = 443, cidr_ipv4 = "10.0.0.0/16" }
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

# THE SPELLING-EVASION REGRESSIONS. The guard used to compare the string
# "::/0", and IPv6 has many legal spellings of that prefix — both of
# these planned CLEAN with allow_world_open_ingress at its false
# default, and AWS creates the rule (provider issue #15982 is this
# exact bug). The v4 side was safe only by luck: the provider's
# network-address validator leaves "0.0.0.0/0" as the sole accepted v4
# /0 spelling.
#
# A fail-case run against "::/0" alone proves nothing about the others,
# which is precisely why the run above was not enough.
run "world_open_ipv6_compressed_zero_rejected" {
  command = plan

  variables {
    ingress_rules = {
      sneaky = { description = "the 0::/0 spelling of the v6 world", from_port = 443, cidr_ipv6 = "0::/0" }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "world_open_ipv6_expanded_rejected" {
  command = plan

  variables {
    ingress_rules = {
      sneaky = {
        description = "the fully expanded spelling of the v6 world"
        from_port   = 443
        cidr_ipv6   = "0000:0000:0000:0000:0000:0000:0000:0000/0"
      }
    }
  }

  expect_failures = [var.ingress_rules]
}

#--------------------------------------------------------------
# AWS string-charset constraints — server-side only
#--------------------------------------------------------------

# The module's OWN default description carried a U+2014 em dash, so
# every non-overriding invocation would have failed at apply against
# real AWS. Neither gate could catch it: the constraint is server-side,
# and LocalStack does not enforce it.
run "non_ascii_description_rejected" {
  command = plan

  variables {
    description = "Public Gateway frontend — webhooks and corp hairpin"
  }

  expect_failures = [var.description]
}

run "non_ascii_rule_description_rejected" {
  command = plan

  variables {
    ingress_rules = {
      corp = { description = "Corp ranges — hairpin posture", from_port = 443, cidr_ipv4 = "203.0.113.0/24" }
    }
  }

  expect_failures = [var.ingress_rules]
}

#--------------------------------------------------------------
# Protocol semantics
#--------------------------------------------------------------

# ICMP puts the TYPE in from_port and the CODE in to_port. Left to
# collapse, `{ from_port = 8, ip_protocol = "icmp" }` reads as "allow
# ping" and plans as type 8 / code 8 — which matches nothing, since
# echo requests carry code 0. Both must be explicit.
run "icmp_rule_without_explicit_code_rejected" {
  command = plan

  variables {
    ingress_rules = {
      ping = { description = "allow ping", from_port = 8, ip_protocol = "icmp", cidr_ipv4 = "203.0.113.0/24" }
    }
  }

  expect_failures = [var.ingress_rules]
}

# A correctly-spelled ICMP rule must still PASS — otherwise the rule
# above would be satisfied by a guard that rejects all ICMP.
run "icmp_rule_with_explicit_code_accepted" {
  command = plan

  variables {
    ingress_rules = {
      ping = {
        description = "allow ping, any code"
        from_port   = 8
        to_port     = -1
        ip_protocol = "icmp"
        cidr_ipv4   = "203.0.113.0/24"
      }
    }
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.this["ping"].from_port == 8 && aws_vpc_security_group_ingress_rule.this["ping"].to_port == -1
    error_message = "a correctly-spelled ICMP rule must plan with type and code as written, with no collapse"
  }
}

# AWS ignores ports for protocols other than tcp/udp/icmp, so a rule
# carrying them reads as port-scoped and is not. This and
# ports_with_all_protocols_rejected fire the SAME coherence rule on
# purpose — they exercise its two non-port branches ("-1" and a numeric
# protocol), which the probe confirmed.
run "ports_on_a_numeric_protocol_rejected" {
  command = plan

  variables {
    ingress_rules = {
      esp = { description = "ESP with a port that AWS will ignore", from_port = 443, ip_protocol = "50", cidr_ipv4 = "203.0.113.0/24" }
    }
  }

  expect_failures = [var.ingress_rules]
}

# NO from_port here, deliberately. With one, the isolated message probe
# showed this input tripping the port-coherence rule as well (an unknown
# protocol is not tcp/udp, so ports must be absent) — two rules firing,
# and expect_failures cannot tell you which one it passed off. Omitting
# the port leaves the protocol enum as the only rule this input can
# violate.
run "unknown_ip_protocol_rejected" {
  command = plan

  variables {
    ingress_rules = {
      typo = { description = "protocol typo", ip_protocol = "https", cidr_ipv4 = "203.0.113.0/24" }
    }
  }

  expect_failures = [var.ingress_rules]
}

run "inverted_port_range_rejected" {
  command = plan

  variables {
    ingress_rules = {
      backwards = { description = "to_port below from_port", from_port = 443, to_port = 80, cidr_ipv4 = "203.0.113.0/24" }
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
