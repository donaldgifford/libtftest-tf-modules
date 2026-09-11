#--------------------------------------------------------------
# Trust-condition composition (DESIGN-0027 Part A)
#
# One list of condition objects, built so an UNSET input contributes
# no element and therefore no rendered block at all. That is what
# keeps the zero-diff invariant: with require_org_ids = [] and
# external_id = null this list is empty, the dynamic block in
# trust.tf emits nothing, and the trust document is byte-identical to
# the one v0.23.0 shipped.
#
# Note the asymmetry in `values`: require_org_ids passes through
# whole (StringEquals ORs the values, which is the intended "in ANY
# of our organizations"), while external_id is wrapped in a
# single-element list because it is scalar by design.
#--------------------------------------------------------------

locals {
  trust_conditions = concat(
    (length(var.require_org_ids) == 0 ? [] : [{
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = var.require_org_ids
    }]),
    (var.external_id == null ? [] : [{
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }]),
  )
}
