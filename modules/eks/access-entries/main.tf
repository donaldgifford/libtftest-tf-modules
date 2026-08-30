#--------------------------------------------------------------
# EKS Access Entries — the generic principal-to-cluster surface
#--------------------------------------------------------------
#
# DESIGN-0024 part 1. Binds arbitrary IAM principals to a cluster with
# per-entry policy associations and full namespace scoping — none of
# which the cluster module's SSO singleton supports (INV-0011 F7).
# The platform's consumers (DESIGN-0001 §4) are the hub
# argocd-deployer's assumed sse-platform-access role, break-glass SSO,
# and the deploy role.
#
# The SSO singleton stays in eks/cluster, untouched. Because the two
# surfaces now live in different stacks, a principal declared in both
# is a CROSS-STACK conflict that AWS would only reject at apply — the
# precondition below turns it into a plan failure here.

locals {
  # Flatten (entry x association) into a single map keyed
  # "<entry>:<association>". Both halves are logical names, so adding
  # or removing one association never re-indexes a sibling — the
  # for_each-over-typed-map convention, not list indices.
  policy_associations = merge([
    for entry_key, entry in var.access_entries : {
      for assoc_key, assoc in entry.policy_associations :
      "${entry_key}:${assoc_key}" => {
        entry_key     = entry_key
        principal_arn = entry.principal_arn
        policy_arn    = assoc.policy_arn
        scope_type    = assoc.access_scope.type
        namespaces    = assoc.access_scope.namespaces
      }
    }
  ]...)

  # Null-safe: a cluster state written before DESIGN-0024 has no
  # sso_principal_arn output at all. Degrade to no-guard rather than
  # erroring — the README tells the operator to re-apply the cluster
  # stack to arm it.
  sso_principal_arn = try(data.terraform_remote_state.eks.outputs.sso_principal_arn, null)

  # Identity key for comparing principals, because one IAM role has two
  # legitimate ARN spellings. data.aws_iam_roles (the cluster module's
  # SSO lookup) returns reserved SSO roles path-bearing:
  #   arn:aws:iam::<acct>:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_Admin_abc
  # while the conventional spelling in access-entry configs strips the
  # path:
  #   arn:aws:iam::<acct>:role/AWSReservedSSO_Admin_abc
  # Those are the same principal to AWS but different strings, so a raw
  # compare would let the path-stripped form slip past the guard.
  # Reduce both to "<account>/<name>", lowercased — IAM role names are
  # case-insensitive for uniqueness.
  sso_principal_key = local.sso_principal_arn == null ? null : lower(
    "${split(":", local.sso_principal_arn)[4]}/${reverse(split("/", local.sso_principal_arn))[0]}"
  )

  entry_principal_keys = {
    for k, e in var.access_entries :
    k => lower("${split(":", e.principal_arn)[4]}/${reverse(split("/", e.principal_arn))[0]}")
  }
}

resource "aws_eks_access_entry" "this" {
  for_each = var.access_entries

  cluster_name      = data.terraform_remote_state.eks.outputs.cluster_name
  principal_arn     = each.value.principal_arn
  type              = each.value.type
  kubernetes_groups = each.value.kubernetes_groups
  user_name         = each.value.user_name
  tags              = var.tags

  lifecycle {
    # Cross-stack collision guard. eks/cluster owns the SSO principal's
    # entry; declaring it here too means two stacks own one AWS
    # resource — an apply-time ResourceInUseException, and a fight over
    # its policies forever after.
    precondition {
      condition     = local.sso_principal_key == null || local.entry_principal_keys[each.key] != local.sso_principal_key
      error_message = "access_entries[\"${each.key}\"] names the principal that eks/cluster already binds via its SSO access entry (${coalesce(local.sso_principal_arn, "n/a")}). Compared path- and case-insensitively, so an unqualified spelling of the same role is caught too. One principal, one owning stack: drop this entry, or disable sso_access_enabled on the cluster and declare the principal here."
    }
  }
}

resource "aws_eks_access_policy_association" "this" {
  for_each = local.policy_associations

  cluster_name  = data.terraform_remote_state.eks.outputs.cluster_name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type = each.value.scope_type

    # The EKS API rejects namespaces on a cluster-scoped association.
    namespaces = each.value.scope_type == "namespace" ? each.value.namespaces : null
  }

  # The entry must exist before a policy attaches to its principal.
  depends_on = [aws_eks_access_entry.this]
}
