#--------------------------------------------------------------
# Identity
#--------------------------------------------------------------

variable "name" {
  description = "Logical name for this security group. Becomes the name_prefix (\"<name>-\", so the physical name carries a provider-generated suffix), the friendly Name tag, the default description, and the <name> segment of this stack's ADR-0020 remote-state key — which makes it triple-coupled: producer identifier == live-repo folder == future consumer input. Renaming is a deliberate SG replacement, not a refactor."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,99}$", var.name))
    error_message = "name must be 1-100 characters of alphanumerics, underscore, period or hyphen, starting with an alphanumeric or underscore — the name_prefix adds a suffix, so this leaves room under the AWS 255-character group-name limit."
  }

  nullable = false
}

variable "description" {
  description = "Security group description. Defaults to a line composed from var.name. NOTE: description is create-time on AWS (ForceNew) — editing it REPLACES the security group. The module's name_prefix + create_before_destroy make that replacement survivable, but it still mints a new security group id, so any chart-side or cross-stack consumer of the id needs updating in the same change."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the security group and to every rule resource. The Name tag is set by the module from var.name and must not be supplied here."
  type        = map(string)
  default     = {}

  validation {
    condition     = !contains(keys(var.tags), "Name")
    error_message = "tags must not set Name — the module sets it from var.name so the friendly name and the name_prefix cannot drift apart."
  }

  nullable = false
}

#--------------------------------------------------------------
# VPC remote-state pointer
#--------------------------------------------------------------

variable "vpc_name" {
  description = "VPC name used to compose the VPC remote-state key (<account_name>/<region>/vpc/<vpc_name>/terraform.tfstate). Must match the VPC stack's identifier."
  type        = string
  nullable    = false
}

#--------------------------------------------------------------
# Terragrunt-injected multi-account globals (IMPL-0015)
#
# In production Terragrunt injects these into every module via includes,
# regardless of whether the module uses them. At test time the shared
# test/fixtures/terragrunt-inputs.tfvars var-file supplies them.
#--------------------------------------------------------------

variable "region" {
  description = "AWS region the security group is created in."
  type        = string
  nullable    = false
}

variable "account_name" {
  description = "Terragrunt account name — the <account_name> prefix of the account-scoped VPC remote-state key this module reads."
  type        = string
  nullable    = false
}

variable "account_id" {
  description = "12-digit AWS account ID that owns the remote-state bucket. Composed into the assume_role role_arn (arn:aws:iam::<account_id>:role/<deploy_role_name>) for the cross-account state read."
  type        = string
  nullable    = false
}

variable "remote_state_bucket" {
  description = "S3 bucket holding the VPC stack's terraform state, read at <account_name>/<region>/vpc/<vpc_name>/terraform.tfstate for vpc_id."
  type        = string
  nullable    = false
}

variable "remote_state_bucket_region" {
  description = "Region of the remote-state S3 bucket — distinct from var.region (the deployment region) in production Terragrunt."
  type        = string
  nullable    = false
}

variable "deploy_role_name" {
  description = "Name of the IAM role Terraform assumes to read the remote-state bucket cross-account. Composed into the assume_role role_arn with account_id."
  type        = string
  nullable    = false
}
