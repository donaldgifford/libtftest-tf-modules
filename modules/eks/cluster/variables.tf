#--------------------------------------------------------------
# Shared Variables
#--------------------------------------------------------------

variable "eks_version" {
  type    = string
  default = "1.35"
}

variable "name" {
  description = "Cluster Name."
  type        = string
  default     = "libtftest"
}

variable "aws_account_alias_enabled" {
  description = "AWS Account Alias Data Resource enabled."
  type        = bool
  default     = true
}

variable "account_alias" {
  description = "AWS Account Alias if not set."
  type        = string
}

variable "sso_access_enabled" {
  description = "AWS SSO access to cluster via EKS Access Entry enabled."
  type        = bool
  default     = false
}

variable "sso_role_name" {
  description = "AWS SSO Permission Set to Allow"
  type        = string
  default     = "Developer"
}

variable "sso_eks_access_entry" {
  description = "Object mapping for EKS Access Entry"
  type = object({
    kubernetes_groups = list(string)
    user_name         = string
    type              = string
  })
  default = {
    kubernetes_groups = ["dev:readonly"]
    user_name         = "dev:sso-readonly:{{SessionName}}"
    type              = "STANDARD"
  }
}

variable "sso_cluster_policy" {
  description = "Policy to attach to SSO EKS Access Entry"
  type        = string

  validation {
    condition     = contains(["AmazonEKSClusterAdminPolicy", "AmazonEKSAdminPolicy", "AmazonEKSViewPolicy", var.sso_cluster_policy])
    error_message = "Invalid input, options: \"AmazonEKSClusterAdminPolicy\", \"AmazonEKSAdminPolicy\", \"AmazonEKSViewPolicy\"."
  }
}

variable "sso_cluster_policy_access_scope" {
  description = "Policy to attach to SSO EKS Access scope."
  type        = string
  default     = "cluster"
}

#--------------------------------------------------------------
# Data Provider definitions
#--------------------------------------------------------------

# TODO: remove once `var.region` migration lands — region comes from
# Boilerplate-generated Terragrunt. See ADR-0001.
data "aws_region" "this" {}

# Identity-class carve-out under ADR-0001: kept on purpose. Account ID is
# identity (does not drift), the call is free, and hoisting via Boilerplate
# would only relocate the same `sts:GetCallerIdentity` resolution. Used in
# the KMS key resource policy (`arn:aws:iam::<id>:root` principal) and any
# IAM ARN construction in the SSO access entry block.
data "aws_caller_identity" "current" {}

# TODO: remove once `var.account_alias` migration lands — account alias
# comes from Boilerplate-generated Terragrunt. See ADR-0001.
data "aws_iam_account_alias" "this" {
  count = var.aws_account_alias_enabled ? 1 : 0
}

# TODO: replace tag-based VPC discovery with a remote-state read from the
# VPC stack — `data.terraform_remote_state.vpc.outputs.vpc_id` driven by
# `var.remote_state_bucket`, `var.region`, `var.vpc_name`. See ADR-0001:
# live AWS data sources let upstream drift cascade into this module's plan;
# the VPC stack's state file is the contract.
data "aws_vpc" "this" {
  filter {
    name   = "tag:Account"
    values = [local.tags.Account]
  }
}

# TODO: replace with `data.terraform_remote_state.vpc.outputs.private_subnet_ids`.
# See ADR-0001.
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = {
    Network = "Private"
  }
}

# TODO: replace with `data.terraform_remote_state.vpc.outputs.public_subnet_ids`.
# See ADR-0001.
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = {
    Network = "Public"
  }
}
