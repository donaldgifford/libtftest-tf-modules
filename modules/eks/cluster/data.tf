#--------------------------------------------------------------
# Data sources
#--------------------------------------------------------------

# Identity-class carve-out under ADR-0001. Account ID is identity (does not
# drift), the call is effectively free, and hoisting via Boilerplate would
# only relocate the same sts:GetCallerIdentity resolution. Used in the KMS
# key resource policy (arn:aws:iam::<id>:root principal).
data "aws_caller_identity" "current" {}

# Managed prefix lists expanded into the public-endpoint fence. The EKS
# API accepts literal CIDRs only, so this is a PLAN-TIME snapshot of
# each list's entries — edits to a list do not reach the cluster until
# this stack's next apply (DESIGN-0024 part 2; the README warning
# callout spells out the contrast with a live SG prefix-list rule).
data "aws_ec2_managed_prefix_list" "fence" {
  for_each = toset(var.endpoint_public_access_prefix_list_ids)

  id = each.value
}

# VPC stack remote state. Per ADR-0001, cross-module data flows through
# the last-known-good state file rather than live AWS data sources.
#
# use_path_style = true keeps S3 addressing as bucket-in-path (works with
# any bucket name, any S3 endpoint — including LocalStack — without
# relying on virtual-host DNS resolution). Modest performance cost,
# wider compatibility.
data "terraform_remote_state" "vpc" {
  backend = "s3"

  # Terragrunt multi-account shape (IMPL-0015): account-scoped key, the
  # remote-state bucket's own region, and a cross-account assume_role. The
  # session name is the fixed production literal (Q5a).
  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.account_name}/${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
    region         = var.remote_state_bucket_region
    use_path_style = true

    assume_role = {
      role_arn     = "arn:aws:iam::${var.account_id}:role/${var.deploy_role_name}"
      session_name = "Deploy-Tf"
    }
  }
}
