#--------------------------------------------------------------
# Data sources
#--------------------------------------------------------------

# Identity-class carve-out under ADR-0001. Account ID is identity (does not
# drift), the call is effectively free, and hoisting via Boilerplate would
# only relocate the same sts:GetCallerIdentity resolution. Used in the KMS
# key resource policy (arn:aws:iam::<id>:root principal).
data "aws_caller_identity" "current" {}

# VPC stack remote state. Per ADR-0001, cross-module data flows through
# the last-known-good state file rather than live AWS data sources.
data "terraform_remote_state" "vpc" {
  backend = "s3"

  config = {
    bucket = var.remote_state_bucket
    key    = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
    region = var.region
  }
}
