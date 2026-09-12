variable "security_group_id" {
  description = "Id of the security group created by the module under test."
  type        = string
  nullable    = false
}

variable "vpc_id" {
  description = "VPC the security group is expected to be in — asserted by the caller against the contract VPC."
  type        = string
  nullable    = false
}

variable "prefix_list_rule_id" {
  description = "sgr-... id of the prefix-list ingress rule, read back to prove the live reference survived the apply."
  type        = string
  nullable    = false
}
