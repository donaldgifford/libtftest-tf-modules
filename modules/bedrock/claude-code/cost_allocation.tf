#--------------------------------------------------------------
# Cost-allocation tag activation (conditional) + identity data sources
#
# This is Phase 2 (early) because every downstream resource's tag set
# references var.cost_tag.key — a single failure point here if the tag
# key is malformed beats one failure per resource later.
#
# The identity-class data sources live here (ADR-0001 carve-out: the
# remote-state-only rule does not cover aws_caller_identity /
# aws_organizations_organization). account_id feeds the IAM policy scope
# (Phase 3); the org lookup backs the tag-activation guardrail below.
#--------------------------------------------------------------

data "aws_caller_identity" "current" {}

# Org lookup gated on local mode — the only mode that activates a tag in
# THIS account. count = 0 outside local mode so member/standalone
# accounts using payer/none modes never pay the Organizations API call.
data "aws_organizations_organization" "current" {
  count = var.cost_allocation_tag_activation == "local" ? 1 : 0
}

# Activate var.cost_tag.key as a cost-allocation tag in this account.
# Only meaningful in a standalone account or the org management account
# (member accounts must activate in the payer account — var.cost_tag is
# still applied as a plain tag there; see README payer-mode recipe).
resource "aws_ce_cost_allocation_tag" "this" {
  count = var.cost_allocation_tag_activation == "local" ? 1 : 0

  tag_key = var.cost_tag.key
  status  = "Active"

  # Permissive guardrail (DESIGN-0009 Q7, lookup-failure-as-standalone):
  # block only when we can PROVE this is a non-management org member —
  # i.e. the org read succeeded AND its management account differs from
  # the caller. try(..., true) defaults to pass when the org read is
  # unavailable (standalone account, no Organizations permission), so
  # standalone accounts in local mode are never blocked.
  lifecycle {
    precondition {
      condition     = try(data.aws_organizations_organization.current[0].master_account_id == local.account_id, true)
      error_message = "cost_allocation_tag_activation = 'local' activates the cost-allocation tag in THIS account, but this account appears to be a non-management member of an AWS Organization. Cost-allocation tags can only be activated in a standalone account or the org management (payer) account. Use cost_allocation_tag_activation = 'payer' and activate the tag in the management account (see the README payer-mode recipe), or 'none' to skip activation."
    }
  }
}
