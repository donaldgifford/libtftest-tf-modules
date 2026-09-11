variable "remote_state_bucket" {
  description = "S3 bucket the reference-vpc fixture seeds its contract state into."
  type        = string
  nullable    = false
}

variable "remote_state_bucket_region" {
  description = "Region of the remote-state bucket."
  type        = string
  nullable    = false
}

variable "vpc_name" {
  description = "VPC name — the <name> segment of the seeded ADR-0020 vpc key, and the prefix for the fixture's own resources."
  type        = string
  nullable    = false
}

variable "account_name" {
  description = "Terragrunt account name — the <account_name> prefix of the seeded key."
  type        = string
  nullable    = false
}

variable "region" {
  description = "Deployment region."
  type        = string
  nullable    = false
}
