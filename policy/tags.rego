# tags.rego — the per-module `tags` variable removal gate (IMPL-0026
# Phase 3 / DESIGN-0029).
#
# THE INVARIANT: no module declares a `variable "tags"`. The fleet's
# standard tag set arrives through the AWS provider's default_tags,
# which Terragrunt sets in the live repo's generated provider block.
# Terragrunt also passes one uniform input set to every module, and a
# per-module `tags` variable with a module-specific type (the old
# eks/addons typed object) breaks that uniformity. Modules set only
# the keys they own (`Name`, `cost_tag`, ...) on the resource itself.
#
# Enforced repo-wide by scripts/static-check.sh §7 (and `just
# conftest`) against MODULE SOURCE using conftest's hcl2 parser. A
# `variable "tags"` block parses to
#   input.variable.tags = [ { <attributes> } ]
# (probed with `conftest parse --parser hcl2`, 2026-11-11).
#
# Only the declaration needs a rule. Once it cannot exist, a `var.tags`
# reference fails `terraform validate` (static §2), and a stale `tags`
# in a .tftest.hcl `variables` block is silently ignored, so it can
# break nothing.
#
# Scope, stated honestly: this matches the name `tags` only. Purpose-
# named, typed inputs a module owns (eks/pod-identity-access's
# `association_tags`, bedrock's `cost_tag`, vpc-lookup's `*_tags`
# lookup filters) are deliberately allowed. A generic pass-through
# reintroduced under another name (`extra_tags`) is not caught here.
# That is a review question, not a lint question.

package main

deny contains msg if {
	input.variable.tags
	msg := "module declares variable \"tags\" — the standard tag set arrives through the provider's default_tags (DESIGN-0029); set only module-owned keys on the resource itself"
}
