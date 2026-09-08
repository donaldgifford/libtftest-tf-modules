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
  description = "Exact IAM principal ARNs (roles or users) granted sts:AssumeRole on this role. At least one is required — a role nobody can assume is dead weight. Wildcards are rejected: this typed surface exists to prevent the fail-open a JSON trust channel would allow. Entries must be the REAL, path-bearing ARNs — IAM validates principals when the policy is saved, and role names are account-unique regardless of path, so a path-stripped spelling of a path-bearing role fails the apply rather than matching anything else. Service principals belong to the resource-owning modules (see the README Non-Goals)."
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

  # Duplicates change no behavior (IAM dedupes principals at policy
  # save), but the trust list is an audit surface reviewers count:
  # a repeated ARN misstates the principal count (OQ 2a).
  validation {
    condition     = length(var.trusted_role_arns) == length(distinct(var.trusted_role_arns))
    error_message = "trusted_role_arns must not repeat a principal — the trust list is an audit surface and states each principal exactly once."
  }

  nullable = false
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
  description = "ARN of an IAM policy to attach as this role's permissions boundary. Null (default) attaches no boundary."
  type        = string
  default     = null
}

#--------------------------------------------------------------
# Policy channels (DESIGN-0025 OQ 3a — the eks/pod-identity-access
# surface, so the fleet has ONE way to express role policies.
# Attach-only: standalone aws_iam_policy creation is the future
# iam/policy sibling's concern, not this module's.)
#--------------------------------------------------------------

variable "managed_policy_arns" {
  description = "AWS-managed policy ARNs to attach to this role (e.g. arn:aws:iam::aws:policy/ReadOnlyAccess)."
  type        = list(string)
  default     = []

  nullable = false
}

variable "customer_managed_policy_arns" {
  description = "Customer-managed policy ARNs to attach to this role. Separate from managed_policy_arns so the plan distinguishes AWS-owned from caller-owned policy ARNs at a glance."
  type        = list(string)
  default     = []

  nullable = false
}

variable "inline_policies" {
  description = "Inline IAM policy documents to attach to this role, keyed by policy name. Values are JSON strings — compose them with data.aws_iam_policy_document in the calling stack. These are AUTHORIZATION documents; no credential ever rides this channel."
  type        = map(string)
  default     = {}

  # OQ 1a: the surface SHAPE is the pod-identity-access mirror, but a
  # malformed document is a guaranteed apply-time
  # MalformedPolicyDocument — cheap to move to plan time. (Follow-up:
  # backport this validation to eks/pod-identity-access so the mirror
  # stays honest in both directions.)
  validation {
    condition     = alltrue([for doc in values(var.inline_policies) : can(jsondecode(doc))])
    error_message = "Every inline_policies value must be a valid JSON document — IAM rejects malformed documents at apply (MalformedPolicyDocument); this catches it at plan."
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
