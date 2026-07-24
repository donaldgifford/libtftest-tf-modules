#--------------------------------------------------------------
# Inputs
#--------------------------------------------------------------

variable "remote_state_bucket" {
  description = "S3 bucket the fixture creates and writes the stub VPC remote state into. The seeded object lands at the key downstream module tests read: <region>/vpc/<vpc_name>/terraform.tfstate."
  type        = string
  nullable    = false
}

variable "vpc_name" {
  description = "Logical VPC name. Used as the <vpc_name> segment of the seeded remote-state key and as the Name tag on the VPC."
  type        = string
  nullable    = false
}

variable "region" {
  description = "AWS region. Used to compose subnet availability zones (region + az_letters) and the seeded remote-state key."
  type        = string
  nullable    = false
}

variable "vpc_cidr" {
  description = "CIDR block for the reference VPC. The three subnet tiers are carved as /24s within it."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_letters" {
  description = "Availability-zone letters (each appended to var.region) the three subnet tiers span. Defaults to three AZs per DESIGN-0016."
  type        = list(string)
  default     = ["a", "b", "c"]
}
