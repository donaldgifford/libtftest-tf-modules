#--------------------------------------------------------------
# Policy composition (DESIGN-0030 § Policy composition)
#
# Built with jsonencode, NOT aws_iam_policy_document: the data source
# collapses a one-element principal list to a bare string, so every
# assertion would need two shapes. Here a principal list is always a
# list. Every input is sorted before encoding, so reordering a caller's
# map or list never produces a diff.
#--------------------------------------------------------------

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # The pull trio: enough for kubelet, crane and docker, including
  # resolving a tag to a digest (DESIGN-0030 OQ 4a).
  # ecr:GetAuthorizationToken has no resource, so it is identity-only
  # and lives in the consumer contract instead.
  pull_actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
  ]

  consumer_ids = sort(keys(var.consumer_accounts))
  plain_ids    = [for id in local.consumer_ids : id if length(var.consumer_accounts[id].principal_arn_patterns) == 0]
  narrowed_ids = [for id in local.consumer_ids : id if length(var.consumer_accounts[id].principal_arn_patterns) > 0]

  pull_prefixes      = sort(distinct(var.pull_repository_prefixes))
  protected_prefixes = sort(distinct(var.protected_prefixes))

  pull_repository_arns      = [for p in local.pull_prefixes : "arn:aws:ecr:${local.region}:${local.account_id}:repository/${p}/*"]
  protected_repository_arns = [for p in local.protected_prefixes : "arn:aws:ecr:${local.region}:${local.account_id}:repository/${p}/*"]

  # Accounts with no narrowing share one statement.
  plain_statements = (length(local.plain_ids) == 0 ? [] : [{
    Sid       = "ConsumerPull"
    Effect    = "Allow"
    Principal = { AWS = [for id in local.plain_ids : "arn:aws:iam::${id}:root"] }
    Action    = local.pull_actions
    Resource  = local.pull_repository_arns
  }])

  # A narrowed account needs its own statement: the condition differs
  # per account, and conditions AND within a statement.
  narrowed_statements = [for id in local.narrowed_ids : {
    Sid       = "ConsumerPull${id}"
    Effect    = "Allow"
    Principal = { AWS = ["arn:aws:iam::${id}:root"] }
    Action    = local.pull_actions
    Resource  = local.pull_repository_arns
    Condition = {
      ArnLike = { "aws:PrincipalArn" = sort(distinct(var.consumer_accounts[id].principal_arn_patterns)) }
    }
  }]

  # DESIGN-0030 OQ 5b: an explicit Deny on the protected prefixes for
  # EVERY allow-listed account (plain and narrowed). An explicit Deny
  # beats any Allow, so this holds even when an over-broad
  # additional_policy_statements entry grants a consumer repository/*.
  # It names consumer accounts only, so same-account principals
  # (writers, intake) are unaffected.
  deny_protected_statements = (length(local.consumer_ids) == 0 || length(local.protected_prefixes) == 0 ? [] : [{
    Sid       = "ConsumerDenyProtected"
    Effect    = "Deny"
    Principal = { AWS = [for id in local.consumer_ids : "arn:aws:iam::${id}:root"] }
    Action    = ["ecr:*"]
    Resource  = local.protected_repository_arns
  }])

  # Operator statements, rendered as given and appended last. Conditions
  # sharing a test operator merge into one operator object, which is how
  # IAM reads them anyway. Condition is omitted entirely when empty: the
  # for-expression yields {} so merge() adds no key.
  additional_statements = [for st in var.additional_policy_statements : merge(
    {
      Sid       = st.sid
      Effect    = st.effect
      Principal = { for p in st.principals : p.type => p.identifiers }
      Action    = st.actions
      Resource  = st.resources
    },
    { for k, v in {
      Condition = {
        for t in distinct([for c in st.conditions : c.test]) :
        t => { for c in st.conditions : c.variable => c.values if c.test == t }
      }
    } : k => v if length(st.conditions) > 0 },
  )]

  # Whether a policy renders depends only on input lengths, so the
  # resource count is known at plan.
  render_policy = length(var.consumer_accounts) + length(var.additional_policy_statements) > 0

  registry_policy_json = (local.render_policy ? jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      local.plain_statements,
      local.narrowed_statements,
      local.deny_protected_statements,
      local.additional_statements,
    )
  }) : null)

  # The identity side a consumer principal needs (DESIGN-0030 § The
  # consumer contract). AmazonEC2ContainerRegistryReadOnly / PullOnly
  # already cover it; this is the minimal equivalent for hand-scoped
  # roles in accounts this repo does not manage.
  consumer_identity_policy_json = (length(local.pull_prefixes) == 0 ? null : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthorizationToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid      = "RegistryPull"
        Effect   = "Allow"
        Action   = local.pull_actions
        Resource = local.pull_repository_arns
      },
    ]
  }))
}
