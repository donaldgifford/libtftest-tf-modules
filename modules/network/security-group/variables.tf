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
# The rules surface
#
# One aws_vpc_security_group_{ingress,egress}_rule resource per map
# entry, keyed by LOGICAL name. That keying is the point: plan diffs
# read as named intentions, and adding or removing one webhook source
# never churns a sibling rule's address.
#
# DEVIATION FROM DESIGN-0026, deliberate: the design's object spec
# writes `from_port = number` (required) while also requiring a
# ports-with-"-1" rejection. Those two cannot both hold — a required
# from_port means every rule carries a port, so an all-protocols rule
# would always be rejected and "-1" would be unrepresentable. Every
# "-1" rule in the fleet (eks/cluster, rds/cluster, rds/serverless)
# omits ports, and this module's own allow_all_egress default emits
# exactly that shape. So from_port is optional(number) and the
# coherence is enforced by validation instead: ports are REQUIRED for
# tcp/udp and REJECTED for "-1".
#--------------------------------------------------------------

variable "ingress_rules" {
  description = "Ingress allowlist, keyed by logical rule name (stable addresses). Each rule names exactly ONE source: cidr_ipv4 | cidr_ipv6 | prefix_list_id | referenced_security_group_id. prefix_list_id rules are LIVE references — edits to the list propagate without a Terraform apply, unlike the eks/cluster endpoint fence's plan-time expansion. description is required: every allowlist entry says why it exists. to_port defaults to from_port (single-port rule). Set ip_protocol = \"-1\" for all protocols, in which case ports must be omitted."
  type = map(object({
    description                  = string
    from_port                    = optional(number)
    to_port                      = optional(number)
    ip_protocol                  = optional(string, "tcp")
    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    prefix_list_id               = optional(string)
    referenced_security_group_id = optional(string)
  }))
  default = {}

  nullable = false
}

variable "egress_rules" {
  description = "Egress rules, keyed by logical rule name. Same object shape as ingress_rules. Additive to allow_all_egress — set allow_all_egress = false to make this map the whole egress posture, otherwise the all-egress rule is already wider than anything you add here."
  type = map(object({
    description                  = string
    from_port                    = optional(number)
    to_port                      = optional(number)
    ip_protocol                  = optional(string, "tcp")
    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    prefix_list_id               = optional(string)
    referenced_security_group_id = optional(string)
  }))
  default = {}

  nullable = false
}

variable "allow_all_egress" {
  description = "Emit one explicit all-protocols egress rule to 0.0.0.0/0 (default true). This is NOT redundant with AWS's default: the provider REVOKES the default allow-all egress when it creates a security group, so a module with no egress surface would ship SGs that silently fail ALB health checks and target traffic. The rule is emitted as a real resource so the posture is visible in every plan rather than implied. Set false to make egress_rules the whole posture."
  type        = bool
  default     = true

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
