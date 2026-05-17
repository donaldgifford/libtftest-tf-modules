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
  description = "When true (default), the module creates a Pod-Identity-trusting IAM role and binds the association to it. When false, the caller must pass existing_role_arn — the module creates the association only."
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
  description = "AWS-managed policy ARNs to attach to the Mode A role (e.g. arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy)."
  type        = list(string)
  default     = []
}

variable "customer_managed_policy_arns" {
  description = "Customer-managed policy ARNs to attach to the Mode A role. Separate from managed_policy_arns so the plan distinguishes AWS-owned from caller-owned policy ARNs at a glance."
  type        = list(string)
  default     = []
}

variable "inline_policies" {
  description = "Inline IAM policy documents to attach to the Mode A role, keyed by policy name. Values are JSON strings."
  type        = map(string)
  default     = {}
}

variable "permissions_boundary" {
  description = "ARN of an IAM permissions boundary policy to attach to the Mode A role. Null (default) attaches no boundary."
  type        = string
  default     = null
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
