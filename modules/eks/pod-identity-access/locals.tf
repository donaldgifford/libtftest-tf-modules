#--------------------------------------------------------------
# Locals
#--------------------------------------------------------------
#
# Deterministic IAM role name:
#   <cluster_name>-<namespace>-<service_account>
#
# Joined with "-" by default; overridden by var.role_name_override.
# When the joined default exceeds IAM's 64-char hard limit, truncate
# to 57 chars + "-" + 6-char sha256 prefix (totaling 64). The hash
# disambiguates names that share the same 57-char prefix so different
# (namespace, service_account) pairs don't silently collide.

locals {
  role_name_joined = "${var.cluster_name}-${var.namespace}-${var.service_account}"

  role_name_truncated = (
    length(local.role_name_joined) <= 64
    ? local.role_name_joined
    : format("%s-%s", substr(local.role_name_joined, 0, 57), substr(sha256(local.role_name_joined), 0, 6))
  )

  # tflint-ignore: terraform_unused_declarations  # consumed by aws_iam_role.this[0].name in Phase 3
  role_name = coalesce(var.role_name_override, local.role_name_truncated)
}
