#--------------------------------------------------------------
# Data sources
#--------------------------------------------------------------
#
# Cross-module composition per ADR-0001: cluster + VPC state files
# are the last-known-good ground truth, read at the use site rather
# than re-aliased through locals.
#
# use_path_style = true keeps S3 addressing as bucket-in-path so the
# data source works against any S3 endpoint (production, LocalStack,
# etc.) without virtual-host DNS dependence. Matches the cluster
# module's drive-by fix.

# Terragrunt multi-account shape (IMPL-0015): both reads use the account-scoped
# key, the remote-state bucket's own region, and a cross-account assume_role.
# The session name is the fixed production literal (Q5a).

data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.account_name}/${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region         = var.remote_state_bucket_region
    use_path_style = true

    assume_role = {
      role_arn     = "arn:aws:iam::${var.account_id}:role/${var.deploy_role_name}"
      session_name = "Deploy-Tf"
    }
  }
}

data "terraform_remote_state" "vpc" {
  backend = "s3"

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
