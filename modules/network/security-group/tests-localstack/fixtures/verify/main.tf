# Read-back fixture: an independent look at what the EC2 API serves for
# the security group the module under test created, rather than at what
# the provider recorded in state.

data "aws_security_group" "this" {
  id = var.security_group_id
}

# The prefix-list rule read back through the EC2 API, by its own
# sgr-... id. This is the assertion that actually proves the LIVE
# reference survived — asserting only that the rule got an id would
# pass even if the prefix list id had been dropped on the way in, which
# is exactly the "green at the tier where the logic lives, degenerate at
# the tier that matters" gap the IMPL-0020 live-coverage sweep found.
data "aws_vpc_security_group_rule" "prefix_list" {
  security_group_rule_id = var.prefix_list_rule_id
}
