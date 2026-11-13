#--------------------------------------------------------------
# Identity
#--------------------------------------------------------------

variable "name" {
  description = "Instance name, used for the template IAM role (<name>-ecr-templates) and the intake event rule (<name>-quarantine-push). Use a placeholder-style name (for example example-intake). Renaming replaces both."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,40}$", var.name))
    error_message = "name must be 1-40 characters of alphanumerics, '_' or '-' (it is suffixed into an IAM role name and an EventBridge rule name, both capped at 64)."
  }

  nullable = false
}

#--------------------------------------------------------------
# Repository layout (DESIGN-0031 § Repository layout)
#
# Prefixes use the ECR repository-name grammar (the ecr/registry
# rule): lowercase segments of [a-z0-9] joined by '.', '_' or '-',
# separated by '/'. No leading or trailing slash.
#--------------------------------------------------------------

variable "quarantine_prefix" {
  description = "Prefix of the quarantine template. Writers push here; images expire after quarantine_retention_days; only writers, intake and admins can read or write it. Never list it in ecr/registry's pull_repository_prefixes (that module's protected_prefixes default already denies it)."
  type        = string
  default     = "quarantine"

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", var.quarantine_prefix))
    error_message = "quarantine_prefix must follow the ECR repository-name grammar: lowercase [a-z0-9] segments joined by '.', '_' or '-', separated by '/', with no leading or trailing slash."
  }

  nullable = false
}

variable "quarantine_retention_days" {
  description = "Days after push at which EVERY quarantined image expires (sinceImagePushed). Quarantine is a staging area, not a store: intake promotes by digest well inside the window."
  type        = number
  default     = 7

  validation {
    condition     = var.quarantine_retention_days >= 1 && var.quarantine_retention_days <= 30 && floor(var.quarantine_retention_days) == var.quarantine_retention_days
    error_message = "quarantine_retention_days must be a whole number from 1 to 30."
  }

  nullable = false
}

variable "promoted_prefixes" {
  description = "Promoted prefixes, one creation template each: IMMUTABLE_WITH_EXCLUSION tags, no lifecycle policy, writes by intake and admins only, policy changes by admins only. Keys are prefixes; feed the promoted_prefixes output to ecr/registry's pull_repository_prefixes to share them. The default exclusion sha256-* keeps cosign's legacy .sig/.att tags appendable."
  type = map(object({
    description               = optional(string)
    tag_mutability_exclusions = optional(list(string), ["sha256-*"])
  }))
  default = { mirror = {} }

  validation {
    condition     = length(var.promoted_prefixes) > 0
    error_message = "promoted_prefixes must name at least one prefix: intake needs somewhere to promote to."
  }

  validation {
    condition     = alltrue([for p in keys(var.promoted_prefixes) : can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", p))])
    error_message = "Every promoted_prefixes key must follow the ECR repository-name grammar: lowercase [a-z0-9] segments joined by '.', '_' or '-', separated by '/', with no leading or trailing slash."
  }

  # Parent/child between two promoted prefixes: ECR applies the most
  # specific template, so a nested prefix would silently swap the
  # outer template's policy for its own on part of the namespace.
  validation {
    condition = alltrue(flatten([
      for a in keys(var.promoted_prefixes) : [
        for b in keys(var.promoted_prefixes) : !startswith(b, "${a}/")
      ]
    ]))
    error_message = "promoted_prefixes must not nest: no key may be a parent of another (for example mirror and mirror/charts)."
  }

  # Cross-variable (>= 1.9). Equal, parent or child of quarantine would
  # let a promoted template's policy (no expiry, reads unrestricted)
  # govern quarantined images, or the reverse.
  validation {
    condition = alltrue([
      for p in keys(var.promoted_prefixes) :
      p != var.quarantine_prefix && !startswith(p, "${var.quarantine_prefix}/") && !startswith(var.quarantine_prefix, "${p}/")
    ])
    error_message = "promoted_prefixes must not equal, contain or sit inside quarantine_prefix."
  }

  # The provider and the ECR API both cap exclusion filters at five per
  # template (provider schema: max_items = 5). At least one is required
  # because IMMUTABLE_WITH_EXCLUSION with none is just IMMUTABLE.
  validation {
    condition = alltrue([
      for p in values(var.promoted_prefixes) :
      length(p.tag_mutability_exclusions) >= 1 && length(p.tag_mutability_exclusions) <= 5
    ])
    error_message = "Each promoted prefix needs 1 to 5 tag_mutability_exclusions (the ECR limit is five per template)."
  }

  validation {
    condition = alltrue(flatten([
      for p in values(var.promoted_prefixes) : [
        for f in p.tag_mutability_exclusions : can(regex("^[0-9a-zA-Z._*-]{1,128}$", f))
      ]
    ]))
    error_message = "Each tag_mutability_exclusions filter must be 1-128 characters of alphanumerics, '.', '_', '-' or the '*' wildcard (no whitespace)."
  }

  validation {
    condition = alltrue([
      for p in values(var.promoted_prefixes) :
      length(p.tag_mutability_exclusions) == length(distinct(p.tag_mutability_exclusions))
    ])
    error_message = "tag_mutability_exclusions must not repeat a filter within one prefix."
  }

  nullable = false
}

#--------------------------------------------------------------
# Principals (DESIGN-0031 § Principal inputs and validation)
#
# Each list carries iam/role's five-rule set, one rule per block, so a
# rejection run can be verified against the rule it names.
#--------------------------------------------------------------

variable "writer_principal_arns" {
  description = "Principals that push to quarantine (the sync job's role). Same account as the registry only (DESIGN-0031 OQ 14a, enforced by a precondition). Grant them writer_policy_json."
  type        = list(string)

  validation {
    condition     = length(var.writer_principal_arns) > 0
    error_message = "writer_principal_arns must name at least one principal."
  }

  validation {
    condition     = alltrue([for a in var.writer_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/.+$", a))])
    error_message = "Every writer_principal_arns entry must be an exact IAM role or user ARN: arn:aws:iam::<12-digit-account>:role/<name> (or :user/<name>). Account roots are rejected: an exemption naming a root would exempt every principal in that account."
  }

  validation {
    condition     = alltrue([for a in var.writer_principal_arns : !can(regex("[*?]", a))])
    error_message = "writer_principal_arns must not contain wildcard characters (* or ?): the repository policies name principals exactly, and a wildcard in an ArnNotLike exemption widens it."
  }

  validation {
    condition     = alltrue([for a in var.writer_principal_arns : a == trimspace(a)])
    error_message = "writer_principal_arns entries must carry no leading or trailing whitespace: a padded ARN matches no principal, so the Deny would fire on the principal it meant to exempt."
  }

  validation {
    condition     = length(var.writer_principal_arns) == length(distinct([for a in var.writer_principal_arns : lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))]))
    error_message = "writer_principal_arns must not name the same principal twice, compared as normalized <account>/<name> (lowercased, path-stripped)."
  }

  nullable = false
}

variable "intake_principal_arns" {
  description = "Principals that read quarantine and promote into the promoted prefixes (the intake workflow's role). Grant them intake_policy_json. Must not overlap writer_principal_arns."
  type        = list(string)

  validation {
    condition     = length(var.intake_principal_arns) > 0
    error_message = "intake_principal_arns must name at least one principal."
  }

  validation {
    condition     = alltrue([for a in var.intake_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/.+$", a))])
    error_message = "Every intake_principal_arns entry must be an exact IAM role or user ARN: arn:aws:iam::<12-digit-account>:role/<name> (or :user/<name>). Account roots are rejected: an exemption naming a root would exempt every principal in that account."
  }

  validation {
    condition     = alltrue([for a in var.intake_principal_arns : !can(regex("[*?]", a))])
    error_message = "intake_principal_arns must not contain wildcard characters (* or ?): the repository policies name principals exactly, and a wildcard in an ArnNotLike exemption widens it."
  }

  validation {
    condition     = alltrue([for a in var.intake_principal_arns : a == trimspace(a)])
    error_message = "intake_principal_arns entries must carry no leading or trailing whitespace: a padded ARN matches no principal, so the Deny would fire on the principal it meant to exempt."
  }

  validation {
    condition     = length(var.intake_principal_arns) == length(distinct([for a in var.intake_principal_arns : lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))]))
    error_message = "intake_principal_arns must not name the same principal twice, compared as normalized <account>/<name> (lowercased, path-stripped)."
  }

  # Cross-variable (>= 1.9): a writer that can also promote collapses
  # "pushed" into "available", the separation the module exists for.
  validation {
    condition = length(setintersection(
      toset([for a in var.intake_principal_arns : lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))]),
      toset([for a in var.writer_principal_arns : lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))]),
    )) == 0
    error_message = "intake_principal_arns and writer_principal_arns must be disjoint: a writer that can also promote skips the intake gate."
  }

  nullable = false
}

variable "admin_principal_arns" {
  description = "Principals exempt from every Deny: they alone may change a promoted repository's policy, mutability or lifecycle, or delete it. Required, because with no admin the policy-mutation Deny would lock every principal out. Include the deploy role."
  type        = list(string)

  validation {
    condition     = length(var.admin_principal_arns) > 0
    error_message = "admin_principal_arns must name at least one principal."
  }

  validation {
    condition     = alltrue([for a in var.admin_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/.+$", a))])
    error_message = "Every admin_principal_arns entry must be an exact IAM role or user ARN: arn:aws:iam::<12-digit-account>:role/<name> (or :user/<name>). Account roots are rejected: an exemption naming a root would exempt every principal in that account."
  }

  validation {
    condition     = alltrue([for a in var.admin_principal_arns : !can(regex("[*?]", a))])
    error_message = "admin_principal_arns must not contain wildcard characters (* or ?): the repository policies name principals exactly, and a wildcard in an ArnNotLike exemption widens it."
  }

  validation {
    condition     = alltrue([for a in var.admin_principal_arns : a == trimspace(a)])
    error_message = "admin_principal_arns entries must carry no leading or trailing whitespace: a padded ARN matches no principal, so the Deny would fire on the principal it meant to exempt."
  }

  validation {
    condition     = length(var.admin_principal_arns) == length(distinct([for a in var.admin_principal_arns : lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))]))
    error_message = "admin_principal_arns must not name the same principal twice, compared as normalized <account>/<name> (lowercased, path-stripped)."
  }

  nullable = false
}

#--------------------------------------------------------------
# Encryption and events
#--------------------------------------------------------------

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for repository encryption. null (default) = AES256 (DESIGN-0031 OQ 8a). A CMK adds a cross-account question: consumers pulling from another account may also need kms:Decrypt on the key, so read the README before setting it."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be null or a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>). Aliases are not accepted."
  }
}

variable "intake_event_target" {
  description = "Optional EventBridge target for quarantine pushes (a queue, topic, event bus or state machine). null (default) creates no rule; the pattern is always exported as intake_event_pattern_json. The destination's resource policy belongs to the destination stack. role_arn is required for event-bus and state-machine targets."
  type = object({
    arn      = string
    role_arn = optional(string)
  })
  default = null

  validation {
    condition     = var.intake_event_target == null || can(regex("^arn:aws:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:.+$", var.intake_event_target.arn))
    error_message = "intake_event_target.arn must be a resource ARN (arn:aws:<service>:<region>:<account>:<resource>)."
  }

  validation {
    condition     = var.intake_event_target == null || try(var.intake_event_target.role_arn, null) == null || can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.intake_event_target.role_arn))
    error_message = "intake_event_target.role_arn must be null or an IAM role ARN."
  }

  # EventBridge rejects an event-bus or Step Functions target without a
  # role to assume; catch it at plan.
  validation {
    condition = (
      var.intake_event_target == null
      || try(var.intake_event_target.role_arn, null) != null
      || !can(regex(":event-bus/|:stateMachine:", var.intake_event_target.arn))
    )
    error_message = "intake_event_target.role_arn is required when the target is an event bus or a state machine."
  }
}
