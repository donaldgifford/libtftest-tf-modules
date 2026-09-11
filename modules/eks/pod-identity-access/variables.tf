#--------------------------------------------------------------
# Required inputs
#--------------------------------------------------------------

variable "remote_state_bucket" {
  description = "S3 bucket holding the cluster module's remote state. Used by data.terraform_remote_state.eks per ADR-0001."
  type        = string
  nullable    = false
}

variable "region" {
  description = "AWS region. Also feeds the remote-state key convention <region>/eks/<cluster_name>/terraform.tfstate."
  type        = string
  nullable    = false
}

variable "cluster_name" {
  description = "EKS cluster name. Used as the remote-state key fragment and as the association's cluster_name."
  type        = string
  nullable    = false
}

# Terragrunt-injected multi-account remote-state inputs (IMPL-0015). In
# production these come from Terragrunt includes; in tests from the shared
# test/fixtures/terragrunt-inputs.tfvars via the `just tf test*` recipes.
# Required (no default) — production always injects them and a wrong default
# would silently mis-scope the cross-account remote-state read.

variable "account_name" {
  description = "Terragrunt account name — the <account_name> prefix of the account-scoped remote-state key this module reads (<account_name>/<region>/eks/<cluster_name>/terraform.tfstate)."
  type        = string
  nullable    = false
}

variable "account_id" {
  description = "12-digit AWS account ID that owns the remote-state bucket. Composed into the assume_role role_arn (arn:aws:iam::<account_id>:role/<deploy_role_name>) for the cross-account state read."
  type        = string
  nullable    = false
}

variable "remote_state_bucket_region" {
  description = "Region of the remote-state S3 bucket — distinct from var.region (the deployment region) in production Terragrunt. The terraform_remote_state backend reads from this region."
  type        = string
  nullable    = false
}

variable "deploy_role_name" {
  description = "Name of the IAM role Terraform assumes to read the remote-state bucket cross-account. Composed into the assume_role role_arn with account_id."
  type        = string
  nullable    = false
}

variable "namespace" {
  description = "Kubernetes namespace of the target ServiceAccount. The ServiceAccount itself is created out-of-band (Helm/Kustomize/Argo) per ADR-0011."
  type        = string
  nullable    = false
}

variable "service_account" {
  description = "Kubernetes ServiceAccount name to bind to AWS credentials."
  type        = string
  nullable    = false
}

#--------------------------------------------------------------
# Mode toggle (Mode A = create role; Mode B = pass existing_role_arn)
#--------------------------------------------------------------

variable "create_role" {
  description = "When true (default), the module creates a Pod-Identity-trusting IAM role and binds the association to it. When false, the caller must pass existing_role_arn — the module creates the association only, and the four Mode A policy inputs (managed_policy_arns, customer_managed_policy_arns, inline_policies, permissions_boundary) are ACCEPTED AND IGNORED rather than rejected. That tolerance is deliberate: Terragrunt injects a uniform input set into every module regardless of use, so failing on an unused input would break the fleet's normal calling pattern (DESIGN-0027 Part C, withdrawn). Policies for a pre-existing role belong to whatever stack owns that role."
  type        = bool
  default     = true
}

variable "existing_role_arn" {
  description = "ARN of a pre-existing Pod-Identity-trusting IAM role. Required when create_role = false; ignored when create_role = true. The cross-variable invariant is enforced via lifecycle.precondition on aws_eks_pod_identity_association.this (terraform >= 1.1 cannot reference other variables in a variable.validation block)."
  type        = string
  default     = null
}

#--------------------------------------------------------------
# Naming
#--------------------------------------------------------------

variable "role_name_override" {
  description = "Override the default deterministic role name (<cluster_name>-<namespace>-<service_account>). Use sparingly — the default name surfaces the binding for free in the console / IAM audits."
  type        = string
  default     = null
}

#--------------------------------------------------------------
# Mode A policy inputs
#--------------------------------------------------------------

variable "managed_policy_arns" {
  description = "AWS-managed policy ARNs to attach to the Mode A role (e.g. arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy). Only the aws-owned pseudo-account spelling is accepted — caller-owned ARNs belong in customer_managed_policy_arns. MODE B: ignored when create_role = false — the module attaches nothing to a role it does not own, so policies for a pre-existing role belong to whatever stack owns that role."
  type        = list(string)
  default     = []

  # DESIGN-0027 Part B — mirrored verbatim from iam/role, where the
  # IMPL-0022 security review added it. The channel split is
  # advertised as a plan-readability contract, so enforce it rather
  # than trust it. This partition ALSO closes the cross-channel
  # duplicate hazard structurally: an ARN cannot match both this rule
  # and the customer one (the account field is "aws" or 12 digits,
  # never both), so the same policy can no longer be listed in two
  # channels. That mattered because AttachRolePolicy is idempotent —
  # two resources would manage one real attachment, and dropping the
  # ARN from one channel would DETACH the policy while the other
  # channel still declared it, printing "1 to destroy" with no hint
  # the grant survives in config. Anyone loosening these regexes
  # (e.g. for aws-cn / aws-us-gov) must keep the account field
  # mutually exclusive or restore that guard as a precondition.
  validation {
    condition     = alltrue([for a in var.managed_policy_arns : can(regex("^arn:aws:iam::aws:policy/.+$", a))])
    error_message = "Every managed_policy_arns entry must be an AWS-managed policy ARN (arn:aws:iam::aws:policy/...). Caller-owned policies belong in customer_managed_policy_arns."
  }
}

variable "customer_managed_policy_arns" {
  description = "Customer-managed policy ARNs to attach to the Mode A role. Separate from managed_policy_arns so the plan distinguishes AWS-owned from caller-owned policy ARNs at a glance, and so the same ARN cannot be listed in both channels. MODE B: ignored when create_role = false."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.customer_managed_policy_arns : can(regex("^arn:aws:iam::[0-9]{12}:policy/.+$", a))])
    error_message = "Every customer_managed_policy_arns entry must be a customer-managed policy ARN (arn:aws:iam::<12-digit-account>:policy/...). AWS-managed policies belong in managed_policy_arns."
  }
}

variable "inline_policies" {
  description = "Inline IAM policy documents to attach to the Mode A role, keyed by policy name. Values are JSON strings. MODE B: ignored when create_role = false."
  type        = map(string)
  default     = {}

  # Scope, precisely: this proves the value PARSES, nothing more. A
  # well-formed document that is not a policy ({"foo":1}) passes here
  # and still fails at apply. Statement-level validity is the
  # caller's concern by design.
  validation {
    condition     = alltrue([for doc in values(var.inline_policies) : can(jsondecode(doc))])
    error_message = "Every inline_policies value must parse as JSON — unparseable documents are a guaranteed apply-time MalformedPolicyDocument; this catches that class at plan."
  }
}

variable "permissions_boundary" {
  description = "ARN of an IAM permissions boundary policy to attach to the Mode A role. MODE B: ignored when create_role = false. Null (default) attaches no boundary. An EMPTY STRING is rejected rather than treated as null: the provider omits the argument on create and takes the DeleteRolePermissionsBoundary branch on update, so \"\" reads as \"bounded\" in a plan and applies as NO boundary — including silently stripping the boundary off an existing role. Pass null explicitly, never a defaulted-to-empty lookup."
  type        = string
  default     = null

  # The empty string is the one value here that is both accepted by
  # the provider's ARN validator and semantically the opposite of
  # what it looks like (IMPL-0022 F1, found live on iam/role).
  validation {
    condition     = var.permissions_boundary == null || can(regex("^arn:aws:iam::(aws|[0-9]{12}):policy/.+$", var.permissions_boundary))
    error_message = "permissions_boundary must be null (no boundary) or an IAM policy ARN — an empty string reads as \"bounded\" in a plan and applies as NO boundary."
  }
}

#--------------------------------------------------------------
# Tags
#--------------------------------------------------------------

variable "tags" {
  description = "Tags applied to the Mode A IAM role."
  type        = map(string)
  default     = {}
}

variable "association_tags" {
  description = "Tags applied to the aws_eks_pod_identity_association resource. Separate from var.tags so callers can label the association independently of the role (useful when migrating ownership)."
  type        = map(string)
  default     = {}
}
