# ECR registry: the single owner of a private registry's registry-level
# configuration in one account and region (DESIGN-0030 / IMPL-0027).
#
# The registry policy, the REGISTRY_POLICY_SCOPE account setting and the
# scanning configuration are per-registry SINGLETONS: each Put call
# replaces the whole thing. Two stacks managing any of them in the same
# registry overwrite each other on every apply, with a permanent diff
# and no error. So purpose modules (ecr/org-registry, ecr/image-intake)
# never touch them, and this module must be deployed once per account
# and region.
#
# The headline feature is an account ALLOW-LIST: named accounts may pull
# from named repository prefixes, with no org-wide or OU-wide grant.

#--------------------------------------------------------------
# Registry policy scope
#--------------------------------------------------------------

# Pull grants in a registry policy need the V2 scope ("Amazon ECR allows
# all ECR actions in the policy"). V1 covers only replication and
# pull-through-cache actions.
resource "aws_ecr_account_setting" "registry_policy_scope" {
  count = var.manage_registry_policy_scope ? 1 : 0

  name  = "REGISTRY_POLICY_SCOPE"
  value = "V2"
}

#--------------------------------------------------------------
# Registry policy
#--------------------------------------------------------------

resource "aws_ecr_registry_policy" "this" {
  count = local.render_policy ? 1 : 0

  policy = local.registry_policy_json

  lifecycle {
    # Same-account access is IAM's job. A self-grant here reads as
    # narrowing while doing nothing, so it is rejected.
    precondition {
      condition     = !contains(keys(var.consumer_accounts), local.account_id)
      error_message = "consumer_accounts must not include this registry's own account (${local.account_id}). Same-account pulls are governed by IAM; a self-grant here grants nothing."
    }
  }

  # ORDERING (IMPL-0027 Phase 1 finding): a V1-scoped registry is
  # expected to REJECT a pull grant at PutRegistryPolicy (LocalStack Pro
  # 2026.10.7 does exactly that), so the scope must be V2 before the
  # policy is written. Terraform cannot infer this: nothing in the
  # policy references the setting.
  depends_on = [aws_ecr_account_setting.registry_policy_scope]
}

#--------------------------------------------------------------
# Scanning configuration (off by default, DESIGN-0030 OQ 7a)
#--------------------------------------------------------------

# A non-null var.scanning TAKES OWNERSHIP of the registry's scanning
# setup: the resource replaces it wholesale. ENHANCED enables Amazon
# Inspector billing for the account.
resource "aws_ecr_registry_scanning_configuration" "this" {
  count = var.scanning == null ? 0 : 1

  scan_type = var.scanning.scan_type

  dynamic "rule" {
    for_each = var.scanning.rules

    content {
      scan_frequency = rule.value.scan_frequency

      dynamic "repository_filter" {
        for_each = rule.value.filters

        content {
          filter      = repository_filter.value
          filter_type = "WILDCARD"
        }
      }
    }
  }
}
