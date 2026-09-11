#--------------------------------------------------------------
# Identity (DESIGN-0025 — the naming posture is fixed by the fleet:
# consumers reference this role BY NAME)
#--------------------------------------------------------------

variable "name" {
  description = "Exact IAM role name — no prefix, no suffixing. Consumers reference this role BY NAME (every ADR-0020 remote-state read composes arn:aws:iam::<account_id>:role/<deploy_role_name> and assumes it), so the physical name IS the contract. Changing it replaces the role."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9+=,.@_-]+$", var.name))
    error_message = "name must use the IAM role-name charset: alphanumerics and +=,.@_- (no spaces, no slashes — a path belongs in var.path)."
  }

  validation {
    condition     = length(var.name) >= 1 && length(var.name) <= 64
    error_message = "name must be 1-64 characters (the IAM role-name limit)."
  }

  nullable = false
}

variable "path" {
  description = "IAM path for the role (default \"/\"). CAUTION: a non-default path gives the role TWO legitimate ARN spellings — path-bearing (arn:...:role/team/Name, what IAM returns) and path-stripped (arn:...:role/Name) — and spelling mismatches are exactly where guards and validations get evaded (IMPL-0020's collision guard normalizes for this reason). Keep \"/\" for roles destined for an eks/access-entries binding: how the EKS API canonicalizes path-bearing principal ARNs is unverified until IMPL-0020 task 5.4's live runs answer it."
  type        = string
  default     = "/"

  validation {
    condition     = can(regex("^/([a-zA-Z0-9+=,.@_-]+/)*$", var.path))
    error_message = "path must begin and end with \"/\" and contain only the IAM path charset (e.g. \"/\" or \"/platform/\")."
  }

  nullable = false
}

variable "description" {
  description = "Human-readable description of what this role is for and who assumes it. Updates in place (no replacement)."
  type        = string
  default     = null
}

#--------------------------------------------------------------
# Trust surface (DESIGN-0025 OQ 1a — ARN-only, fail-closed; no
# service principals and no raw-JSON channel, both deliberately.
# Each rule is its own validation block so a rejection run can be
# verified to fail on the rule it names, IMPL-0022 task 1.7.)
#--------------------------------------------------------------

variable "trusted_role_arns" {
  description = "Exact IAM principal ARNs (roles or users) granted sts:AssumeRole on this role. At least one is required — a role nobody can assume is dead weight. Wildcards are rejected: this typed surface exists to prevent the fail-open a JSON trust channel would allow. Entries must be the REAL, path-bearing ARNs. CAUTION — the apply-time backstop is SAME-ACCOUNT ONLY: IAM resolves a same-account principal to its unique id when the policy is saved, so a wrong spelling there fails the apply; a CROSS-ACCOUNT ARN is stored as an unvalidated literal string, so a typo applies green, grants nobody, and leaves a dangling principal that whoever later creates a role by that name inherits. Both worked examples in the README are cross-account, so treat these ARNs as unverified input and pair the cross-account instances with a trust condition (DESIGN-0025 Follow-up 1). Service principals belong to the resource-owning modules (see the README Non-Goals)."
  type        = list(string)

  validation {
    condition     = length(var.trusted_role_arns) > 0
    error_message = "trusted_role_arns must name at least one principal — a role nobody can assume is dead weight."
  }

  validation {
    condition = alltrue([
      for a in var.trusted_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/.+$", a))
    ])
    error_message = "Every trusted_role_arns entry must be an exact IAM role or user ARN: arn:aws:iam::<12-digit-account>:role/<name> (or :user/<name>). Service principals (e.g. pods.eks.amazonaws.com) are not accepted here."
  }

  validation {
    condition = alltrue([
      for a in var.trusted_role_arns : !can(regex("[*?]", a))
    ])
    error_message = "trusted_role_arns must not contain wildcard characters (* or ?) — trust is granted to named principals only."
  }

  # A padded ARN passes the format regex above (".+$" happily matches
  # a trailing space) and reaches Principal.AWS verbatim, where it
  # resolves to nothing — the realistic copy-paste artifact. Leading
  # whitespace and embedded newlines are already rejected by the
  # anchors (Go RE2 "$" is end-of-text without the "m" flag).
  validation {
    condition     = alltrue([for a in var.trusted_role_arns : a == trimspace(a)])
    error_message = "trusted_role_arns entries must carry no leading or trailing whitespace — a padded ARN passes the format check and reaches the trust policy verbatim, where it matches no principal at all."
  }

  # Duplicates change no behavior (IAM dedupes principals at policy
  # save), but the trust list is an audit surface reviewers count:
  # a repeated ARN misstates the principal count (OQ 2a).
  #
  # Compared NORMALIZED — <account>/<name>, lowercased and
  # path-stripped — not as raw strings, because one role has two
  # legitimate ARN spellings (see var.path) and IAM role names are
  # account-unique CASE-INSENSITIVELY. A raw distinct() lets both
  # evasions through, which is the IMPL-0020 collision-guard lesson.
  # element() is used over [] indexing because it wraps rather than
  # erroring, so this rule stays evaluable on a malformed ARN that
  # the format rule above is what should reject.
  validation {
    condition = length(var.trusted_role_arns) == length(distinct([
      for a in var.trusted_role_arns :
      lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))
    ]))
    error_message = "trusted_role_arns must not name the same principal twice — compared as normalized <account>/<name>, lowercased and path-stripped, because one role has two legitimate ARN spellings and IAM role names are case-insensitively unique."
  }

  nullable = false
}

#--------------------------------------------------------------
# Trust conditions (DESIGN-0027 Part A — the DESIGN-0025 Follow-up 1
# surface, promoted by the IMPL-0022 security review from
# "expected sooner rather than later" to a PREREQUISITE for the
# cross-account instances.
#
# Both compose into the SINGLE existing trust statement. See
# trust.tf for why that placement is a security invariant.)
#--------------------------------------------------------------

variable "require_org_ids" {
  description = "AWS Organization ids (o-...) whose principals may assume this role, ANDed onto the trust statement as StringEquals on aws:PrincipalOrgID. Empty (default) adds no condition. SCOPE, stated honestly: this mitigates the cross-account dangling-principal hazard — IAM stores a cross-account principal ARN unvalidated, so a typo grants nobody but leaves the name claimable, and an org condition means whoever claims it must ALSO be in one of these organizations. It does NOTHING for a typo naming a nonexistent role INSIDE the org. Correct ARNs remain the primary control."
  type        = list(string)
  default     = []

  # Empty-string entries are the F1 lesson applied preemptively: one
  # would render "aws:PrincipalOrgID": [""], a condition no principal
  # can satisfy. That fails CLOSED, so it is not a hole — but it is an
  # unexplained total lockout, and the regex costs one block.
  validation {
    condition     = alltrue([for o in var.require_org_ids : can(regex("^o-[a-z0-9]{10,32}$", o))])
    error_message = "Every require_org_ids entry must be an AWS organization id: o- followed by 10-32 lowercase alphanumerics (e.g. o-a1b2c3d4e5)."
  }

  # An audit surface, like trusted_role_arns. Unlike ARNs, org ids are
  # lowercase-canonical by format and have no path or case variants —
  # so a plain distinct() is sufficient here and normalizing would be
  # theatre (DESIGN-0027).
  validation {
    condition     = length(var.require_org_ids) == length(distinct(var.require_org_ids))
    error_message = "require_org_ids must not repeat an organization — the condition is an audit surface and states each org exactly once."
  }

  nullable = false
}

variable "external_id" {
  description = "Value the caller must present as sts:ExternalId to assume this role — the classic confused-deputy control for a trust granted to a third party. Null (default) adds no condition. It is a unique, unpredictable identifier and NOT a secret: AWS documents it as such, and it appears in CloudTrail requestParameters.externalId on both sides of the AssumeRole as well as in plan output and state. Singular by design: it keys one relationship, so a list of accepted values would mean \"any of these will do\". DO NOT set this on a role the fleet's data.terraform_remote_state blocks assume (the deploy role) unless you add a matching external_id to every one of those blocks in the same change — otherwise every consumer plan fleet-wide fails AccessDenied on the NEXT plan, not on the apply that caused it."
  type        = string
  default     = null

  # Charset and length are SEPARATE rules, and not only for the usual
  # one-rule-one-message reason: Go's RE2 caps a bounded repeat at
  # 1000, so the obvious "{2,1224}" spelling is an INVALID regex.
  # can() swallows that error and returns false, which would have made
  # this rule reject every non-null value — fail-closed, but total.
  # Probed and caught before a single test was written (IMPL-0024
  # task 1.4); do not re-merge these into one bounded-repeat regex.
  validation {
    condition     = var.external_id == null || can(regex("^[\\w+=,.@:/-]+$", var.external_id))
    error_message = "external_id must use the AWS-documented external-id charset: alphanumerics, underscore, and +=,.@:/- only."
  }

  validation {
    condition     = var.external_id == null || (length(var.external_id) >= 2 && length(var.external_id) <= 1224)
    error_message = "external_id must be between 2 and 1224 characters (the AWS-enforced range)."
  }
}

variable "max_session_duration" {
  description = "Maximum session duration in seconds for sessions assumed into this role (AWS default 3600 = 1 hour, maximum 43200 = 12 hours)."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 (1 hour) and 43200 (12 hours) seconds — the IAM-enforced range."
  }

  nullable = false
}

variable "permissions_boundary" {
  description = "ARN of an IAM policy to attach as this role's permissions boundary. Null (default) attaches no boundary. An EMPTY STRING is rejected rather than treated as null: the provider omits the argument on create and takes the DeleteRolePermissionsBoundary branch on update, so \"\" reads as \"bounded\" in a plan and applies as NO boundary — including silently stripping the boundary off an existing role. Pass null explicitly, never a defaulted-to-empty lookup."
  type        = string
  default     = null

  # The empty string is the one value here that is both accepted by
  # the provider's ARN validator and semantically the opposite of what
  # it looks like. A live-repo `try(dependency.x.outputs.arn, "")` or
  # a lookup miss is all it takes.
  validation {
    condition     = var.permissions_boundary == null || can(regex("^arn:aws:iam::(aws|[0-9]{12}):policy/.+$", var.permissions_boundary))
    error_message = "permissions_boundary must be null (no boundary) or an IAM policy ARN — an empty string reads as \"bounded\" in a plan and applies as NO boundary."
  }
}

#--------------------------------------------------------------
# Policy channels (DESIGN-0025 OQ 3a — the eks/pod-identity-access
# surface, so the fleet has ONE way to express role policies.
# Attach-only: standalone aws_iam_policy creation is the future
# iam/policy sibling's concern, not this module's.)
#--------------------------------------------------------------

variable "managed_policy_arns" {
  description = "AWS-managed policy ARNs to attach to this role (e.g. arn:aws:iam::aws:policy/ReadOnlyAccess). Only the aws-owned pseudo-account spelling is accepted — caller-owned ARNs belong in customer_managed_policy_arns."
  type        = list(string)
  default     = []

  # The channel split is advertised as a plan-readability contract, so
  # enforce it rather than trusting it. This partition ALSO closes the
  # cross-channel duplicate hazard structurally: an ARN cannot match
  # both this rule and the customer one (the account field is "aws" or
  # 12 digits, never both), so the same policy can no longer be listed
  # in two channels. That mattered because AttachRolePolicy is
  # idempotent — two resources would manage one real attachment, and
  # dropping the ARN from one channel would DETACH the policy while
  # the other channel still declared it, printing "1 to destroy" with
  # no hint the grant survives in config. Anyone loosening these
  # regexes (e.g. for aws-cn / aws-us-gov) must keep the account field
  # mutually exclusive or restore that guard as a precondition.
  validation {
    condition     = alltrue([for a in var.managed_policy_arns : can(regex("^arn:aws:iam::aws:policy/.+$", a))])
    error_message = "Every managed_policy_arns entry must be an AWS-managed policy ARN (arn:aws:iam::aws:policy/...). Caller-owned policies belong in customer_managed_policy_arns."
  }

  nullable = false
}

variable "customer_managed_policy_arns" {
  description = "Customer-managed policy ARNs to attach to this role. Separate from managed_policy_arns so the plan distinguishes AWS-owned from caller-owned policy ARNs at a glance, and so the same ARN cannot be listed in both channels."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.customer_managed_policy_arns : can(regex("^arn:aws:iam::[0-9]{12}:policy/.+$", a))])
    error_message = "Every customer_managed_policy_arns entry must be a customer-managed policy ARN (arn:aws:iam::<12-digit-account>:policy/...). AWS-managed policies belong in managed_policy_arns."
  }

  nullable = false
}

variable "inline_policies" {
  description = "Inline IAM policy documents to attach to this role, keyed by policy name. Values are JSON strings — compose them with data.aws_iam_policy_document in the calling stack. These are AUTHORIZATION documents; no credential ever rides this channel."
  type        = map(string)
  default     = {}

  # OQ 1a: the surface SHAPE is the pod-identity-access mirror, plus
  # this parse check — unparseable JSON is a guaranteed apply-time
  # MalformedPolicyDocument, cheap to move to plan time. (Follow-up:
  # backport it to eks/pod-identity-access so the mirror stays honest
  # in both directions.)
  #
  # Scope, precisely: this proves the value PARSES, nothing more. A
  # well-formed document that is not a policy ({"foo":1}) passes here
  # and still fails at apply. The provider's own validIAMPolicyJSON
  # separately rejects a JSON array at plan. Statement-level validity
  # is the caller's concern by design.
  validation {
    condition     = alltrue([for doc in values(var.inline_policies) : can(jsondecode(doc))])
    error_message = "Every inline_policies value must parse as JSON — unparseable documents are a guaranteed apply-time MalformedPolicyDocument; this catches that class at plan."
  }

  nullable = false
}

#--------------------------------------------------------------
# Tags
#--------------------------------------------------------------

variable "tags" {
  description = "Tags applied to the IAM role."
  type        = map(string)
  default     = {}

  nullable = false
}
