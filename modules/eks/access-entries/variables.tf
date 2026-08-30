#--------------------------------------------------------------
# Required inputs
#--------------------------------------------------------------

variable "remote_state_bucket" {
  description = "S3 bucket holding the cluster module's remote state. Used by data.terraform_remote_state.eks per ADR-0001."
  type        = string
  nullable    = false
}

variable "region" {
  description = "AWS region. Also feeds the remote-state key convention <account_name>/<region>/eks/<cluster_name>/terraform.tfstate."
  type        = string
  nullable    = false
}

variable "cluster_name" {
  description = "EKS cluster name. Used as the remote-state key fragment and as each access entry's cluster_name (read from the cluster's remote state output at the use site, ADR-0001)."
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

#--------------------------------------------------------------
# The access entries surface (DESIGN-0024 part 1)
#--------------------------------------------------------------
#
# Keyed by LOGICAL name, not principal ARN: the key is the Terraform
# address, so it must stay stable when a principal is re-pointed
# (an SSO permission set re-mints its role suffix, a deploy role is
# recreated). policy_associations is likewise a map so adding one
# association never churns a sibling's address.
#
# Principals are direct ARNs with no resolution — spokes are separate
# AWS accounts, so the in-account regex resolution the cluster
# module's SSO path uses cannot reach them (INV-0011 F1 batch 2).

variable "access_entries" {
  description = "Generic EKS access entries: logical name -> entry. Direct principal ARNs — no resolution. policy_associations (map keyed by logical association name) grant EKS access policies with cluster or namespace scope; kubernetes_groups binds RBAC groups instead of (or alongside) policies."
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string), [])
    user_name         = optional(string)
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = optional(object({
        type       = optional(string, "cluster")
        namespaces = optional(list(string), [])
      }), {})
    })), {})
  }))
  default = {}

  # Exact IAM role/user ARNs only. A wildcard here would silently widen
  # cluster admin to every principal matching the pattern.
  validation {
    condition = alltrue([
      for k, e in var.access_entries :
      can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/.+$", e.principal_arn)) && !strcontains(e.principal_arn, "*")
    ])
    error_message = "Every access_entries[*].principal_arn must be an exact IAM role or user ARN (arn:aws:iam::<12-digit-account>:role/<name> or :user/<name>) with no wildcards."
  }

  validation {
    condition = alltrue([
      for k, e in var.access_entries :
      contains(["STANDARD", "EC2_LINUX", "EC2_WINDOWS", "FARGATE_LINUX", "HYBRID_LINUX"], e.type)
    ])
    error_message = "access_entries[*].type must be one of STANDARD, EC2_LINUX, EC2_WINDOWS, FARGATE_LINUX, HYBRID_LINUX."
  }

  # The EKS API refuses groups / user_name / policy associations on
  # non-STANDARD entry types — those entries exist to describe compute,
  # not to grant a principal access (INV-0011 F7).
  validation {
    condition = alltrue([
      for k, e in var.access_entries :
      e.type == "STANDARD" || (
        length(e.kubernetes_groups) == 0 &&
        e.user_name == null &&
        length(e.policy_associations) == 0
      )
    ])
    error_message = "Non-STANDARD access entry types (EC2_LINUX, EC2_WINDOWS, FARGATE_LINUX, HYBRID_LINUX) cannot carry kubernetes_groups, user_name, or policy_associations — the EKS API rejects them."
  }

  # Full policy ARNs, prefix-validated (DESIGN-0024 OQ 2a): AWS grows
  # the cluster-access-policy catalog without a module release, but a
  # pasted IAM policy ARN still fails at plan.
  validation {
    condition = alltrue(flatten([
      for k, e in var.access_entries : [
        for ak, a in e.policy_associations :
        startswith(a.policy_arn, "arn:aws:eks::aws:cluster-access-policy/")
      ]
    ]))
    error_message = "Every policy_associations[*].policy_arn must be a full EKS cluster-access-policy ARN starting with arn:aws:eks::aws:cluster-access-policy/ (not an IAM policy ARN)."
  }

  validation {
    condition = alltrue(flatten([
      for k, e in var.access_entries : [
        for ak, a in e.policy_associations :
        contains(["cluster", "namespace"], a.access_scope.type)
      ]
    ]))
    error_message = "Every policy_associations[*].access_scope.type must be \"cluster\" or \"namespace\"."
  }

  # A namespace-scoped association with no namespaces grants nothing —
  # the caller almost certainly meant cluster scope.
  validation {
    condition = alltrue(flatten([
      for k, e in var.access_entries : [
        for ak, a in e.policy_associations :
        a.access_scope.type != "namespace" || length(a.access_scope.namespaces) > 0
      ]
    ]))
    error_message = "A policy association with access_scope.type = \"namespace\" must list at least one namespace (use \"cluster\" scope for cluster-wide grants)."
  }
}

variable "tags" {
  description = "AWS resource tags applied to every access entry in the module."
  type        = map(string)
  default     = {}
}
