#--------------------------------------------------------------
# The consumer allow-list
#
# Keyed by 12-digit account ID (DESIGN-0030 OQ 2a): order-stable, and
# duplicate accounts are impossible by construction. Each validation is
# its own block so every rejection run can be verified against the rule
# it names (IMPL-0020: expect_failures proves the variable errored, not
# which rule fired).
#--------------------------------------------------------------

variable "consumer_accounts" {
  description = "Accounts allowed to PULL from pull_repository_prefixes, keyed by 12-digit account ID. Each account is granted as arn:aws:iam::<id>:root, meaning that account's own IAM decides which of its principals may pull (not the root user). principal_arn_patterns optionally narrows an account to ArnLike patterns on aws:PrincipalArn (for example arn:aws:iam::<id>:role/*-node-*); patterns must name the same account. Every listed account is also explicitly DENIED all ECR actions on protected_prefixes. A typo in an account ID grants to a stranger's account, so review this map like a trust policy."
  type = map(object({
    principal_arn_patterns = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for id in keys(var.consumer_accounts) : can(regex("^[0-9]{12}$", id))])
    error_message = "consumer_accounts keys must be 12-digit AWS account IDs."
  }

  # A pattern naming a different account matches nothing, so the account
  # would silently get NO access.
  validation {
    condition = alltrue(flatten([
      for id, acct in var.consumer_accounts : [
        for p in acct.principal_arn_patterns : startswith(p, "arn:aws:iam::${id}:")
      ]
    ]))
    error_message = "every principal_arn_patterns entry must start with arn:aws:iam::<that account's id>: — a pattern naming another account matches nothing and silently grants the account no access."
  }

  validation {
    condition = alltrue(flatten([
      for acct in values(var.consumer_accounts) : [
        for p in acct.principal_arn_patterns : can(regex("^\\S+$", p))
      ]
    ]))
    error_message = "principal_arn_patterns entries must not contain whitespace."
  }

  # arn:aws:iam::<id>:* matches every principal in the account, which is
  # exactly what no narrowing means. Writing it as a pattern reads as a
  # restriction while restricting nothing.
  validation {
    condition = alltrue(flatten([
      for id, acct in var.consumer_accounts : [
        for p in acct.principal_arn_patterns : p != "arn:aws:iam::${id}:*"
      ]
    ]))
    error_message = "principal_arn_patterns must not contain arn:aws:iam::<id>:* — it matches every principal, which is the same as no narrowing. Use an empty list instead."
  }

  validation {
    condition = alltrue([
      for acct in values(var.consumer_accounts) :
      length(distinct(acct.principal_arn_patterns)) == length(acct.principal_arn_patterns)
    ])
    error_message = "principal_arn_patterns must not contain duplicates within an account."
  }

  # Cross-variable (>= 1.9): accounts with nothing to read are a silent
  # no-op.
  validation {
    condition     = length(var.consumer_accounts) == 0 || length(var.pull_repository_prefixes) > 0
    error_message = "consumer_accounts is non-empty but pull_repository_prefixes is empty — the accounts would be granted nothing. List the prefixes they may pull."
  }

  nullable = false
}

#--------------------------------------------------------------
# Prefix scoping
#
# The grant is a prefix ALLOW-LIST that fails closed (INV-0012 F6): a
# new prefix is unreadable cross-account until someone lists it here.
#--------------------------------------------------------------

variable "pull_repository_prefixes" {
  description = "Repository prefixes the consumer accounts may pull, without a trailing slash (for example [\"mirror\", \"apps\"]). Each renders as arn:aws:ecr:<region>:<account>:repository/<prefix>/*. Must follow the ECR repository-name grammar (lowercase; no '*', no leading or trailing '/'), so a registry-wide repository/* grant is unrepresentable. Must not equal, contain, or sit inside a protected prefix."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.pull_repository_prefixes : can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", p))])
    error_message = "pull_repository_prefixes entries must follow the ECR repository-name grammar: lowercase alphanumerics separated by '.', '_' or '-', path segments joined by single '/', no '*' and no leading or trailing '/'."
  }

  validation {
    condition     = length(distinct(var.pull_repository_prefixes)) == length(var.pull_repository_prefixes)
    error_message = "pull_repository_prefixes must not contain duplicates."
  }

  # Cross-variable (>= 1.9). Overlap in either direction: quarantine,
  # quarantine/mirror, and a parent of quarantine are all rejected.
  validation {
    condition = alltrue(flatten([
      for p in var.pull_repository_prefixes : [
        for q in var.protected_prefixes :
        !(p == q || startswith(p, "${q}/") || startswith(q, "${p}/"))
      ]
    ]))
    error_message = "pull_repository_prefixes must not equal, sit inside, or contain a protected prefix (protected_prefixes, default [\"quarantine\"])."
  }

  nullable = false
}

variable "protected_prefixes" {
  description = "Repository prefixes no consumer account may ever touch (default [\"quarantine\"], where unvetted images wait for intake). Enforced twice: a plan-time overlap check against pull_repository_prefixes, and an explicit ConsumerDenyProtected statement denying every listed account all ECR actions on these prefixes. Set [] only if the registry has no such prefix."
  type        = list(string)
  default     = ["quarantine"]

  validation {
    condition     = alltrue([for p in var.protected_prefixes : can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", p))])
    error_message = "protected_prefixes entries must follow the ECR repository-name grammar: lowercase alphanumerics separated by '.', '_' or '-', path segments joined by single '/', no '*' and no leading or trailing '/'."
  }

  validation {
    condition     = length(distinct(var.protected_prefixes)) == length(var.protected_prefixes)
    error_message = "protected_prefixes must not contain duplicates."
  }

  nullable = false
}

#--------------------------------------------------------------
# Additional registry-policy statements
#
# This module is the registry policy's ONLY owner, so any other
# registry-level grant (for example a cross-account replication source)
# has to come through here. Rendered as given and appended after the
# module's statements. The module does NOT inspect them for widening:
# that is code review's job (DESIGN-0030 OQ 8a).
#--------------------------------------------------------------

variable "additional_policy_statements" {
  description = "Extra registry-policy statements, appended unchanged after the module's own. sids must be alphanumeric, unique, and must not start with the reserved 'Consumer' prefix. principals[].type is AWS or Service; actions must be ecr: actions. Conditions sharing a test operator merge into one operator object. These are not checked for widening: a statement granting a consumer repository/* still cannot reach a protected prefix, because the module's explicit Deny wins."
  type = list(object({
    sid    = string
    effect = string
    principals = list(object({
      type        = string
      identifiers = list(string)
    }))
    actions   = list(string)
    resources = list(string)
    conditions = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
  }))
  default = []

  validation {
    condition     = alltrue([for st in var.additional_policy_statements : can(regex("^[A-Za-z0-9]+$", st.sid))])
    error_message = "additional_policy_statements sids must be alphanumeric (IAM's sid grammar)."
  }

  validation {
    condition     = length(distinct([for st in var.additional_policy_statements : st.sid])) == length(var.additional_policy_statements)
    error_message = "additional_policy_statements sids must be unique."
  }

  validation {
    condition     = alltrue([for st in var.additional_policy_statements : !startswith(st.sid, "Consumer")])
    error_message = "additional_policy_statements sids must not start with 'Consumer', which is reserved for the module's ConsumerPull* and ConsumerDenyProtected statements."
  }

  validation {
    condition     = alltrue([for st in var.additional_policy_statements : contains(["Allow", "Deny"], st.effect)])
    error_message = "additional_policy_statements effect must be Allow or Deny."
  }

  validation {
    condition     = alltrue(flatten([for st in var.additional_policy_statements : [for a in st.actions : startswith(a, "ecr:")]]))
    error_message = "additional_policy_statements actions must be ecr: actions — a registry policy governs ECR only."
  }

  validation {
    condition     = alltrue(flatten([for st in var.additional_policy_statements : [for p in st.principals : contains(["AWS", "Service"], p.type)]]))
    error_message = "additional_policy_statements principals[].type must be AWS or Service."
  }

  nullable = false
}

#--------------------------------------------------------------
# Registry policy scope
#--------------------------------------------------------------

variable "manage_registry_policy_scope" {
  description = "Pin the account's REGISTRY_POLICY_SCOPE to V2, which pull grants in a registry policy require (V1 covers only replication and pull-through-cache actions, and a V1 registry is expected to reject the pull grant outright). Set false only when the scope is managed elsewhere AND the registry is already on V2."
  type        = bool
  default     = true
  nullable    = false
}

#--------------------------------------------------------------
# Scanning (off by default, DESIGN-0030 OQ 7a)
#--------------------------------------------------------------

variable "scanning" {
  description = "Registry scanning configuration. null (default) manages nothing and leaves the registry's existing scanning setup alone; it does not disable scanning. A non-null value TAKES OWNERSHIP: it replaces the registry's whole scanning configuration. BASIC allows SCAN_ON_PUSH and MANUAL; ENHANCED allows SCAN_ON_PUSH and CONTINUOUS_SCAN, and enables Amazon Inspector billing for the account. filters are WILDCARD repository filters (for example \"quarantine/*\")."
  type = object({
    scan_type = string
    rules = list(object({
      scan_frequency = string
      filters        = list(string)
    }))
  })
  default = null

  validation {
    condition     = var.scanning == null || contains(["BASIC", "ENHANCED"], try(var.scanning.scan_type, ""))
    error_message = "scanning.scan_type must be BASIC or ENHANCED."
  }

  # Server-side contract, validated here because nothing else will catch
  # it before apply (the IMPL-0023 lesson).
  validation {
    condition = var.scanning == null || alltrue([
      for r in try(var.scanning.rules, []) : contains(
        try(var.scanning.scan_type, "") == "ENHANCED" ? ["SCAN_ON_PUSH", "CONTINUOUS_SCAN"] : ["SCAN_ON_PUSH", "MANUAL"],
        r.scan_frequency,
      )
    ])
    error_message = "scanning rule scan_frequency must match scan_type: BASIC allows SCAN_ON_PUSH or MANUAL; ENHANCED allows SCAN_ON_PUSH or CONTINUOUS_SCAN."
  }

  validation {
    condition     = var.scanning == null || alltrue([for r in try(var.scanning.rules, []) : length(r.filters) > 0])
    error_message = "every scanning rule needs at least one repository filter."
  }
}
