# Apply-suite substrate for network/security-group.
#
# Composes the shared reference-vpc fixture (DESIGN-0016 — consumer
# apply tests never hand-roll a VPC; the real NAT gateway makes this
# ~1-2 min slower and that is the accepted price of full network-fact
# fidelity) and adds the two things a security group needs a real peer
# for:
#
#   1. A POPULATED managed prefix list, so a live prefix-list rule has
#      a real list to reference. This is also, uniquely in this fleet,
#      the first Community-tier probe of whether token-free 4.4 serves
#      managed prefix lists at all — the eks/cluster fence fixture has
#      only ever proved prefix-list entries under the PRO container.
#
#   2. A second security group, so the referenced_security_group_id
#      rule points at something that exists. Without it that source
#      type would be the one path the apply never exercises, which is
#      exactly the "green at one tier over a degenerate case at
#      another" gap the IMPL-0020 live-coverage sweep found three of.

module "vpc" {
  source = "../../../../../../test/fixtures/reference-vpc"

  remote_state_bucket        = var.remote_state_bucket
  remote_state_bucket_region = var.remote_state_bucket_region
  vpc_name                   = var.vpc_name
  account_name               = var.account_name
  region                     = var.region
}

resource "aws_ec2_managed_prefix_list" "corp" {
  name           = "${var.vpc_name}-corp-egress"
  address_family = "IPv4"
  max_entries    = 5

  entry {
    cidr        = "203.0.113.0/24"
    description = "Corp public egress range A"
  }

  entry {
    cidr        = "198.51.100.0/24"
    description = "Corp public egress range B"
  }

  tags = { Name = "${var.vpc_name}-corp-egress" }
}

# The peer for the referenced-SG rule. Deliberately a bare SG with no
# rules of its own — the module under test is what references it.
resource "aws_security_group" "peer" {
  name_prefix = "${var.vpc_name}-peer-"
  description = "Peer SG for the referenced_security_group_id rule under test"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${var.vpc_name}-peer" }

  lifecycle {
    create_before_destroy = true
  }
}
