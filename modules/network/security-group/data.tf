#--------------------------------------------------------------
# Data sources
#--------------------------------------------------------------

# VPC stack remote state. Per ADR-0001, cross-module data flows through
# the last-known-good state file rather than live AWS data sources. This
# module is the seventh vpc consumer (ADR-0020).
#
# use_path_style = true keeps S3 addressing as bucket-in-path (works with
# any bucket name, any S3 endpoint — including LocalStack — without
# relying on virtual-host DNS resolution).
data "terraform_remote_state" "vpc" {
  backend = "s3"

  # Terragrunt multi-account shape (IMPL-0015): account-scoped key, the
  # remote-state bucket's own region, and a cross-account assume_role. The
  # session name is the fixed production literal.
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
