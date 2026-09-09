#--------------------------------------------------------------
# The role (DESIGN-0025)
#
# Exact name, no prefix: the fleet references this role BY NAME —
# every ADR-0020 remote-state read composes
# arn:aws:iam::<account_id>:role/<deploy_role_name> and assumes it.
# A generated or suffixed name would break that contract, so a name
# change is a deliberate replacement.
#--------------------------------------------------------------

resource "aws_iam_role" "this" {
  name                 = var.name
  path                 = var.path
  description          = var.description
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary

  tags = var.tags
}

#--------------------------------------------------------------
# Policy channels (DESIGN-0025 OQ 3a — attach-only)
#
# managed / customer attachments split across two resources so the
# plan distinguishes AWS-owned from caller-owned ARNs at a glance
# (the eks/pod-identity-access state-readability dividend). All three
# channels key by a stable value — the policy ARN or the policy name
# — so adding one never churns a sibling's address.
#--------------------------------------------------------------

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "customer" {
  for_each = toset(var.customer_managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  for_each = var.inline_policies

  name   = each.key
  role   = aws_iam_role.this.name
  policy = each.value
}
