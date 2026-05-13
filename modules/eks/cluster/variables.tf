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
data "aws_region" "this" {}
data "aws_caller_identity" "current" {}

data "aws_iam_account_alias" "this" {
  count = var.aws_account_alias_enabled ? 1 : 0
}

data "aws_vpc" "this" {
  filter {
    name   = "tag:Account"
    values = [local.tags.Account]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = {
    Network = "Private"
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = {
    Network = "Public"
  }
}
