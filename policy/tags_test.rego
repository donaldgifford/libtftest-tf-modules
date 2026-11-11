# Unit tests for tags.rego — run via `conftest verify --policy policy/`
# (wired into `just conftest` and static §7). The deny rule is exercised
# both ways: a `variable "tags"` fires exactly one message, and every
# legitimate tag-shaped input in the fleet stays clean.
#
# Inputs mirror conftest's hcl2 parse shape:
# input.variable.<name> = [ { <attributes> } ].

package main

test_tags_variable_denied if {
	count(deny) == 1 with input as {"variable": {"tags": [{"type": "${map(string)}", "default": {}}]}}
}

# The old eks/addons shape: a typed object, still named `tags`.
test_typed_tags_variable_denied if {
	count(deny) == 1 with input as {"variable": {"tags": [{"type": "${object({Environment = string})}"}]}}
}

test_resource_tags_argument_allowed if {
	count(deny) == 0 with input as {"resource": {"aws_security_group": {"this": [{"name_prefix": "x-", "tags": {"Name": "x"}}]}}}
}

test_association_tags_allowed if {
	count(deny) == 0 with input as {"variable": {"association_tags": [{"type": "${map(string)}", "default": {}}]}}
}

test_cost_tag_allowed if {
	count(deny) == 0 with input as {"variable": {"cost_tag": [{"type": "${object({key = string, value = string})}"}]}}
}

test_vpc_lookup_tag_filters_allowed if {
	count(deny) == 0 with input as {"variable": {
		"vpc_tags": [{"type": "${map(string)}"}],
		"private_subnet_tags": [{"type": "${map(string)}"}],
		"public_subnet_tags": [{"type": "${map(string)}"}],
		"private_eks_subnet_tags": [{"type": "${map(string)}"}],
	}}
}

# A module with no variables at all (network/vpc-lookup's outputs.tf,
# any versions.tf) parses with no `variable` key.
test_no_variables_allowed if {
	count(deny) == 0 with input as {"terraform": [{"required_version": ">= 1.5"}]}
}
